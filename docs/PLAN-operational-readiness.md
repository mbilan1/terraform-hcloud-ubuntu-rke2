# Plan: Operational Readiness — Backup, Upgrade, Rollback

> **Status**: Approved plan, not yet implemented
> **Branch**: `feature/operational-readiness-plan`
> **Created**: 2026-02-15
> **Scope**: etcd backup, PVC backup (Velero), health check, upgrade flow, rollback procedure
> **MTTR target**: < 15 min for HA cluster (3 masters + 3 workers)

---

## Table of Contents

- [Problem Statement](#problem-statement)
- [Architecture Overview](#architecture-overview)
- [Step 1: etcd Backup (K8s State → S3)](#step-1-etcd-backup-k8s-state--s3)
- [Step 2: PVC Backup via Velero (Application Data → S3)](#step-2-pvc-backup-via-velero-application-data--s3)
- [Step 3: Health Check (null_resource)](#step-3-health-check-null_resource)
- [Step 4: Upgrade with Pre-Snapshot](#step-4-upgrade-with-pre-snapshot)
- [Step 5: Rollback (Monolithic)](#step-5-rollback-monolithic)
- [Step 6: Documentation in ARCHITECTURE.md](#step-6-documentation-in-architecturemd)
- [Files Changed](#files-changed)
- [Verification](#verification)
- [Key Decisions](#key-decisions)
- [MTTR Breakdown](#mttr-breakdown)
- [RPO / RTO Targets](#rpo--rto-targets)

---

## Problem Statement

The module has **zero** day-2 operational capabilities:

| Gap | Severity | Current state |
|-----|:--------:|---------------|
| etcd backup | CRITICAL | RKE2 local snapshots only (default 12h/5 retention), lost if node is destroyed |
| PVC backup | CRITICAL | None. MySQL, MongoDB, MeiliSearch, Redis data unprotected |
| Health check after upgrade/restore | HIGH | None. No automated validation that cluster is functional |
| Upgrade procedure | HIGH | SUC exists but no pre-snapshot, no health validation, no rollback |
| Rollback procedure | HIGH | No documented or automated rollback path |

---

## Architecture Overview

Two-level backup architecture, both targeting Hetzner Object Storage (S3-compatible):

```
Level 1: etcd snapshots (Kubernetes state)
──────────────────────────────────────────
  RKE2 config.yaml → etcd-s3-* params → Hetzner Object Storage
  Mechanism: RKE2 native (zero dependencies, runs in cloud-init)
  RPO: 6 hours (configurable via cron)

Level 2: PVC data (application state)
──────────────────────────────────────
  Velero + Kopia → file-level PV backup → Hetzner Object Storage
  Mechanism: Helm release (cluster-velero.tf)
  RPO: 6 hours (configurable via Velero Schedule)
  Pre-backup hooks: mysqldump, mongodump for DB consistency

Upgrade flow:
─────────────
  rke2_version change
    → null_resource.pre_upgrade_snapshot (etcd + Velero)
    → RKE2 upgrade (SUC or manual)
    → null_resource.cluster_health_check
    → IF FAIL → operator executes rollback (documented procedure)

Rollback:
─────────
  etcd restore (K8s state) + Velero restore (PVC data) = full cluster rollback
```

### Why Two Levels?

| Layer | What it protects | Restore scope |
|-------|-----------------|---------------|
| etcd snapshot | All K8s objects: Deployments, Services, ConfigMaps, Secrets, CRDs, RBAC, PVCs (metadata) | Cluster state |
| Velero + Kopia | Actual data on PVs: MySQL databases, MongoDB collections, MeiliSearch indexes, Redis dumps | Application data |

etcd snapshot alone restores PVC *claims* but not the *data on the volumes*. Both levels are required for a complete rollback.

---

## Step 1: etcd Backup (K8s State → S3)

RKE2 natively supports S3-compatible backup via `config.yaml` parameters.
See: https://docs.rke2.io/datastore/backup_restore

Hetzner Object Storage endpoints: `{location}.your-objectstorage.com` (fsn1, nbg1, hel1).
See: https://docs.hetzner.com/storage/object-storage/overview

### 1a. Variables

Extend `cluster_configuration` in `variables.tf` — add `etcd_backup` object:

```hcl
etcd_backup = optional(object({
  enabled        = optional(bool, false)
  schedule_cron  = optional(string, "0 */6 * * *")   # Every 6h (RKE2 default is 12h — too infrequent for production)
  retention      = optional(number, 10)
  compress       = optional(bool, true)
  s3_endpoint    = optional(string, "")               # Auto-filled from lb_location if empty
  s3_bucket      = optional(string, "")
  s3_folder      = optional(string, "")               # Defaults to cluster_name
  s3_access_key  = optional(string, "")
  s3_secret_key  = optional(string, "")
  s3_region      = optional(string, "eu-central")
}), {})
```

Mark `s3_access_key` and `s3_secret_key` as sensitive in the `templatefile()` call (they are already wrapped in `sensitive()` for the entire `user_data`).

### 1b. Guardrail

Add to `guardrails.tf`:

```hcl
check "etcd_backup_requires_s3_config" {
  assert {
    condition = (
      !var.cluster_configuration.etcd_backup.enabled ||
      (
        trimspace(var.cluster_configuration.etcd_backup.s3_bucket) != "" &&
        trimspace(var.cluster_configuration.etcd_backup.s3_access_key) != "" &&
        trimspace(var.cluster_configuration.etcd_backup.s3_secret_key) != ""
      )
    )
    error_message = "etcd_backup.enabled=true requires s3_bucket, s3_access_key, and s3_secret_key to be set."
  }
}
```

### 1c. Cloud-init template

Modify `scripts/rke-master.sh.tpl` — add conditional block to generated `config.yaml`:

```yaml
%{ if ETCD_BACKUP_ENABLED }
etcd-snapshot-schedule-cron: "${ETCD_SNAPSHOT_SCHEDULE}"
etcd-snapshot-retention: ${ETCD_SNAPSHOT_RETENTION}
etcd-snapshot-compress: ${ETCD_SNAPSHOT_COMPRESS}
etcd-s3: true
etcd-s3-endpoint: ${ETCD_S3_ENDPOINT}
etcd-s3-bucket: ${ETCD_S3_BUCKET}
etcd-s3-folder: ${ETCD_S3_FOLDER}
etcd-s3-access-key: ${ETCD_S3_ACCESS_KEY}
etcd-s3-secret-key: ${ETCD_S3_SECRET_KEY}
etcd-s3-region: ${ETCD_S3_REGION}
%{ endif }
```

### 1d. Update templatefile() calls

In `main.tf`, add new template variables to both `hcloud_server.master` and `hcloud_server.additional_masters` `templatefile()` calls:

```hcl
ETCD_BACKUP_ENABLED    = var.cluster_configuration.etcd_backup.enabled
ETCD_SNAPSHOT_SCHEDULE  = var.cluster_configuration.etcd_backup.schedule_cron
ETCD_SNAPSHOT_RETENTION = var.cluster_configuration.etcd_backup.retention
ETCD_SNAPSHOT_COMPRESS  = var.cluster_configuration.etcd_backup.compress
ETCD_S3_ENDPOINT        = local.etcd_s3_endpoint
ETCD_S3_BUCKET          = var.cluster_configuration.etcd_backup.s3_bucket
ETCD_S3_FOLDER          = local.etcd_s3_folder
ETCD_S3_ACCESS_KEY      = var.cluster_configuration.etcd_backup.s3_access_key
ETCD_S3_SECRET_KEY      = var.cluster_configuration.etcd_backup.s3_secret_key
ETCD_S3_REGION          = var.cluster_configuration.etcd_backup.s3_region
```

### 1e. Computed locals

Add to `locals.tf`:

```hcl
# DECISION: Auto-detect Hetzner Object Storage endpoint from lb_location.
# Why: Reduces configuration burden — operator only needs bucket + credentials.
# Hetzner endpoints follow pattern: {location}.your-objectstorage.com.
# See: https://docs.hetzner.com/storage/object-storage/overview
etcd_s3_endpoint = (
  trimspace(var.cluster_configuration.etcd_backup.s3_endpoint) != ""
  ? var.cluster_configuration.etcd_backup.s3_endpoint
  : "${var.lb_location}.your-objectstorage.com"
)

etcd_s3_folder = (
  trimspace(var.cluster_configuration.etcd_backup.s3_folder) != ""
  ? var.cluster_configuration.etcd_backup.s3_folder
  : var.cluster_name
)
```

---

## Step 2: PVC Backup via Velero (Application Data → S3)

### Why Velero + Kopia (not CSI snapshots)

Hetzner CSI driver does **NOT** support VolumeSnapshot.
- Confirmed: https://github.com/hetznercloud/csi-driver/issues/849
- Hetzner maintainer (Aug 2025): *"VolumeSnapshots are still not supported by the Hetzner Cloud API"*
- Hetzner Cloud API has no volume snapshot endpoint — only server snapshots exist
- This rules out all CSI-snapshot-based backup paths

Velero + Kopia = file-level backup via node agent. Mounts PV, copies files to S3-compatible storage.

### Tutor PVCs (from abstract-k8s-common-template)

| PVC | Access Mode | Size | Content |
|-----|------------|------|---------|
| `mysql` | RWO | 5Gi | MySQL database |
| `mongodb` | RWO | 5Gi | MongoDB database |
| `meilisearch` | RWO | 5Gi | Search engine data |
| `redis` | RWO | 1Gi | Cache/queue |
| **Total** | | **16Gi** | |

### Database consistency

File-level backup of a running database can produce inconsistent snapshots (unflushed WAL, partial writes). Solution: Velero **pre-backup hooks** via pod annotations.

Tutor deployments should add these annotations to database pods:

```yaml
# MySQL pod
annotations:
  pre.hook.backup.velero.io/command: '["/bin/sh", "-c", "mysqldump --all-databases --single-transaction > /var/lib/mysql/velero-dump.sql"]'
  pre.hook.backup.velero.io/timeout: "120s"

# MongoDB pod
annotations:
  pre.hook.backup.velero.io/command: '["/bin/sh", "-c", "mongodump --archive=/data/db/velero-dump.archive"]'
  pre.hook.backup.velero.io/timeout: "120s"
```

NOTE: These annotations are on the Tutor/Harmony layer, not in this module. The module only deploys Velero infrastructure. Documenting here for completeness.

### 2a. Variables

New top-level variable `velero` in `variables.tf`:

```hcl
variable "velero" {
  type = object({
    enabled         = optional(bool, false)
    version         = optional(string, "11.3.2")
    backup_schedule = optional(string, "0 */6 * * *")  # Synchronized with etcd schedule
    backup_ttl      = optional(string, "720h")          # 30 days retention
    s3_endpoint     = optional(string, "")               # Reuses etcd_backup endpoint if empty
    s3_bucket       = optional(string, "")               # Reuses etcd_backup bucket if empty
    s3_access_key   = optional(string, "")
    s3_secret_key   = optional(string, "")
    s3_region       = optional(string, "eu-central")
    extra_values    = optional(list(string), [])
  })
  default     = {}
  sensitive   = false  # But s3_access_key/s3_secret_key are passed to Helm via sensitive values
  description = <<-EOT
    Velero backup infrastructure for PVC data protection.
    Uses Kopia file-level backup (Hetzner CSI does not support VolumeSnapshot).
    Targets S3-compatible storage (Hetzner Object Storage recommended).
  EOT
}
```

### 2b. New file: cluster-velero.tf

```hcl
# ──────────────────────────────────────────────────────────────────────────────
# Velero — PVC backup via Kopia file-level backup
# https://velero.io/
#
# DECISION: Velero + Kopia instead of CSI VolumeSnapshot
# Why: Hetzner CSI does not support VolumeSnapshot (GitHub issue #849,
#      confirmed by maintainer Aug 2025). Kopia is the only file-level
#      backup path. velero-plugin-for-aws works with any S3-compatible
#      endpoint (including Hetzner Object Storage).
# See: https://github.com/hetznercloud/csi-driver/issues/849
# ──────────────────────────────────────────────────────────────────────────────

resource "kubernetes_namespace_v1" "velero" {
  depends_on = [null_resource.wait_for_cluster_ready]
  count      = var.velero.enabled ? 1 : 0
  metadata {
    name = "velero"
  }
  lifecycle {
    ignore_changes = [metadata[0].annotations]
  }
}

resource "helm_release" "velero" {
  depends_on = [
    null_resource.wait_for_cluster_ready,
    helm_release.hcloud_csi,  # PVCs must be provisionable before backup
  ]
  count      = var.velero.enabled ? 1 : 0
  repository = "https://vmware-tanzu.github.io/helm-charts"
  chart      = "velero"
  name       = "velero"
  namespace  = kubernetes_namespace_v1.velero[0].metadata[0].name
  version    = var.velero.version

  values = concat([yamlencode(local.velero_values)], var.velero.extra_values)
}
```

Velero values (in `locals.tf` or `templates/values/velero.yaml`):

```yaml
initContainers:
  - name: velero-plugin-for-aws
    image: velero/velero-plugin-for-aws:v1.11.1
    volumeMounts:
      - mountPath: /target
        name: plugins

deployNodeAgent: true            # Required for Kopia file-level backup
nodeAgent:
  podVolumePath: /var/lib/kubelet/pods

configuration:
  defaultVolumesToFsBackup: true  # All PVCs backed up via Kopia by default
  backupStorageLocations:
    - name: default
      provider: aws
      bucket: <s3_bucket>
      config:
        region: <s3_region>
        s3ForcePathStyle: "true"
        s3Url: https://<s3_endpoint>
      credential:
        name: velero-s3-credentials
        key: cloud

credentials:
  secretContents:
    cloud: |
      [default]
      aws_access_key_id=<s3_access_key>
      aws_secret_access_key=<s3_secret_key>

schedules:
  full-cluster:
    disabled: false
    schedule: "<backup_schedule>"
    useOwnerReferencesInBackup: false
    template:
      ttl: "<backup_ttl>"
      includedNamespaces:
        - "*"
      defaultVolumesToFsBackup: true
```

### 2c. Guardrails

```hcl
check "velero_requires_s3_config" {
  assert {
    condition = (
      !var.velero.enabled ||
      (
        local.velero_s3_bucket != "" &&
        local.velero_s3_access_key != "" &&
        local.velero_s3_secret_key != ""
      )
    )
    error_message = "velero.enabled=true requires S3 credentials. Set them in velero.s3_* or cluster_configuration.etcd_backup.s3_*."
  }
}

check "velero_requires_csi" {
  assert {
    condition = !var.velero.enabled || var.cluster_configuration.hcloud_csi.preinstall
    error_message = "Velero backs up PVCs provisioned by CSI. Set cluster_configuration.hcloud_csi.preinstall=true when velero.enabled=true."
  }
}
```

### 2d. Credential reuse

If Velero S3 credentials are empty, fall back to etcd_backup credentials (computed local):

```hcl
velero_s3_endpoint   = coalesce(var.velero.s3_endpoint, local.etcd_s3_endpoint)
velero_s3_bucket     = coalesce(var.velero.s3_bucket, var.cluster_configuration.etcd_backup.s3_bucket)
velero_s3_access_key = coalesce(var.velero.s3_access_key, var.cluster_configuration.etcd_backup.s3_access_key)
velero_s3_secret_key = coalesce(var.velero.s3_secret_key, var.cluster_configuration.etcd_backup.s3_secret_key)
```

One set of Hetzner Object Storage credentials → both etcd and Velero backups.

---

## Step 3: Health Check (null_resource)

Unified health check after any critical operation (upgrade, restore). Runs on `master[0]` via `remote-exec`.

### 3a. Resource

New `null_resource.cluster_health_check` in `main.tf`:

```hcl
resource "null_resource" "cluster_health_check" {
  depends_on = [null_resource.wait_for_cluster_ready]

  # Re-run when RKE2 version changes (triggers health check after upgrade)
  triggers = {
    rke2_version = var.rke2_version
  }

  provisioner "remote-exec" {
    inline = [
      <<-EOT
      export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
      KC=/var/lib/rancher/rke2/bin/kubectl
      EXPECTED=${var.master_node_count + var.worker_node_count}
      TIMEOUT=600
      ELAPSED=0

      echo "=== Cluster Health Check ==="

      # Check 1: API server /readyz
      until [ "$($KC get --raw='/readyz' 2>/dev/null)" = "ok" ]; do
        [ $ELAPSED -ge $TIMEOUT ] && echo "FAIL: API /readyz" && exit 1
        sleep 5; ELAPSED=$((ELAPSED + 5))
      done
      echo "PASS: API /readyz"

      # Check 2: All nodes Ready
      while true; do
        READY=$($KC get nodes --no-headers 2>/dev/null | awk '$2 == "Ready" {c++} END {print c+0}')
        [ "$READY" -ge "$EXPECTED" ] && break
        [ $ELAPSED -ge $TIMEOUT ] && echo "FAIL: Nodes $READY/$EXPECTED" && exit 1
        sleep 10; ELAPSED=$((ELAPSED + 10))
      done
      echo "PASS: Nodes $READY/$EXPECTED Ready"

      # Check 3: System pods Running (coredns, kube-proxy, cloud-controller-manager)
      for POD_PREFIX in coredns kube-proxy cloud-controller-manager; do
        COUNT=$($KC get pods -A --no-headers 2>/dev/null | grep "$POD_PREFIX" | grep -c "Running" || true)
        if [ "$COUNT" -eq 0 ]; then
          echo "FAIL: No running $POD_PREFIX pods"
          exit 1
        fi
        echo "PASS: $POD_PREFIX ($COUNT running)"
      done

      # Check 4: HTTP endpoint (optional, for OpenEdx /heartbeat)
      %{ for URL in HEALTH_CHECK_URLS }
      HTTP_CODE=$(curl -sk -o /dev/null -w '%%{http_code}' '${URL}' 2>/dev/null || echo "000")
      if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 400 ]; then
        echo "PASS: HTTP ${URL} ($HTTP_CODE)"
      else
        echo "FAIL: HTTP ${URL} ($HTTP_CODE)"
        exit 1
      fi
      %{ endfor }

      echo "=== All health checks passed ==="
      EOT
    ]

    connection {
      type        = "ssh"
      host        = hcloud_server.master[0].ipv4_address
      user        = "root"
      private_key = tls_private_key.machines.private_key_openssh
      timeout     = "15m"
    }
  }
}
```

### 3b. Variable

```hcl
variable "health_check_urls" {
  type        = list(string)
  default     = []
  description = <<-EOT
    HTTP(S) URLs to check after cluster operations (upgrade, restore).
    Each URL must return 2xx/3xx to pass. Empty list skips HTTP checks.
    For OpenEdx: ["https://yourdomain.com/heartbeat"]
    The /heartbeat endpoint validates MySQL, MongoDB, and app availability.
  EOT
}
```

### Health check criteria

| # | Check | What it validates | How |
|---|-------|-------------------|-----|
| 1 | API readiness | Control plane alive | `kubectl get --raw='/readyz'` = `ok` |
| 2 | Node readiness | All nodes registered | `kubectl get nodes` count Ready = expected |
| 3 | System pods | Core K8s components | `coredns`, `kube-proxy`, `cloud-controller-manager` Running |
| 4 | HTTP endpoint | Full data path (optional) | `curl` to user-defined URLs (e.g. OpenEdx `/heartbeat`) |

**Why `/heartbeat`**: OpenEdx LMS returns 200 on `/heartbeat` only when MySQL, MongoDB, and the app are reachable. This is a single e2e check for the entire data path. Traffic: client → LB (port 443, already open in firewall) → worker → ingress-nginx → pod. If it responds — the cluster is fully functional.

---

## Step 4: Upgrade with Pre-Snapshot

### 4a. Pre-upgrade snapshot

New `null_resource.pre_upgrade_snapshot` in `main.tf`:

```hcl
resource "null_resource" "pre_upgrade_snapshot" {
  # Only when etcd backup is configured
  count = var.cluster_configuration.etcd_backup.enabled ? 1 : 0

  # Re-run when RKE2 version changes
  triggers = {
    rke2_version = var.rke2_version
  }

  provisioner "remote-exec" {
    inline = [
      <<-EOT
      export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
      SNAPSHOT_NAME="pre-upgrade-$(date +%Y%m%d-%H%M%S)"

      echo "Creating pre-upgrade etcd snapshot: $SNAPSHOT_NAME"
      /var/lib/rancher/rke2/bin/rke2 etcd-snapshot save --name "$SNAPSHOT_NAME"

      # Record snapshot name for rollback reference
      echo "$SNAPSHOT_NAME" > /var/lib/rancher/rke2/server/last-pre-upgrade-snapshot
      echo "Pre-upgrade snapshot saved: $SNAPSHOT_NAME"

      %{ if VELERO_ENABLED }
      echo "Creating pre-upgrade Velero backup: $SNAPSHOT_NAME"
      /var/lib/rancher/rke2/bin/kubectl create -f - <<VELERO_BACKUP
      apiVersion: velero.io/v1
      kind: Backup
      metadata:
        name: $SNAPSHOT_NAME
        namespace: velero
      spec:
        includedNamespaces:
          - "*"
        defaultVolumesToFsBackup: true
        ttl: 720h0m0s
      VELERO_BACKUP

      # Wait for Velero backup to complete (timeout 30 min)
      ELAPSED=0
      while true; do
        PHASE=$(/var/lib/rancher/rke2/bin/kubectl get backup "$SNAPSHOT_NAME" -n velero -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        echo "Velero backup phase: $PHASE ($${ELAPSED}s)"
        [ "$PHASE" = "Completed" ] && break
        [ "$PHASE" = "Failed" ] && echo "WARN: Velero backup failed, continuing with etcd snapshot only" && break
        [ $ELAPSED -ge 1800 ] && echo "WARN: Velero backup timeout, continuing" && break
        sleep 15; ELAPSED=$((ELAPSED + 15))
      done
      %{ endif }
      EOT
    ]

    connection {
      type        = "ssh"
      host        = hcloud_server.master[0].ipv4_address
      user        = "root"
      private_key = tls_private_key.machines.private_key_openssh
      timeout     = "30m"
    }
  }
}
```

### 4b. Dependency graph

```
rke2_version change (var.rke2_version modified in tfvars)
  ↓
null_resource.pre_upgrade_snapshot [triggers on rke2_version]
  ├── etcd-snapshot save (local + S3)
  └── velero backup create (if enabled)
  ↓
[Operator restarts RKE2 services with new version, or SUC handles it]
  ↓
null_resource.cluster_health_check [triggers on rke2_version]
  ├── API /readyz
  ├── All nodes Ready
  ├── System pods Running
  └── HTTP /heartbeat (if configured)
  ↓
IF PASS → upgrade complete
IF FAIL → operator executes rollback (Step 5)
```

### 4c. SUC pre-snapshot enhancement

Modify `templates/manifests/system-upgrade-controller-server.yaml` to add a `prepare` container that takes an etcd snapshot before upgrading the first master:

```yaml
spec:
  concurrency: 1
  cordon: true
  prepare:
    args:
      - etcd-snapshot
      - save
      - --name
      - pre-suc-upgrade
    image: rancher/rke2-upgrade
  upgrade:
    image: rancher/rke2-upgrade
  channel: https://update.rke2.io/v1-release/channels/stable
```

NOTE: The `prepare` field already exists in the agent plan (waits for server-plan). Adding it to the server plan means `rke2 etcd-snapshot save` runs before any upgrade begins.

---

## Step 5: Rollback (Monolithic)

Full cluster rollback = etcd state + PVC data restored as one operation.

### Rollback procedure (HA cluster, 3+ masters)

```bash
# 1. Identify the pre-upgrade snapshot
SNAPSHOT=$(cat /var/lib/rancher/rke2/server/last-pre-upgrade-snapshot)
# Or list all: rke2 etcd-snapshot list

# 2. Stop RKE2 on ALL nodes (workers first, then additional masters, then master-0)
# On each worker:
systemctl stop rke2-agent.service

# On each additional master (master-1, master-2):
systemctl stop rke2-server.service

# On master-0:
systemctl stop rke2-server.service

# 3. Restore etcd on master-0
rke2 server \
  --cluster-reset \
  --cluster-reset-restore-path=/var/lib/rancher/rke2/server/db/snapshots/${SNAPSHOT}

# 4. Start master-0
systemctl start rke2-server.service
# Wait for API: until kubectl get --raw='/readyz' == ok

# 5. On additional masters: remove stale etcd data and rejoin
rm -rf /var/lib/rancher/rke2/server/db/etcd
systemctl start rke2-server.service

# 6. On workers: restart
systemctl start rke2-agent.service

# 7. Restore PVC data (if Velero backup exists)
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
velero restore create --from-backup ${SNAPSHOT} --wait

# 8. Verify
kubectl get nodes                    # All nodes Ready
kubectl get --raw='/readyz'          # ok
kubectl get pods -A | grep -v Running  # No crashed pods
curl -sk https://<domain>/heartbeat  # 200 OK
```

### S3 restore variant (snapshot not on local disk)

```bash
rke2 server \
  --cluster-reset \
  --cluster-reset-restore-path=${SNAPSHOT} \
  --etcd-s3 \
  --etcd-s3-endpoint=fsn1.your-objectstorage.com \
  --etcd-s3-bucket=<bucket> \
  --etcd-s3-access-key=<key> \
  --etcd-s3-secret-key=<secret> \
  --etcd-s3-folder=<cluster-name>
```

### What gets rolled back

| Component | Restored by | State after rollback |
|-----------|------------|---------------------|
| Deployments, Services, ConfigMaps | etcd restore | Pre-upgrade state |
| Secrets, RBAC, CRDs | etcd restore | Pre-upgrade state |
| PVC claims (metadata) | etcd restore | Pre-upgrade state |
| PVC data (MySQL, MongoDB, etc.) | Velero restore | Pre-upgrade state |
| Node registrations | etcd restore + node rejoin | Current nodes |
| Helm releases state | etcd restore | Pre-upgrade state |

### What is NOT rolled back

| Component | Why | Mitigation |
|-----------|-----|------------|
| RKE2 binary version on nodes | Binary is on disk, not in etcd | Reinstall previous version: `INSTALL_RKE2_VERSION=<old> curl -sfL https://get.rke2.io \| sh -` |
| OS-level changes | Out of scope | Hetzner server snapshot (external) |
| Hetzner infrastructure (LB, firewall, network) | Managed by Terraform, not K8s | `tofu apply` with previous state |

---

## Step 6: Documentation in ARCHITECTURE.md

Add section **"Operations: Backup, Upgrade, Rollback"** between "CI Quality Gates" and "Compromise Log" in `docs/ARCHITECTURE.md`.

Content: condensed version of Step 5 (rollback commands), health check criteria table, and RPO/RTO targets. No prose — commands and tables only.

---

## Files Changed

| File | Change type | What changes |
|------|:-----------:|-------------|
| `variables.tf` | MODIFY | Add `etcd_backup` to `cluster_configuration`, add `velero` variable, add `health_check_urls` variable |
| `guardrails.tf` | MODIFY | Add 3 check blocks: `etcd_backup_requires_s3_config`, `velero_requires_s3_config`, `velero_requires_csi` |
| `scripts/rke-master.sh.tpl` | MODIFY | Add conditional etcd S3 backup parameters to `config.yaml` |
| `main.tf` | MODIFY | Add `ETCD_BACKUP_*` to templatefile() calls, add `pre_upgrade_snapshot`, add `cluster_health_check` |
| `locals.tf` | MODIFY | Add `etcd_s3_endpoint`, `etcd_s3_folder`, `velero_*` computed locals |
| `cluster-velero.tf` | **NEW** | Velero Helm release + namespace (pattern: cluster-*.tf) |
| `templates/values/velero.yaml` | **NEW** | Velero Helm values template |
| `templates/manifests/system-upgrade-controller-server.yaml` | MODIFY | Add `prepare` for pre-snapshot |
| `output.tf` | MODIFY | Add `etcd_backup_enabled`, `velero_enabled` |
| `docs/ARCHITECTURE.md` | MODIFY | Add "Operations" section |
| `tests/variables.tftest.hcl` | MODIFY | Tests for `etcd_backup` and `velero` variable validation |
| `tests/guardrails.tftest.hcl` | MODIFY | Tests for new check blocks |
| `tests/conditional_logic.tftest.hcl` | MODIFY | Velero count assertions |
| `examples/openedx-tutor/main.tf` | MODIFY | Add example with backup + velero + health_check_urls |

---

## Verification

After implementation, run these (all safe, no credentials needed):

```bash
tofu fmt -check          # Formatting
tofu validate            # Syntax and provider schema
tofu test                # All tests (~75+ after new tests added), ~3s, $0
```

Additionally, verify in `examples/openedx-tutor/`:

```bash
cd examples/openedx-tutor
tofu init
tofu plan                # Requires credentials — run only if available
```

---

## Key Decisions

| Decision | Rationale |
|----------|-----------|
| **etcd backup via RKE2 native, not Velero** | etcd snapshot is a built-in RKE2 feature, zero dependencies, configured in cloud-init before K8s even starts. Velero requires a running cluster. |
| **Velero + Kopia for PVC backup** | Hetzner CSI does not support VolumeSnapshot (confirmed: GitHub issue #849, maintainer statement Aug 2025). Kopia is the only file-level backup path in Velero. |
| **Hetzner Object Storage as S3 target** | S3-compatible, same DC as compute (eu-central), GDPR-native, no additional provider needed. Endpoints: `{fsn1,nbg1,hel1}.your-objectstorage.com`. |
| **velero-plugin-for-aws** | Works with any S3-compatible endpoint (not just AWS). Standard Velero plugin, well-tested. |
| **S3 credential reuse between etcd and Velero** | One Hetzner Object Storage credential set for both. Velero falls back to etcd_backup credentials if its own are empty. |
| **Health check as null_resource** | Integrated into Terraform dependency graph. Triggers on `rke2_version` change. Runs at `tofu apply` time — validates upgrade before operator proceeds. |
| **`/heartbeat` as e2e check** | OpenEdx LMS endpoint, validates MySQL + MongoDB + app availability in one request. Firewall already allows 443 inbound. |
| **Pre-backup hooks for DB consistency** | `mysqldump`/`mongodump` before file-level PVC snapshot. Without this, backup may capture partially-written data. Annotations are on Tutor layer, not this module. |
| **Full etcd restore for rollback (not binary downgrade)** | Binary downgrade can leave K8s API objects in inconsistent state (migrated CRDs, changed schemas). etcd restore guarantees consistent state. |

---

## MTTR Breakdown

Target: **< 15 minutes** for HA cluster (3 masters + 3 workers, 16Gi PVC).

| Phase | Duration | Cumulative |
|-------|:--------:|:----------:|
| Stop RKE2 on all nodes | ~1 min | 1 min |
| etcd restore on master-0 | ~1 min | 2 min |
| Start master-0, wait for API | ~3 min | 5 min |
| Restart additional masters | ~2 min | 7 min |
| Restart workers | ~2 min | 9 min |
| Velero PVC restore (16Gi via Kopia) | ~3-5 min | 14 min |
| Health check pass | ~1 min | **15 min** |

Factors that increase MTTR:
- More PVC data → longer Velero restore
- S3 endpoint in different region → higher latency
- Larger etcd database → longer restore
- Network issues → SSH timeouts

---

## RPO / RTO Targets

| Metric | Target | Mechanism |
|--------|--------|-----------|
| **RPO (etcd)** | 6 hours | `etcd-snapshot-schedule-cron: "0 */6 * * *"` |
| **RPO (PVC)** | 6 hours | Velero Schedule `"0 */6 * * *"` |
| **RPO (pre-upgrade)** | 0 | On-demand snapshot before every upgrade |
| **RTO (HA cluster)** | < 15 min | etcd restore + Velero restore + health check |
| **RTO (single master)** | < 10 min | No additional masters to restart |
| **Upgrade rollback** | < 15 min | Pre-upgrade snapshot → full restore procedure |
