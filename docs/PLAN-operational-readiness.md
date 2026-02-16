




# Plan: Operational Readiness — Backup, Upgrade, Rollback

> **Status**: Approved plan, implementation in progress
> **Branch**: `feature/operational-readiness-plan`
> **Created**: 2026-02-15
> **Updated**: 2026-02-16 — added cluster sizing, storage architecture analysis, monitoring stack, module GAP analysis
> **Scope**: etcd backup, PVC backup (Velero/Longhorn), health check, upgrade flow, rollback procedure, cluster sizing
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
- [Appendix A: Cluster Sizing (Open edX @ 5K–15K DAU)](#appendix-a-cluster-sizing-open-edx--5k15k-dau)
- [Appendix B: Storage Architecture — Longhorn vs Hetzner CSI + Velero](#appendix-b-storage-architecture--longhorn-vs-hetzner-csi--velero)
- [Appendix C: Monitoring Stack Resource Budget](#appendix-c-monitoring-stack-resource-budget)
- [Appendix D: Module GAP Analysis](#appendix-d-module-gap-analysis)
- [Appendix E: Recommended Configuration](#appendix-e-recommended-configuration)

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
  enabled              = optional(bool, false)
  schedule_cron        = optional(string, "0 */6 * * *")   # Every 6h (RKE2 default is 12h — too infrequent for production)
  retention            = optional(number, 10)
  s3_retention         = optional(number, 10)               # S3-specific retention (separate from local). Available since RKE2 v1.34.0+.
  compress             = optional(bool, true)
  s3_endpoint          = optional(string, "")               # Auto-filled from lb_location if empty
  s3_bucket            = optional(string, "")
  s3_folder            = optional(string, "")               # Defaults to cluster_name
  s3_access_key        = optional(string, "")
  s3_secret_key        = optional(string, "")
  s3_region            = optional(string, "eu-central")
  s3_bucket_lookup_type = optional(string, "path")          # "path" required for Hetzner Object Storage
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
# DECISION: etcd backup via RKE2 native config.yaml params (zero dependencies)
# See: https://docs.rke2.io/datastore/backup_restore
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
# DECISION: Force path-style S3 access for Hetzner Object Storage
# Why: Hetzner endpoints use path-style URLs (virtual-hosted style not supported).
#      Default "auto" may attempt virtual-hosted style and fail.
# See: https://docs.hetzner.com/storage/object-storage/overview
etcd-s3-bucket-lookup-type: ${ETCD_S3_BUCKET_LOOKUP_TYPE}
# NOTE: etcd-s3-retention is separate from local etcd-snapshot-retention.
# Available since RKE2 v1.34.0+rke2r1.
# See: https://docs.rke2.io/datastore/backup_restore#s3-retention
etcd-s3-retention: ${ETCD_S3_RETENTION}
%{ endif }
```

### 1d. Update templatefile() calls

In `main.tf`, add new template variables to both `hcloud_server.master` and `hcloud_server.additional_masters` `templatefile()` calls:

```hcl
ETCD_BACKUP_ENABLED       = var.cluster_configuration.etcd_backup.enabled
ETCD_SNAPSHOT_SCHEDULE    = var.cluster_configuration.etcd_backup.schedule_cron
ETCD_SNAPSHOT_RETENTION   = var.cluster_configuration.etcd_backup.retention
ETCD_SNAPSHOT_COMPRESS    = var.cluster_configuration.etcd_backup.compress
ETCD_S3_ENDPOINT          = local.etcd_s3_endpoint
ETCD_S3_BUCKET            = var.cluster_configuration.etcd_backup.s3_bucket
ETCD_S3_FOLDER            = local.etcd_s3_folder
ETCD_S3_ACCESS_KEY        = var.cluster_configuration.etcd_backup.s3_access_key
ETCD_S3_SECRET_KEY        = var.cluster_configuration.etcd_backup.s3_secret_key
ETCD_S3_REGION            = var.cluster_configuration.etcd_backup.s3_region
ETCD_S3_BUCKET_LOOKUP_TYPE = var.cluster_configuration.etcd_backup.s3_bucket_lookup_type
ETCD_S3_RETENTION         = var.cluster_configuration.etcd_backup.s3_retention
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
    enabled              = optional(bool, false)
    version              = optional(string, "11.3.2")       # Helm chart version (app version: v1.17.1)
    plugin_version       = optional(string, "v1.13.2")      # velero-plugin-for-aws version (must match Velero app version)
    backup_schedule      = optional(string, "0 */6 * * *")  # Synchronized with etcd schedule
    backup_ttl           = optional(string, "720h")          # 30 days retention
    s3_endpoint          = optional(string, "")               # Auto-filled from lb_location if empty
    s3_bucket            = optional(string, "")
    s3_access_key        = optional(string, "")
    s3_secret_key        = optional(string, "")
    s3_region            = optional(string, "eu-central")
    s3_bucket_lookup_type = optional(string, "path")          # "path" required for Hetzner Object Storage
    extra_values         = optional(list(string), [])
  })
  default     = {}
  sensitive   = false  # But s3_access_key/s3_secret_key are passed to Helm via sensitive values
  description = <<-EOT
    Velero backup infrastructure for PVC data protection.
    Uses Kopia file-level backup (Hetzner CSI does not support VolumeSnapshot).
    Targets S3-compatible storage (Hetzner Object Storage recommended).

    IMPORTANT: velero-plugin-for-aws plugin_version must match the Velero app
    version shipped in the chart. Chart 11.3.2 ships Velero v1.17.1, which
    requires plugin v1.13.x. See compatibility matrix:
    https://github.com/vmware-tanzu/velero-plugin-for-aws#compatibility

    NOTE: S3 credentials are independent from etcd_backup S3 credentials.
    Each component manages its own config (module self-contained addon pattern).
    Share credentials at the module invocation level if desired.
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
#      confirmed by maintainer Aug 2025). Kopia is the only viable file-level
#      backup path. Restic was deprecated in Velero v1.15 and fully removed
#      in v1.17 — Kopia is the sole uploader.
# See: https://github.com/hetznercloud/csi-driver/issues/849
# See: https://velero.io/docs/main/file-system-backup/
#
# WORKAROUND: checksumAlgorithm="" in BSL config for Hetzner Object Storage
# Why: aws-sdk-go-v2 (used by velero-plugin-for-aws v1.13.x) adds aws-chunked
#      transfer encoding that Hetzner S3 does not support (HTTP 400).
# See: https://github.com/vmware-tanzu/velero/issues/8660
# TODO: Remove when Hetzner adds aws-chunked support or Velero switches to minio-go
# ──────────────────────────────────────────────────────────────────────────────

# Cross-variable safety checks
check "velero_requires_s3_config" {
  assert {
    condition = (
      !var.velero.enabled ||
      (
        trimspace(var.velero.s3_bucket) != "" &&
        trimspace(var.velero.s3_access_key) != "" &&
        trimspace(var.velero.s3_secret_key) != ""
      )
    )
    error_message = "velero.enabled=true requires s3_bucket, s3_access_key, and s3_secret_key to be set."
  }
}

check "velero_requires_csi" {
  assert {
    condition = !var.velero.enabled || var.cluster_configuration.hcloud_csi.preinstall
    error_message = "Velero backs up PVCs provisioned by CSI. Set cluster_configuration.hcloud_csi.preinstall=true when velero.enabled=true."
  }
}

locals {
  # DECISION: Auto-detect Hetzner Object Storage endpoint from lb_location for Velero.
  # Why: Reduces configuration burden — operator only needs bucket + credentials.
  # See: https://docs.hetzner.com/storage/object-storage/overview
  velero_s3_endpoint = (
    trimspace(var.velero.s3_endpoint) != ""
    ? var.velero.s3_endpoint
    : "${var.lb_location}.your-objectstorage.com"
  )

  velero_values = {
    initContainers = [
      {
        # DECISION: velero-plugin-for-aws version must match Velero app version
        # Why: Plugin uses aws-sdk-go-v2 starting from v1.9.x. Compatibility matrix
        #      requires v1.13.x for Velero v1.17.x (chart 11.3.2 = app v1.17.1).
        #      Using v1.11.x (for Velero v1.15.x) would cause silent backup failures.
        # See: https://github.com/vmware-tanzu/velero-plugin-for-aws#compatibility
        name            = "velero-plugin-for-aws"
        image           = "velero/velero-plugin-for-aws:${var.velero.plugin_version}"
        imagePullPolicy = "IfNotPresent"
        volumeMounts = [{
          mountPath = "/target"
          name      = "plugins"
        }]
      }
    ]

    # DECISION: Deploy node-agent DaemonSet for Kopia file-level backup
    # Why: Required for File System Backup (FSB). Node agent mounts PV via
    #      hostPath (/var/lib/kubelet/pods) and copies files to S3.
    # See: https://velero.io/docs/main/file-system-backup/
    deployNodeAgent = true
    nodeAgent = {
      podVolumePath = "/var/lib/kubelet/pods"
    }

    # DECISION: Disable VolumeSnapshotLocation — Hetzner CSI does not support VolumeSnapshot
    # Why: Chart creates a VolumeSnapshotLocation CRD by default. Without a CSI
    #      snapshot driver, it stays in "Unavailable" status and generates error logs.
    #      We use Kopia file-level backup instead (defaultVolumesToFsBackup: true).
    # See: https://github.com/hetznercloud/csi-driver/issues/849
    snapshotsEnabled = false

    configuration = {
      # DECISION: Opt-out approach — all PVCs backed up by default via Kopia FSB
      # Why: Safer default. New PVCs are automatically included in backup.
      #      Operators can exclude specific PVCs via Velero annotations if needed.
      defaultVolumesToFsBackup = true

      # NOTE: The Helm chart key is "backupStorageLocation" (singular).
      # It accepts a list of BSL configs. Do NOT use "backupStorageLocations" (plural).
      # See: https://github.com/vmware-tanzu/helm-charts/blob/main/charts/velero/values.yaml
      backupStorageLocation = [
        {
          name     = "default"
          provider = "aws"
          bucket   = var.velero.s3_bucket
          default  = true
          config = {
            region = var.velero.s3_region
            # DECISION: Force path-style S3 access for Hetzner Object Storage
            # Why: Hetzner endpoints use path-style URLs (virtual-hosted style not supported).
            # See: https://docs.hetzner.com/storage/object-storage/overview
            s3ForcePathStyle = "true"
            s3Url            = "https://${local.velero_s3_endpoint}"
            # WORKAROUND: Disable checksum for Hetzner Object Storage compatibility
            # Why: velero-plugin-for-aws v1.13.x uses aws-sdk-go-v2, which adds
            #      aws-chunked transfer encoding + CRC32 checksum by default.
            #      Hetzner Object Storage returns HTTP 400 "Transfering payloads in
            #      multiple chunks using aws-chunked is not supported".
            #      Setting checksumAlgorithm="" disables this behavior.
            # See: https://github.com/vmware-tanzu/velero/issues/8660 (Hetzner-specific)
            # See: https://github.com/vmware-tanzu/velero/issues/8265 (tracking issue)
            # TODO: Remove when Hetzner adds aws-chunked support or Velero switches to minio-go SDK
            checksumAlgorithm = ""
          }
          credential = {
            name = "velero-s3-credentials"
            key  = "cloud"
          }
        }
      ]
    }

    credentials = {
      secretContents = {
        cloud = <<-EOT
          [default]
          aws_access_key_id=${var.velero.s3_access_key}
          aws_secret_access_key=${var.velero.s3_secret_key}
        EOT
      }
    }

    schedules = {
      full-cluster = {
        disabled                    = false
        schedule                    = var.velero.backup_schedule
        useOwnerReferencesInBackup = false
        template = {
          ttl                        = var.velero.backup_ttl
          includedNamespaces         = ["*"]
          defaultVolumesToFsBackup   = true
        }
      }
    }
  }
}

resource "kubernetes_namespace_v1" "velero" {
  depends_on = [null_resource.wait_for_cluster_ready]
  count      = var.velero.enabled ? 1 : 0
  metadata {
    name = "velero"
  }
  lifecycle {
    ignore_changes = [
      metadata[0].annotations,
      metadata[0].labels,
    ]
  }
}

resource "helm_release" "velero" {
  depends_on = [
    kubernetes_namespace_v1.velero,
    helm_release.hcloud_csi,  # PVCs must be provisionable before backup
  ]
  count      = var.velero.enabled ? 1 : 0
  repository = "https://vmware-tanzu.github.io/helm-charts"
  chart      = "velero"
  name       = "velero"
  namespace  = "velero"
  version    = var.velero.version
  timeout    = 600

  values = concat([yamlencode(local.velero_values)], var.velero.extra_values)
}
```

### 2c. Guardrails

> **NOTE:** The `check` blocks are included inline in `cluster-velero.tf` (shown above in Step 2b)
> rather than in a separate `guardrails.tf` section.
>
> **DECISION:** Inline checks vs. centralized `guardrails.tf`
> It follows the self-contained addon pattern — each `cluster-*.tf` owns its own validation.
> Existing `guardrails.tf` checks cross two+ variables that don't belong to a single addon.
> Velero checks reference only `var.velero.*` fields, so they belong with the resource.

Two guardrails enforce deployment safety:

| Check | Condition | Rationale |
|-------|-----------|---------- |
| `velero_requires_s3_config` | `s3_bucket`, `s3_access_key`, `s3_secret_key` must be non-empty when `enabled=true` | Prevents Helm release from deploying with no BSL credentials (silent backup failure) |
| `velero_requires_csi` | `hcloud_csi.preinstall` must be `true` when `enabled=true` | Velero FSB needs PVCs to exist. Without CSI driver, no PVCs are provisioned. |

### 2d. Hetzner S3 Compatibility Risk

> **WARNING:** Hetzner Object Storage is **not listed** in Velero's verified S3 providers.
> The `checksumAlgorithm=""` workaround is community-sourced and may break with future
> Velero or plugin updates.

| Risk | Impact | Mitigation |
|------|--------|------------|
| `aws-chunked` transfer encoding rejected | Backup fails with HTTP 400 | `checksumAlgorithm: ""` in BSL config |
| Workaround may stop working in future Velero versions | Backup silently breaks after upgrade | Pin `plugin_version`, test before upgrade |
| Rate limit 750 req/s on Hetzner Object Storage | Large restores may be throttled | Monitor restore logs for HTTP 429/503 |

**References:**
- https://github.com/vmware-tanzu/velero/issues/8660 (Hetzner-specific)
- https://github.com/vmware-tanzu/velero/issues/8265 (aws-sdk-go-v2 tracking)
- https://docs.hetzner.com/storage/object-storage/overview (rate limits)

**E2E test requirement:** Before merging, run a full backup+restore cycle against Hetzner Object Storage
to verify the workaround works end-to-end. See Verification section below.

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
| `guardrails.tf` | MODIFY | Add 1 check block: `etcd_backup_requires_s3_config` |
| `scripts/rke-master.sh.tpl` | MODIFY | Add conditional etcd S3 backup parameters to `config.yaml` |
| `main.tf` | MODIFY | Add `ETCD_BACKUP_*` to templatefile() calls, add `pre_upgrade_snapshot`, add `cluster_health_check` |
| `locals.tf` | MODIFY | Add `etcd_s3_endpoint`, `etcd_s3_folder` computed locals |
| `cluster-velero.tf` | **NEW** | Velero Helm release + namespace + guardrails + values (self-contained addon pattern) |
| `templates/manifests/system-upgrade-controller-server.yaml` | MODIFY | Add `prepare` for pre-snapshot |
| `output.tf` | MODIFY | Add `etcd_backup_enabled`, `velero_enabled` |
| `docs/ARCHITECTURE.md` | MODIFY | Add "Operations" section, update Compromise Log |
| `tests/variables.tftest.hcl` | MODIFY | Tests for `etcd_backup` and `velero` variable validation |
| `tests/guardrails.tftest.hcl` | MODIFY | Tests for `etcd_backup_requires_s3_config` check block |
| `tests/conditional_logic.tftest.hcl` | MODIFY | Velero namespace + Helm release count assertions |
| `examples/openedx-tutor/main.tf` | MODIFY | Add example with backup + velero + health_check_urls |

---

## Verification

After implementation, run these (all safe, no credentials needed):

```bash
tofu fmt -check          # Formatting
tofu validate            # Syntax and provider schema (run in test-rke2-module/, NOT in module root)
tofu test                # All tests (~75+ after new tests added), ~3s, $0
```

Additionally, verify in `examples/openedx-tutor/`:

```bash
cd examples/openedx-tutor
tofu init
tofu plan                # Requires credentials — run only if available
```

### E2E Backup Verification (REQUIRED before merge)

> **WARNING:** The Hetzner S3 `checksumAlgorithm=""` workaround is community-sourced.
> Automated unit tests cannot validate S3 I/O. A manual E2E test is mandatory.

```bash
# 1. Deploy cluster with Velero enabled
# 2. Create a test PVC + Pod that writes known data
# 3. Run: velero backup create test-backup --wait
# 4. Verify backup completed: velero backup describe test-backup
# 5. Delete the PVC + Pod
# 6. Run: velero restore create --from-backup test-backup --wait
# 7. Verify restored PVC contains the original data
# 8. Check Velero logs for any aws-chunked or checksum errors
```

If step 3 fails with HTTP 400 referencing `aws-chunked`, the `checksumAlgorithm` workaround
needs adjustment. Check https://github.com/vmware-tanzu/velero/issues/8660 for updates.

---

## Key Decisions

| Decision | Rationale |
|----------|-----------|
| **etcd backup via RKE2 native, not Velero** | etcd snapshot is a built-in RKE2 feature, zero dependencies, configured in cloud-init before K8s even starts. Velero requires a running cluster. |
| **Velero + Kopia for PVC backup** | Hetzner CSI does not support VolumeSnapshot (confirmed: GitHub issue #849, maintainer statement Aug 2025). Kopia is the only file-level backup path in Velero (Restic removed in v1.17). |
| **Hetzner Object Storage as S3 target** | S3-compatible, same DC as compute (eu-central), GDPR-native, no additional provider needed. Endpoints: `{fsn1,nbg1,hel1}.your-objectstorage.com`. |
| **velero-plugin-for-aws v1.13.x** | Compatibility matrix requires v1.13.x for Velero v1.17.x. Uses aws-sdk-go-v2, which requires `checksumAlgorithm=""` workaround for Hetzner S3. See: [compatibility matrix](https://github.com/vmware-tanzu/velero-plugin-for-aws#compatibility). |
| **`checksumAlgorithm=""` workaround** | aws-sdk-go-v2 adds `aws-chunked` transfer encoding that Hetzner S3 rejects (HTTP 400). Community-sourced workaround from [issue #8660](https://github.com/vmware-tanzu/velero/issues/8660). E2E validation required before merge. |
| **Separate S3 credentials (etcd vs Velero)** | Module's self-contained addon pattern — each `cluster-*.tf` owns its own configuration. `coalesce("","")` causes runtime errors. Operators can share credentials at module invocation level: `s3_access_key = var.shared_key`. |
| **`snapshotsEnabled: false`** | Hetzner CSI has no VolumeSnapshot driver. Leaving default `true` creates an unavailable VolumeSnapshotLocation CRD that generates error logs. |
| **`s3ForcePathStyle: "true"`** | Hetzner Object Storage supports path-style only (virtual-hosted style not available). Also required for `etcd-s3-bucket-lookup-type: path`. |
| **Velero guardrails inline in cluster-velero.tf** | Self-contained addon pattern — each addon file owns its validation. `guardrails.tf` is for cross-addon checks only. |
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

---

## Appendix A: Cluster Sizing (Open edX @ 5K–15K DAU)

> **Context:** All calculations target a self-hosted Open edX instance deployed via Tutor
> on top of this module's RKE2 cluster. DAU = Daily Active Users (concurrent learners).

### Hetzner Cloud Server Specifications

Live data from Hetzner Cloud API (verified February 2026):

| Type | vCPU | RAM (GB) | SSD (GB) | Network | Price/mo (EUR) |
|------|:----:|:--------:|:--------:|---------|:--------------:|
| CX23 | 2 | 4 | 40 | Shared 10 Gbit | ~3.99 |
| CX33 | 4 | 8 | 80 | Shared 10 Gbit | 5.49 |
| CX43 | 8 | 16 | 160 | Shared 10 Gbit | 9.49 |
| CX53 | 16 | 32 | 320 | Shared 10 Gbit | 17.49 |
| lb11 | — | — | — | 25 Mbps included | 5.49 |

> NOTE: "Shared 10 Gbit" means the physical host has a 10 Gbit NIC shared among all VMs.
> Real-world per-VM throughput is typically 1–3 Gbit/s depending on host load.

### Open edX Component Resource Requirements

Resource estimates for a single-instance Tutor deployment at different DAU levels:

| Component | 5K DAU | 10K DAU | 15K DAU | Notes |
|-----------|:------:|:-------:|:-------:|-------|
| **LMS** (gunicorn, 5 workers) | 1.5C / 2.0G | 3.0C / 3.5G | 4.5C / 5.0G | Heaviest component; scales linearly with DAU |
| **CMS** (Studio) | 0.5C / 1.0G | 0.5C / 1.0G | 0.8C / 1.5G | Low traffic; only course authors |
| **Celery** (workers + beat) | 0.5C / 0.5G | 1.0C / 1.0G | 1.5C / 1.5G | Async tasks: grading, emails, certificates |
| **MySQL 8.0** | 1.0C / 3.0G | 1.5C / 5.0G | 2.0C / 8.0G | `innodb_buffer_pool_size` dominates RAM |
| **MongoDB 7.x** | 0.5C / 3.0G | 0.8C / 3.5G | 1.0C / 5.0G | WiredTiger cache = 50% of allocated RAM |
| **Redis** | 0.3C / 0.5G | 0.3C / 0.5G | 0.5C / 1.0G | Cache + Celery broker |
| **Elasticsearch / MeiliSearch** | 0.5C / 1.0G | 0.5C / 1.5G | 0.8C / 2.0G | Course search indexing |
| **Caddy / nginx** | 0.2C / 0.2G | 0.2C / 0.2G | 0.3C / 0.3G | Reverse proxy |
| **Subtotal (workload)** | **5.0C / 11.2G** | **7.8C / 16.2G** | **11.4C / 24.3G** | — |

### Variant A: Minimal (5K DAU, no HA)

Single master, minimal workers. No fault tolerance.

| Role | Count | Type | vCPU | RAM (GB) | Purpose |
|------|:-----:|------|:----:|:--------:|---------|
| Master | 1 | CX23 | 2 | 4 | Control plane |
| Worker | 2 | CX33 | 8 | 16 | All workloads |
| LB (CP) | 1 | lb11 | — | — | API server |
| LB (Ingress) | 1 | lb11 | — | — | HTTP/HTTPS |
| **Total** | | | **10** | **20** | **~€38.96/mo** |

- **Pros:** Cheapest option
- **Cons:** Single master = single point of failure. etcd quorum lost if master dies. No rolling upgrade.

### Variant B: Recommended (5K DAU, basic HA)

3 masters for etcd quorum, 2 workers for workload distribution.

| Role | Count | Type | vCPU | RAM (GB) | Purpose |
|------|:-----:|------|:----:|:--------:|---------|
| Master | 3 | CX23 | 6 | 12 | Control plane + etcd quorum |
| Worker | 2 | CX33 | 8 | 16 | All workloads |
| LB (CP) | 1 | lb11 | — | — | API server |
| LB (Ingress) | 1 | lb11 | — | — | HTTP/HTTPS |
| **Total** | | | **14** | **28** | **~€43.94/mo** |

- **Pros:** etcd survives 1 master failure. Rolling upgrades possible.
- **Cons:** Workers have ~11% RAM headroom (tight for spikes).

### Variant C: Production HA (5K–10K DAU, with Longhorn + Monitoring)

3 masters (CX33) for headroom, 4 workers (CX43) for workload isolation, Longhorn distributed storage, full monitoring stack (Prometheus + Grafana + Loki).

| Role | Count | Type | vCPU | RAM (GB) | SSD (GB) | Purpose |
|------|:-----:|------|:----:|:--------:|:--------:|---------|
| Master | 3 | CX33 | 12 | 24 | 240 | Control plane + etcd |
| Worker | 4 | CX43 | 32 | 64 | 640 | App + DB + Monitoring |
| LB (CP) | 1 | lb11 | — | — | — | API server |
| LB (Ingress) | 1 | lb11 | — | — | — | HTTP/HTTPS |
| **Cluster total** | **7** | | **44** | **88** | **880** | **~€66.41/mo** |

#### Per-Node Resource Budget (Variant C)

Detailed breakdown showing system overhead, Kubernetes components, Longhorn, and workload:

**Master nodes (CX33: 4C / 8G each):**

| Layer | CPU | RAM | Notes |
|-------|----:|----:|-------|
| OS + systemd | 0.2C | 0.3G | Ubuntu 24.04 baseline |
| kubelet + kube-proxy | 0.3C | 0.5G | — |
| etcd | 0.5C | 0.5G | 3-node quorum, fsync-heavy |
| kube-apiserver | 0.5C | 0.8G | Scales with watch count |
| kube-scheduler + controller-manager | 0.2C | 0.3G | — |
| RKE2 agent | 0.1C | 0.2G | — |
| Longhorn DaemonSet (manager) | 0.25C | 0.26G | Per-node overhead |
| Longhorn instance-manager (engine) | 0.1C | 0.08G | 2 volumes × ~50m/40Mi each |
| Longhorn instance-manager (replica) | 0.15C | 0.12G | 3 replicas × ~50m/40Mi each |
| **Used** | **2.3C** | **3.1G** | — |
| **Free** | **1.7C (42%)** | **4.9G (61%)** | Comfortable headroom |

**Worker nodes (CX43: 8C / 16G each) — "Worker-DB" hosting MySQL + MongoDB:**

| Layer | CPU | RAM | Notes |
|-------|----:|----:|-------|
| OS + systemd | 0.2C | 0.3G | — |
| kubelet + kube-proxy | 0.3C | 0.5G | — |
| RKE2 agent | 0.1C | 0.2G | — |
| Longhorn DaemonSet (manager) | 0.25C | 0.26G | — |
| Longhorn instance-manager (engine) | 0.15C | 0.12G | 3 volumes |
| Longhorn instance-manager (replica) | 0.25C | 0.20G | 5 replicas |
| MySQL 8.0 | 1.0C | 3.0G | `innodb_buffer_pool_size=2G` + overhead |
| MongoDB 7.x | 0.5C | 3.0G | WiredTiger cache ~1.5G |
| Redis | 0.3C | 0.5G | — |
| Elasticsearch / MeiliSearch | 0.5C | 1.0G | — |
| Longhorn cluster-wide pods* | 0.4C | 0.5G | UI, driver, CSI plugin (shared) |
| **Used** | **3.95C** | **9.58G** | — |
| **Free** | **4.05C (51%)** | **6.42G (40%)** | Adequate |

> *Longhorn cluster-wide pods (longhorn-ui, longhorn-csi-plugin, longhorn-driver-deployer) run on one node but are counted in the DB worker budget as worst case.

**Worker nodes (CX43: 8C / 16G each) — "Worker-App" hosting LMS + CMS:**

| Layer | CPU | RAM | Notes |
|-------|----:|----:|-------|
| OS + systemd | 0.2C | 0.3G | — |
| kubelet + kube-proxy | 0.3C | 0.5G | — |
| RKE2 agent | 0.1C | 0.2G | — |
| Longhorn DaemonSet (manager) | 0.25C | 0.26G | — |
| Longhorn instance-manager (engine) | 0.1C | 0.08G | 2 volumes |
| Longhorn instance-manager (replica) | 0.15C | 0.12G | 3 replicas |
| LMS (gunicorn, 5 workers) | 1.5C | 2.0G | Primary CPU consumer |
| CMS (Studio) | 0.5C | 1.0G | — |
| Celery (workers + beat) | 0.5C | 0.5G | — |
| Caddy / nginx | 0.2C | 0.2G | — |
| ingress-nginx (Harmony) | 0.3C | 0.3G | DaemonSet + hostPort |
| **Used** | **4.10C** | **5.46G** | — |
| **Free** | **3.90C (49%)** | **10.54G (66%)** | Comfortable |

**Worker nodes (CX43: 8C / 16G each) — "Worker-Monitoring":**

| Layer | CPU | RAM | Notes |
|-------|----:|----:|-------|
| OS + systemd | 0.2C | 0.3G | — |
| kubelet + kube-proxy | 0.3C | 0.5G | — |
| RKE2 agent | 0.1C | 0.2G | — |
| Longhorn DaemonSet (manager) | 0.25C | 0.26G | — |
| Longhorn instance-manager (engine) | 0.15C | 0.12G | 3 volumes (Prometheus, Loki, Grafana) |
| Longhorn instance-manager (replica) | 0.25C | 0.20G | 5 replicas |
| Prometheus (server) | 1.0C | 2.0G | 15-day retention, ~200 series/node |
| Grafana | 0.3C | 0.5G | Dashboards + alerting |
| Alertmanager | 0.1C | 0.1G | — |
| Loki (log aggregation) | 0.5C | 1.0G | 7-day retention |
| Promtail DaemonSet | 0.1C | 0.1G | Runs on all nodes, counted once |
| **Used** | **3.25C** | **5.28G** | — |
| **Free** | **4.75C (59%)** | **10.72G (67%)** | Most headroom |

### Scaling to 15K DAU

At 15K peak DAU, the following components hit resource ceilings:

| Component | 5K DAU | 15K DAU | Scaling factor | Bottleneck |
|-----------|:------:|:-------:|:--------------:|------------|
| LMS | 1.5C / 2.0G | 4.5C / 5.0G | 3× | CPU (gunicorn workers) |
| Celery | 0.5C / 0.5G | 1.5C / 1.5G | 3× | CPU (task processing) |
| MySQL | 1.0C / 3.0G | 2.0C / 8.0G | 2×C, 2.7×RAM | RAM (`buffer_pool`) |
| MongoDB | 0.5C / 3.0G | 1.0C / 5.0G | 2×C, 1.7×RAM | RAM (WiredTiger cache) |

**Where the Variant C cluster breaks at 15K:**

| Node role | 5K utilization | 15K utilization | Status |
|-----------|:--------------:|:---------------:|--------|
| Master (CX33) | 58% CPU / 39% RAM | ~70% CPU / 45% RAM | ✅ OK |
| Worker-DB (CX43) | 51% CPU / 60% RAM | ~80% CPU / 134% RAM | ❌ OOM — needs CX53 |
| Worker-App (CX43) | 51% CPU / 34% RAM | ~183% CPU / 55% RAM | ❌ CPU exhausted — needs 2 nodes |
| Worker-Mon (CX43) | 41% CPU / 33% RAM | ~50% CPU / 40% RAM | ✅ OK |

**Scaled cluster for 15K DAU:**

| Role | Count | Type | vCPU | RAM (GB) | SSD (GB) | Change from 5K |
|------|:-----:|------|:----:|:--------:|:--------:|----------------|
| Master | 3 | CX33 | 12 | 24 | 240 | No change |
| Worker-DB | 1 | CX53 | 16 | 32 | 320 | CX43 → CX53 (+16G RAM) |
| Worker-App | 2 | CX43 | 16 | 32 | 320 | 1 → 2 nodes (double CPU) |
| Worker-App2 | 1 | CX33 | 4 | 8 | 80 | Additional LMS replica |
| Worker-Mon | 1 | CX43 | 8 | 16 | 160 | No change |
| LB (CP) | 1 | lb11 | — | — | — | No change |
| LB (Ingress) | 1 | lb11 | — | — | — | No change |
| **Total** | **9** | | **56** | **112** | **1120** | **~€71.39/mo** |

### Network Bandwidth Analysis

Longhorn replication factor 3 (RF=3) creates significant write amplification:

| Scenario | Write rate | Network (RF=3) | Notes |
|----------|:----------:|:--------------:|-------|
| Steady state (5K DAU) | ~5 MB/s | ~15 MB/s (120 Mbit/s) | MySQL WAL, MongoDB journal, Redis AOF |
| Burst (bulk import) | ~50 MB/s | ~150 MB/s (1.2 Gbit/s) | Course import, bulk enrollment |
| Velero backup (16G PVC) | ~100 MB/s | ~300 MB/s (2.4 Gbit/s) | Sequential read, no replication |
| Peak combined | — | ~280 Mbit/s sustained | Below 10 Gbit shared NIC, comfortable |

> NOTE: Longhorn RF=3 means each write is replicated to 3 nodes. A 50 MB/s application write
> becomes 150 MB/s of network traffic (50 MB/s × 3 replicas). This is the dominant
> network consumer in the cluster.

### MySQL Single-Instance Ceiling

MySQL 8.0 in single-instance mode (no read replicas) has a practical ceiling:

| DAU | Estimated QPS | buffer_pool | CPU | Status |
|:---:|:------------:|:-----------:|:---:|:------:|
| 5K | ~500 | 2G | 1.0C | ✅ Comfortable |
| 10K | ~1000 | 4G | 1.5C | ✅ OK |
| 15K | ~1500 | 6G | 2.0C | ⚠️ Tight |
| 25K | ~2500 | 10G | 3.5C | ❌ Connection limit / lock contention |

Beyond ~25K DAU, MySQL needs either read replicas (ProxySQL/MaxScale) or migration to a managed
database (Hetzner Managed MySQL, AWS RDS). This is a Tutor-layer decision, not a module concern.

---

## Appendix B: Storage Architecture — Longhorn vs Hetzner CSI + Velero

### Backup Chain Comparison

Three possible backup architectures for PVC data:

| Architecture | Chain | S3 needed? | Pros | Cons |
|-------------|-------|:----------:|------|------|
| **Velero + Kopia** | PVC → Velero node-agent (Kopia) → S3 | Yes | Module-integrated, proven, scheduled | Extra component (Velero), Hetzner S3 workaround (`checksumAlgorithm=""`) |
| **Longhorn Backup** | PVC → Longhorn snapshot → S3 | Yes | Integrated with storage layer, incremental | Same S3 dependency, Longhorn-specific restore workflow |
| **Hetzner Server Snapshot** | Local SSD → Hetzner API snapshot | No | Zero S3 dependency, captures full OS state | Not PVC-level, entire server, slow restore, €0.012/GB/mo |

> KEY INSIGHT: Both Velero and Longhorn backups ultimately target S3-compatible storage.
> Longhorn does NOT eliminate the S3 dependency — it just changes which component talks to S3.

### Longhorn vs Hetzner CSI Volumes

| Criterion | Hetzner CSI Volumes | Longhorn (local SSD) |
|-----------|:-------------------:|:--------------------:|
| **Storage type** | Network-attached block (Ceph-based) | Local NVMe SSD (server disk) |
| **Replication** | Hetzner-managed (3×) | Longhorn-managed (RF=3) |
| **IOPS** | ~5,000–10,000 (spec) | ~50,000–100,000 (NVMe) |
| **Latency** | ~0.5–1ms (network hop) | ~0.1–0.2ms (local) |
| **Cost per GB** | €0.052/GB/mo | €0 (included in server SSD) |
| **16G total storage cost** | €0.83/mo | €0 |
| **160G total storage cost** | €8.32/mo | €0 |
| **VolumeSnapshot support** | ❌ No (GitHub #849) | ✅ Yes (native snapshots) |
| **Backup to S3** | Via Velero (external) | Native (built-in backup feature) |
| **Data locality** | Always network hop | Replica may be local (0 hop) |
| **Node failure tolerance** | Volume survives (detach/reattach) | RF=3 survives 2 node failures |
| **Cluster overhead** | ~0.3C / 0.4G (CSI driver only) | ~4.8C / 5.1G (full Longhorn) |
| **Operational complexity** | Low (managed by Hetzner) | Higher (manage replicas, rebuilds, monitoring) |

### Longhorn Resource Overhead (Detailed)

Longhorn runs several components across the cluster:

**Cluster-wide pods (scheduled once):**

| Component | CPU | RAM | Notes |
|-----------|----:|----:|-------|
| longhorn-manager (leader) | 0.3C | 0.3G | Orchestrates volume management |
| longhorn-ui | 0.1C | 0.1G | Web UI for monitoring |
| longhorn-driver-deployer | 0.1C | 0.1G | CSI driver lifecycle |
| longhorn-csi-plugin | 0.2C | 0.2G | CSI interface |
| longhorn-admission-webhook | 0.1C | 0.1G | Validates Longhorn resources |
| longhorn-conversion-webhook | 0.1C | 0.1G | CRD version conversion |
| longhorn-recovery-backend | 0.1C | 0.1G | Backup/restore coordination |
| **Subtotal** | **1.0C** | **1.0G** | — |

**Per-node DaemonSet pods:**

| Component | CPU | RAM | Notes |
|-----------|----:|----:|-------|
| longhorn-manager (per node) | 0.25C | 0.26G | Node-local volume operations |
| instance-manager-e (engine) | varies | varies | 1 per volume on this node (~50m/40Mi each) |
| instance-manager-r (replica) | varies | varies | 1 per replica on this node (~50m/40Mi each) |

**Total Longhorn overhead for Variant C (7 nodes, 5 volumes × RF=3):**

| Metric | Value | % of cluster (44C / 88G) |
|--------|------:|:------------------------:|
| CPU | ~4.8C | 11% |
| RAM | ~5.1G | 6% |

### When to Choose Which

| Use case | Recommendation | Rationale |
|----------|---------------|-----------|
| Dev/staging, small data (<20G) | Hetzner CSI + Velero | Simpler, cheaper overhead |
| Production, DB-heavy (MySQL/MongoDB) | Longhorn | Better IOPS, native snapshots, no VolumeSnapshot gap |
| Budget-constrained (<€40/mo) | Hetzner CSI (no backup) | Longhorn overhead is 5G RAM |
| Strict RPO requirements (<1h) | Longhorn | Built-in recurring snapshots + S3 backup |

---

## Appendix C: Monitoring Stack Resource Budget

Full observability stack for production cluster:

### Component Breakdown

| Component | CPU | RAM | Storage | Purpose |
|-----------|----:|----:|--------:|---------|
| **Prometheus** (server) | 1.0C | 2.0G | 30G | Metrics collection, 15-day retention |
| **Grafana** | 0.3C | 0.5G | 2G | Dashboards, alerting UI |
| **Alertmanager** | 0.1C | 0.1G | 1G | Alert routing, deduplication |
| **Loki** | 0.5C | 1.0G | 20G | Log aggregation, 7-day retention |
| **Promtail** (DaemonSet) | 0.1C×N | 0.1G×N | — | Log shipping from each node |
| **kube-state-metrics** | 0.1C | 0.1G | — | K8s object metrics |
| **node-exporter** (DaemonSet) | 0.1C×N | 0.05G×N | — | Host-level metrics |
| **Total (7 nodes)** | **~3.4C** | **~4.8G** | **53G** | — |

> NOTE: Promtail and node-exporter are DaemonSets — they run on every node.
> With 7 nodes: Promtail = 0.7C / 0.7G, node-exporter = 0.7C / 0.35G.

### Helm Chart

Recommended: `kube-prometheus-stack` (community chart, includes Prometheus + Grafana + Alertmanager
+ kube-state-metrics + node-exporter) + separate `loki-stack` (Loki + Promtail).

| Chart | Repository | Approx version |
|-------|-----------|:--------------:|
| `kube-prometheus-stack` | https://prometheus-community.github.io/helm-charts | ~69.x |
| `loki-stack` | https://grafana.github.io/helm-charts | ~2.x |

> **Verification required:** Chart versions must be verified against live Helm repos before implementation.
> See AGENTS.md — Verification Rules.

### Monitoring Storage on Longhorn

Monitoring PVCs (Prometheus 30G, Loki 20G, Grafana 2G) are replicated at RF=3:

| PVC | Size | Replicated (RF=3) |
|-----|:----:|:-----------------:|
| Prometheus | 30G | 90G |
| Loki | 20G | 60G |
| Grafana | 2G | 6G |
| Alertmanager | 1G | 3G |
| **Total** | **53G** | **159G** |

This 159G of replicated data is distributed across nodes with available SSD space.
Variant C has 880G total SSD. Open edX volumes consume ~228G replicated (see below).
Monitoring adds 159G → total 387G / 880G = 44% SSD utilization. Comfortable.

### Open edX Storage on Longhorn

| PVC | Size | Replicated (RF=3) |
|-----|:----:|:-----------------:|
| MySQL | 20G | 60G |
| MongoDB | 20G | 60G |
| MeiliSearch | 10G | 30G |
| Redis | 2G | 6G |
| Tutor data (media, themes) | 10G | 30G |
| **Total** | **62G** | **186G** |

Combined (Open edX + Monitoring): 186G + 159G = 345G replicated / 880G SSD = **39% utilization**.

---

## Appendix D: Module GAP Analysis

Mapping the desired architecture (Variant C: 3×CX33 masters + 4×CX43 workers, Longhorn,
Monitoring) against the current module code. Identifies what works today and what requires
new implementation.

### GAP 1: No Heterogeneous Worker Pools

**Current code:** `variables.tf` defines `worker_node_server_type` as a single string.
All workers created by `hcloud_server.worker[count]` in `main.tf` use the same server type.

```hcl
# Current (variables.tf)
variable "worker_node_server_type" {
  type    = string
  default = "cx23"
}
```

**Desired:** Different server types per worker role (DB vs App vs Monitoring).

**Workaround:** Use `CX43` for ALL workers. Workload isolation is achieved via Kubernetes
node labels + pod affinity/anti-affinity rules applied post-deploy (not at Terraform level).

**Proper fix (future):** Introduce `worker_pools` variable:

```hcl
# Future (not implemented)
variable "worker_pools" {
  type = list(object({
    name        = string
    count       = number
    server_type = string
    labels      = optional(map(string), {})
    taints      = optional(list(string), [])
  }))
}
```

**Complexity:** High (~300 lines). Requires changes to `main.tf`, `variables.tf`,
`load_balancer.tf`, `scripts/rke-worker.sh.tpl`, and all tests. Breaking change.

### GAP 2: No Longhorn Addon

**Current code:** No `cluster-longhorn.tf` exists. Storage is provided by Hetzner CSI
(`cluster-csi.tf`), which deploys `hcloud-csi` Helm chart.

**Required:** New `cluster-longhorn.tf` following the self-contained addon pattern
(same as `cluster-velero.tf`). Components:

- Variable: `longhorn` object (enabled, version, s3_backup_target, replica_count, etc.)
- Helm release: `longhorn/longhorn` chart
- StorageClass: `longhorn` as default (replacing `hcloud-volumes`)
- S3 backup Secret: credentials for Longhorn BackupTarget
- Guardrail: `longhorn_conflicts_with_csi` — warn if both enabled

**Complexity:** Medium (~150 lines). Follows existing addon pattern.

### GAP 3: No Monitoring Addon

**Current code:** No `cluster-monitoring.tf` exists.

**Required:** New `cluster-monitoring.tf` with:

- Variable: `monitoring` object (enabled, prometheus retention, grafana admin password, etc.)
- Helm releases: `kube-prometheus-stack` + `loki-stack`
- Namespace: `monitoring`

**Complexity:** Medium (~200 lines). Standard Helm chart deployment.

### GAP 4: No Worker Node Labels/Taints

**Current code:** `scripts/rke-worker.sh.tpl` generates a minimal RKE2 agent `config.yaml`
with only `server`, `token`, `cloud-provider-name`, and `node-ip`. No support for
`node-label` or `node-taint` parameters.

**Impact:** Cannot enforce workload placement at Terraform level. Workers are
indistinguishable from Kubernetes' perspective.

**Workaround:** Apply labels post-deploy via `kubectl label node <name> role=db`.
Or use a `null_resource` with `remote-exec` to label nodes after cluster is ready.

**Proper fix:** Add `node-label` and `node-taint` fields to the worker cloud-init template.
Requires GAP 1 (worker pools) to be meaningful.

### GAP 5: Hetzner CSI ↔ Longhorn Coexistence

**Current code:** `cluster_configuration.hcloud_csi.preinstall` controls whether the
Hetzner CSI driver is deployed. When `false`, RKE2 skips auto-deploying `hcloud-csi`.

**Required behavior:**
- When Longhorn is the primary storage: set `hcloud_csi.preinstall = false`
- Longhorn provides its own CSI driver and StorageClass
- Velero's `velero_requires_csi` guardrail must be updated (Longhorn IS a CSI driver, just not Hetzner's)

**Complexity:** Low. Configuration-level change, no new resources.

### Current Module Capabilities (what works TODAY)

The following configuration works with the current module code, zero changes required:

```hcl
module "rke2" {
  source = "github.com/abstractlabz/terraform-hcloud-rke2"

  cluster_name              = "openedx-production"
  master_node_count         = 3           # HA etcd quorum
  master_node_server_type   = "cx33"      # 4C/8G — headroom for control plane
  worker_node_count         = 4           # DB + App + App + Monitoring
  worker_node_server_type   = "cx43"      # 8C/16G — uniform type (GAP 1 workaround)

  cluster_configuration = {
    hcloud_csi = {
      preinstall = false                  # Disable Hetzner CSI (Longhorn replaces it)
    }
    etcd_backup = {
      enabled       = true
      s3_bucket     = "my-etcd-backups"
      s3_access_key = var.s3_access_key
      s3_secret_key = var.s3_secret_key
    }
  }

  velero = { enabled = false }            # Longhorn handles backup (not Velero)

  health_check_urls = [
    "https://learn.example.com/heartbeat"
  ]

  # Longhorn + monitoring installed via Helm post-apply (GAPs 2, 3)
}
```

Post-deploy steps (manual or via CI/CD):
1. `helm install longhorn longhorn/longhorn -n longhorn-system --create-namespace`
2. `kubectl label node worker-0 role=db && kubectl label node worker-1 role=app ...`
3. `helm install monitoring prometheus-community/kube-prometheus-stack -n monitoring --create-namespace`
4. `helm install loki grafana/loki-stack -n monitoring`

---

## Appendix E: Recommended Configuration

### For 5K DAU (Production)

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Masters | 3 × CX33 | etcd quorum + 42% CPU headroom |
| Workers | 4 × CX43 | Uniform type (module limitation), 40-67% RAM headroom per role |
| Storage | Longhorn RF=3 | NVMe IOPS, native snapshots, built-in S3 backup |
| Backup (etcd) | S3, every 6h | Hetzner Object Storage, RPO=6h |
| Backup (PVC) | Longhorn → S3, every 6h | Replaces Velero, same RPO |
| Monitoring | kube-prometheus-stack + Loki | Full observability |
| Total cost | **~€66/mo** | 7 nodes + 2 LBs |
| DAU headroom | Up to ~10K | Before any node upgrade needed |

### For 15K DAU (Scaled)

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Masters | 3 × CX33 | No change needed |
| Worker-DB | 1 × CX53 | 32G RAM for MySQL buffer_pool + MongoDB cache |
| Worker-App | 2 × CX43 + 1 × CX33 | Distribute LMS/CMS/Celery across 3 nodes |
| Worker-Mon | 1 × CX43 | No change needed |
| Total cost | **~€71/mo** | 9 nodes + 2 LBs |
| Next bottleneck | ~25K DAU | MySQL single-instance ceiling |

> NOTE: Scaling from 5K to 15K requires GAP 1 (heterogeneous worker pools) to be implemented,
> OR manual server type changes + `tofu apply` to resize all workers to CX53
> (overprovisioning the App and Monitoring workers).
