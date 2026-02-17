# Implementation Plan: Operational Readiness

> **Status**: Planned
> **Author**: AI-assisted (GitHub Copilot)
> **Date**: 2026-02-17
> **Scope**: Backup, Restore, Upgrade, Rollback with health checks and MTTR targets

---

## Problem Statement

The module has zero Day-2 operational capabilities:

- **No etcd backup** — RKE2 defaults to local snapshots every 12h with 5 retention, but snapshots are lost if nodes are destroyed. No off-node backup configured.
- **No PVC backup** — MySQL, MongoDB, MeiliSearch, Redis volumes (16Gi total in Tutor setup) have no backup mechanism. Hetzner CSI does not support VolumeSnapshot ([GitHub issue #849](https://github.com/hetznercloud/csi-driver/issues/849), confirmed by maintainer).
- **No health checks** — Beyond Hetzner LB health checks (TCP-level), no application-level or post-operation verification exists.
- **No upgrade procedure** — SUC exists but has no pre-upgrade snapshot and no post-upgrade health validation.
- **No rollback mechanism** — No documented or automated way to revert a failed upgrade.
- **MTTR is undefined** — No recovery time targets, no recovery procedures.

---

## Architecture

Two-layer backup with unified health check and rollback:

```
┌─────────────────────────────────────────────────────────────────┐
│                    BACKUP LAYER                                 │
│                                                                 │
│   Layer 1: etcd snapshots → Hetzner Object Storage (S3)         │
│   ├── What: Kubernetes state (deployments, services, secrets)   │
│   ├── How: RKE2 native config.yaml parameters                  │
│   ├── RPO: 6 hours (configurable via cron)                      │
│   └── MTTR: ~5 min (etcd restore on master-0)                  │
│                                                                 │
│   Layer 2: Velero + Kopia → Hetzner Object Storage (S3)         │
│   ├── What: PVC data (MySQL, MongoDB, MeiliSearch, Redis)       │
│   ├── How: File-level backup via node agent (no VolumeSnapshot) │
│   ├── RPO: 6 hours (configurable via schedule)                  │
│   └── MTTR: ~5 min (Velero restore)                             │
│                                                                 │
│   Pre-backup hooks: mysqldump + mongodump before file-level     │
│   snapshot for database consistency                              │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│                    HEALTH CHECK                                 │
│                                                                 │
│   null_resource.cluster_health_check (on master-0 via SSH)      │
│   ├── API readiness: GET /readyz = "ok"                         │
│   ├── Node readiness: all nodes Ready (count matches expected)  │
│   ├── System pods: coredns, kube-proxy, cloud-controller-mgr    │
│   ├── HTTP e2e: configurable URLs (e.g. /heartbeat for OpenEdx) │
│   └── Timeout: 600s, triggers on rke2_version change            │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│                    UPGRADE FLOW                                 │
│                                                                 │
│   rke2_version change                                           │
│   → pre_upgrade_snapshot (etcd + velero)                        │
│   → RKE2 upgrade (SUC automatic or manual restart)              │
│   → cluster_health_check                                        │
│   → IF FAIL → documented rollback (etcd restore + velero)       │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│                    ROLLBACK (monolithic)                         │
│                                                                 │
│   1. Stop RKE2 on ALL nodes                                     │
│   2. etcd restore from pre-upgrade snapshot (master-0)           │
│   3. Start master-0, wait for API                                │
│   4. Delete stale etcd data on other masters, restart            │
│   5. Velero PVC restore                                          │
│   6. Health check pass                                           │
│   MTTR: ~15 min total                                           │
└─────────────────────────────────────────────────────────────────┘
```

### MTTR Breakdown (HA cluster: 3 masters + 3 workers, 16Gi PVC)

| Phase | Time |
|-------|------|
| Stop RKE2 on all nodes | ~1 min |
| etcd restore on master-0 | ~1 min |
| Start master-0, wait for API | ~3 min |
| Restart remaining masters | ~2 min |
| Restart workers | ~2 min |
| Velero PVC restore (16Gi) | ~3-5 min |
| Health check pass | ~2 min |
| **Total MTTR** | **~15 min** |

### RPO/RTO Targets

| Metric | Target | How |
|--------|--------|-----|
| RPO (K8s state) | 6 hours | etcd snapshot schedule `0 */6 * * *` |
| RPO (PVC data) | 6 hours | Velero schedule `0 */6 * * *` |
| RTO (full cluster) | 15 min | etcd restore + Velero restore + health check |
| RTO (K8s state only) | 5 min | etcd restore only (no PVC) |

---

## Implementation Steps

### Step 1: etcd Backup to Hetzner Object Storage

RKE2 natively supports S3-compatible backup via `config.yaml` parameters. Hetzner Object Storage endpoints: `{location}.your-objectstorage.com`.

**1a. Add `etcd_backup` to `cluster_configuration` in `variables.tf`**

```hcl
cluster_configuration = object({
  # ... existing fields ...
  etcd_backup = optional(object({
    enabled        = optional(bool, false)
    schedule_cron  = optional(string, "0 */6 * * *")  # every 6 hours
    retention      = optional(number, 10)
    compress       = optional(bool, true)
    s3_endpoint    = optional(string, "")   # auto-filled from lb_location if empty
    s3_bucket      = optional(string, "")
    s3_folder      = optional(string, "")   # defaults to cluster_name
    s3_access_key  = optional(string, "")
    s3_secret_key  = optional(string, "")
    s3_region      = optional(string, "eu-central")
  }), {})
})
```

**1b. Add guardrail in `guardrails.tf`**

```hcl
check "etcd_backup_requires_s3_config" {
  assert {
    condition = (
      !var.cluster_configuration.etcd_backup.enabled ||
      (trimspace(var.cluster_configuration.etcd_backup.s3_bucket) != "" &&
       trimspace(var.cluster_configuration.etcd_backup.s3_access_key) != "" &&
       trimspace(var.cluster_configuration.etcd_backup.s3_secret_key) != "")
    )
    error_message = "etcd_backup requires s3_bucket, s3_access_key, and s3_secret_key when enabled."
  }
}
```

**1c. Modify `scripts/rke-master.sh.tpl`**

Add conditional block to generated `config.yaml`:

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

**1d. Update `templatefile()` calls in `main.tf`**

Pass `ETCD_BACKUP_*` variables to both `hcloud_server.master` and `hcloud_server.additional_masters`.

**1e. Add computed local in `locals.tf`**

```hcl
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

**1f. Add outputs in `output.tf`**

```hcl
output "etcd_backup_enabled" {
  description = "Whether etcd S3 backup is enabled"
  value       = var.cluster_configuration.etcd_backup.enabled
}
```

**Files changed**: `variables.tf`, `guardrails.tf`, `scripts/rke-master.sh.tpl`, `main.tf`, `locals.tf`, `output.tf`

---

### Step 2: Velero PVC Backup (Application Data)

Hetzner CSI has **no VolumeSnapshot support** ([issue #849](https://github.com/hetznercloud/csi-driver/issues/849)). Velero + Kopia file-level backup is the only viable approach.

Tutor PVCs: `mysql` (5Gi), `mongodb` (5Gi), `meilisearch` (5Gi), `redis` (1Gi) — 16Gi RWO on Hetzner Volumes.

**2a. Add top-level `velero` variable in `variables.tf`**

```hcl
variable "velero" {
  type = object({
    enabled         = optional(bool, false)
    version         = optional(string, "11.3.2")
    backup_schedule = optional(string, "0 */6 * * *")
    backup_ttl      = optional(string, "720h")   # 30 days
    s3_endpoint     = optional(string, "")        # reuse etcd_backup endpoint if empty
    s3_bucket       = optional(string, "")
    s3_access_key   = optional(string, "")
    s3_secret_key   = optional(string, "")
    s3_region       = optional(string, "eu-central")
  })
  default     = {}
  sensitive   = false
  description = "Velero backup for PVC data (MySQL, MongoDB, etc). Uses Kopia file-level backup to S3-compatible storage."
}
```

**2b. Create `cluster-velero.tf`**

```hcl
resource "kubernetes_namespace_v1" "velero" {
  count      = var.velero.enabled ? 1 : 0
  depends_on = [null_resource.wait_for_cluster_ready]
  metadata { name = "velero" }
}

resource "helm_release" "velero" {
  count      = var.velero.enabled ? 1 : 0
  depends_on = [kubernetes_namespace_v1.velero, helm_release.hcloud_csi]

  repository = "https://vmware-tanzu.github.io/helm-charts"
  chart      = "velero"
  name       = "velero"
  namespace  = "velero"
  version    = var.velero.version

  values = [yamlencode({
    initContainers = [{
      name            = "velero-plugin-for-aws"
      image           = "velero/velero-plugin-for-aws:v1.11.1"
      imagePullPolicy = "IfNotPresent"
      volumeMounts    = [{ mountPath = "/target", name = "plugins" }]
    }]

    configuration = {
      backupStorageLocations = [{
        name     = "hetzner-s3"
        provider = "aws"
        bucket   = local.velero_s3_bucket
        config = {
          region           = local.velero_s3_region
          s3ForcePathStyle = "true"
          s3Url            = "https://${local.velero_s3_endpoint}"
        }
        credential = {
          name = "velero-s3-credentials"
          key  = "cloud"
        }
      }]
    }

    deployNodeAgent    = true
    nodeAgentConfig    = { defaultVolumesToFsBackup = true }
    credentials        = { useSecret = false }  # managed separately

    schedules = {
      full-cluster = {
        disabled = false
        schedule = var.velero.backup_schedule
        template = {
          ttl                    = var.velero.backup_ttl
          includedNamespaces     = ["*"]
          defaultVolumesToFsBackup = true
          snapshotMoveData       = false
        }
      }
    }
  })]
}

# S3 credentials secret
resource "kubernetes_secret_v1" "velero_s3_credentials" {
  count      = var.velero.enabled ? 1 : 0
  depends_on = [kubernetes_namespace_v1.velero]

  metadata {
    name      = "velero-s3-credentials"
    namespace = "velero"
  }

  data = {
    cloud = <<-EOF
      [default]
      aws_access_key_id = ${local.velero_s3_access_key}
      aws_secret_access_key = ${local.velero_s3_secret_key}
    EOF
  }
}
```

**2c. Add computed locals in `locals.tf`**

Velero can reuse etcd backup S3 credentials when its own are empty:

```hcl
velero_s3_endpoint   = coalesce(var.velero.s3_endpoint, local.etcd_s3_endpoint)
velero_s3_bucket     = coalesce(var.velero.s3_bucket, var.cluster_configuration.etcd_backup.s3_bucket)
velero_s3_region     = coalesce(var.velero.s3_region, var.cluster_configuration.etcd_backup.s3_region, "eu-central")
velero_s3_access_key = coalesce(var.velero.s3_access_key, var.cluster_configuration.etcd_backup.s3_access_key)
velero_s3_secret_key = coalesce(var.velero.s3_secret_key, var.cluster_configuration.etcd_backup.s3_secret_key)
```

**2d. Add guardrail in `guardrails.tf`**

```hcl
check "velero_requires_s3_config" {
  assert {
    condition = (
      !var.velero.enabled ||
      (trimspace(local.velero_s3_bucket) != "" &&
       trimspace(local.velero_s3_access_key) != "")
    )
    error_message = "Velero requires S3 credentials. Set velero.s3_* or enable etcd_backup with S3 config."
  }
}

check "velero_requires_csi" {
  assert {
    condition = !var.velero.enabled || var.cluster_configuration.hcloud_csi.preinstall
    error_message = "Velero file-system backup requires CSI driver for PVC access."
  }
}
```

**Files changed**: `variables.tf`, `guardrails.tf`, `locals.tf`, `output.tf`
**Files created**: `cluster-velero.tf`

---

### Step 3: Health Check (null_resource)

Unified post-operation health check triggered by `rke2_version` changes. Runs on `master[0]` via SSH.

**3a. Add `health_check_urls` variable in `variables.tf`**

```hcl
variable "health_check_urls" {
  type        = list(string)
  default     = []
  description = "HTTP(S) URLs to check after cluster operations (e.g. ['https://lms.example.com/heartbeat']). Empty list skips HTTP checks."
}
```

**3b. Add `null_resource.cluster_health_check` in `main.tf`**

```hcl
resource "null_resource" "cluster_health_check" {
  depends_on = [null_resource.wait_for_cluster_ready]
  triggers   = { rke2_version = var.rke2_version }

  provisioner "remote-exec" {
    inline = [<<-EOT
      export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
      KC=/var/lib/rancher/rke2/bin/kubectl
      TIMEOUT=600
      ELAPSED=0

      # Check 1: API readiness
      until [ "$($KC get --raw='/readyz' 2>/dev/null)" = "ok" ]; do
        [ $ELAPSED -ge $TIMEOUT ] && echo "FAIL: API not ready" >&2 && exit 1
        sleep 5; ELAPSED=$((ELAPSED + 5))
      done
      echo "PASS: API ready"

      # Check 2: All nodes Ready
      EXPECTED=${var.master_node_count + var.worker_node_count}
      until [ "$($KC get nodes --no-headers 2>/dev/null | awk '$2=="Ready"{c++}END{print c+0}')" -ge "$EXPECTED" ]; do
        [ $ELAPSED -ge $TIMEOUT ] && echo "FAIL: nodes not ready" >&2 && exit 1
        sleep 10; ELAPSED=$((ELAPSED + 10))
      done
      echo "PASS: $EXPECTED nodes ready"

      # Check 3: System pods
      for POD in coredns kube-proxy; do
        until $KC get pods -A --field-selector=status.phase=Running -l k8s-app=$POD --no-headers 2>/dev/null | grep -q Running; do
          [ $ELAPSED -ge $TIMEOUT ] && echo "FAIL: $POD not running" >&2 && exit 1
          sleep 5; ELAPSED=$((ELAPSED + 5))
        done
        echo "PASS: $POD running"
      done

      # Check 4: HTTP e2e (optional)
      %{ for url in health_check_urls }
      HTTP_CODE=$(curl -sk -o /dev/null -w '%%{http_code}' '${url}' 2>/dev/null || echo "000")
      if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 400 ]; then
        echo "PASS: ${url} → HTTP $HTTP_CODE"
      else
        echo "FAIL: ${url} → HTTP $HTTP_CODE" >&2; exit 1
      fi
      %{ endfor }
      echo "ALL HEALTH CHECKS PASSED"
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

**Health check criteria rationale:**

| Check | What it validates | Why |
|-------|-------------------|-----|
| `/readyz` = ok | Control plane (API server, etcd, scheduler, controller) | Single endpoint covering all CP components |
| All nodes Ready | kubelet running, node registered | Ensures no node was lost during operation |
| coredns Running | DNS resolution inside cluster | Without DNS, no pod-to-service communication |
| kube-proxy Running | Service networking | Without kube-proxy, no ClusterIP routing |
| HTTP URLs (optional) | End-to-end data path: LB → ingress → pod → DB | `/heartbeat` in OpenEdx checks MySQL + MongoDB + app |

**Files changed**: `variables.tf`, `main.tf`

---

### Step 4: Pre-Upgrade Snapshot

Automatic etcd + Velero snapshot before any upgrade, triggered by `rke2_version` change.

**4a. Add `null_resource.pre_upgrade_snapshot` in `main.tf`**

```hcl
resource "null_resource" "pre_upgrade_snapshot" {
  count    = var.cluster_configuration.etcd_backup.enabled ? 1 : 0
  triggers = { rke2_version = var.rke2_version }

  provisioner "remote-exec" {
    inline = [<<-EOT
      SNAPSHOT_NAME="pre-upgrade-$(date +%Y%m%d-%H%M%S)"

      # etcd snapshot (includes S3 upload if configured)
      /var/lib/rancher/rke2/bin/rke2 etcd-snapshot save --name "$SNAPSHOT_NAME"
      echo "$SNAPSHOT_NAME" > /var/lib/rancher/rke2/server/last-pre-upgrade-snapshot

      # Velero backup (if available)
      if command -v velero &>/dev/null || /var/lib/rancher/rke2/bin/kubectl get ns velero &>/dev/null 2>&1; then
        export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
        /var/lib/rancher/rke2/bin/kubectl -n velero create job \
          --from=cronjob/velero-full-cluster "pre-upgrade-$SNAPSHOT_NAME" 2>/dev/null || true
      fi

      echo "Pre-upgrade snapshot: $SNAPSHOT_NAME"
    EOT
    ]
    connection {
      type        = "ssh"
      host        = hcloud_server.master[0].ipv4_address
      user        = "root"
      private_key = tls_private_key.machines.private_key_openssh
      timeout     = "10m"
    }
  }
}
```

**Dependency graph:**

```
rke2_version change
  → pre_upgrade_snapshot (etcd + velero)     [Step 4]
  → [RKE2 upgrade via SUC or systemctl]
  → cluster_health_check                     [Step 3]
  → IF FAIL → operator runs rollback         [Step 5]
```

**Files changed**: `main.tf`

---

### Step 5: Rollback Procedure

Full rollback = etcd state + PVC data in one operation. Documented as runbook commands.

**Rollback from pre-upgrade snapshot (HA cluster, 3 masters + 3 workers):**

```bash
# 1. Stop RKE2 on ALL nodes (workers first, then masters)
# On each worker:
systemctl stop rke2-agent.service

# On each additional master (master-1, master-2):
systemctl stop rke2-server.service

# On master-0:
systemctl stop rke2-server.service

# 2. Read the pre-upgrade snapshot name
SNAPSHOT=$(cat /var/lib/rancher/rke2/server/last-pre-upgrade-snapshot)

# 3. Restore etcd on master-0
rke2 server \
  --cluster-reset \
  --cluster-reset-restore-path="/var/lib/rancher/rke2/server/db/snapshots/$SNAPSHOT"
# Wait for "Managed etcd cluster membership has been reset" message

# 4. Start RKE2 on master-0
systemctl start rke2-server.service
# Wait for API: until kubectl get --raw='/readyz' 2>/dev/null | grep -q ok; do sleep 5; done

# 5. On each additional master: remove stale etcd data, restart
rm -rf /var/lib/rancher/rke2/server/db/etcd
systemctl start rke2-server.service

# 6. On each worker: restart
systemctl start rke2-agent.service

# 7. Velero PVC restore (if Velero was used for pre-upgrade backup)
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
velero restore create --from-backup "pre-upgrade-$SNAPSHOT" --wait

# 8. Verify health
kubectl get --raw='/readyz'                    # expect: ok
kubectl get nodes                              # expect: all Ready
kubectl get pods -A | grep -v Running          # expect: empty (all Running)
```

**S3 restore variant** (if local snapshot is unavailable):

```bash
rke2 server \
  --cluster-reset \
  --cluster-reset-restore-path="$SNAPSHOT" \
  --etcd-s3 \
  --etcd-s3-bucket="$BUCKET" \
  --etcd-s3-endpoint="$ENDPOINT" \
  --etcd-s3-access-key="$ACCESS_KEY" \
  --etcd-s3-secret-key="$SECRET_KEY" \
  --etcd-s3-region="$REGION"
```

**Rollback success criteria** (same as health check):

| Check | Pass condition |
|-------|---------------|
| API readiness | `kubectl get --raw='/readyz'` = `ok` |
| Node readiness | All expected nodes show `Ready` |
| System pods | coredns, kube-proxy Running |
| HTTP e2e | Configured URLs return 2xx/3xx |

---

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| **etcd backup via RKE2 native, not Velero** | etcd snapshot is a built-in RKE2 feature configured in `config.yaml`. Zero dependencies. Works at cloud-init level before K8s is available. Velero cannot backup etcd. |
| **Velero + Kopia for PVC backup** | Hetzner CSI has no VolumeSnapshot support (confirmed by maintainer, [issue #849](https://github.com/hetznercloud/csi-driver/issues/849)). Kopia file-level backup is the only viable path. Kopia is Velero's default since v1.14. |
| **Hetzner Object Storage as S3 target** | S3-compatible, same DC (fsn1/nbg1/hel1), GDPR-native, ~€5/mo for backup storage. No additional provider needed — uses `velero-plugin-for-aws`. |
| **Health check as null_resource** | Integrated into Terraform dependency graph. Triggered by `rke2_version` change. Runs at `tofu apply` time. |
| **`/heartbeat` as e2e check** | OpenEdx LMS endpoint that checks MySQL + MongoDB + app availability in one request. Firewall already allows 443 inbound. Full data path: LB → ingress → workers → pod → DB. |
| **Pre-backup hooks for DB consistency** | `mysqldump` / `mongodump` before file-level snapshot. Without this, PVC backup of a running database can produce inconsistent data (write-ahead log not flushed). |
| **`velero` as top-level variable** | Like `harmony`, it's a full subsystem with its own credentials, namespace, and ingress. Not a simple config toggle. |
| **`etcd_backup` inside `cluster_configuration`** | Unlike Velero, etcd backup is RKE2 server config (`config.yaml` parameters). Logically belongs to cluster infrastructure configuration. |
| **Manual rollback, not fully automatic** | Full automatic rollback (detect failure → restore) risks cascading failures. The health check detects the problem; the operator decides whether to rollback. Pre-upgrade snapshot ensures RPO=0 for the rollback. |

---

## Files Changed Summary

| File | Action | What changes |
|------|--------|-------------|
| `variables.tf` | Modify | Add `etcd_backup` to `cluster_configuration`, add `velero` object, add `health_check_urls` |
| `guardrails.tf` | Modify | Add 3 check blocks (etcd_backup S3, velero S3, velero CSI) |
| `scripts/rke-master.sh.tpl` | Modify | Add etcd S3 parameters to config.yaml (conditional block) |
| `main.tf` | Modify | Add `ETCD_BACKUP_*` to templatefile(), add `pre_upgrade_snapshot`, `cluster_health_check` |
| `locals.tf` | Modify | Add `etcd_s3_endpoint`, `etcd_s3_folder`, `velero_s3_*` computed values |
| `output.tf` | Modify | Add `etcd_backup_enabled`, `velero_enabled` |
| `cluster-velero.tf` | **Create** | Velero Helm release + Schedule + namespace + S3 secret |
| `docs/ARCHITECTURE.md` | Modify | Add "Operations: Backup, Upgrade, Rollback" section |
| `tests/variables.tftest.hcl` | Modify | Tests for new `etcd_backup` and `velero` variables |
| `tests/guardrails.tftest.hcl` | Modify | Tests for new check blocks |
| `tests/conditional_logic.tftest.hcl` | Modify | Count assertions for Velero resources |
| `examples/openedx-tutor/` | Modify | Example with backup + Velero enabled |

---

## Verification Checklist

- [ ] `tofu fmt -check` — all .tf files formatted
- [ ] `tofu validate` — syntax valid
- [ ] `tofu test` — all tests pass (existing 63 + new ~10-15)
- [ ] `tofu test -filter=tests/variables.tftest.hcl` — new variable validations
- [ ] `tofu test -filter=tests/guardrails.tftest.hcl` — new check blocks
- [ ] `tofu test -filter=tests/conditional_logic.tftest.hcl` — Velero count logic
- [ ] `tofu plan` in `examples/openedx-tutor/` with backup + velero enabled
- [ ] `tofu plan` in `examples/minimal/` with defaults (backup/velero disabled) — no regressions
- [ ] ARCHITECTURE.md updated with Operations section
- [ ] All new resources have explanatory comments per AGENTS.md conventions
