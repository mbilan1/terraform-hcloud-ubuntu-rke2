# Plan: Operational Readiness — Backup, Upgrade, Rollback

> **Status**: Approved plan, implementation in progress
> **Branch**: `feature/operational-readiness-plan`
> **Created**: 2026-02-15
> **Updated**: 2026-02-16 — replaced Velero with Longhorn native backup, added restore runbooks
> **Scope**: etcd backup, PVC backup (Longhorn native), health check, upgrade flow, rollback procedure
> **MTTR target**: < 15 min for HA cluster (3 masters + 3 workers)
> **Design principle**: Operational simplicity — fewest moving parts in the restore path

---

## Table of Contents

- [Problem Statement](#problem-statement)
- [Architecture Overview](#architecture-overview)
- [Why NOT Velero + Kopia](#why-not-velero--kopia)
- [Step 1: etcd Backup (K8s State → S3)](#step-1-etcd-backup-k8s-state--s3)
- [Step 2: PVC Backup via Longhorn (Application Data → S3)](#step-2-pvc-backup-via-longhorn-application-data--s3)
- [Step 3: mysqldump Insurance (Logical Backup → S3)](#step-3-mysqldump-insurance-logical-backup--s3)
- [Step 4: Health Check (null_resource)](#step-4-health-check-null_resource)
- [Step 5: Upgrade with Pre-Snapshot](#step-5-upgrade-with-pre-snapshot)
- [Step 6: Rollback](#step-6-rollback)
- [Step 7: Restore Runbooks](#step-7-restore-runbooks)
- [Step 8: Documentation](#step-8-documentation)
- [Files Changed](#files-changed)
- [Verification](#verification)
- [Key Decisions](#key-decisions)
- [MTTR Breakdown](#mttr-breakdown)
- [RPO / RTO Targets](#rpo--rto-targets)
- [Appendix A: Longhorn Tuning for Production](#appendix-a-longhorn-tuning-for-production)
- [Appendix B: Hetzner S3 Compatibility](#appendix-b-hetzner-s3-compatibility)
- [Appendix C: Hetzner CSI Retention (Legacy Path)](#appendix-c-hetzner-csi-retention-legacy-path)
- [Appendix D: Cluster Sizing Reference](#appendix-d-cluster-sizing-reference)

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
| Storage HA | HIGH | Hetzner CSI = single-attach, no replication, no snapshots |

### Operator Profile

This plan is designed for a **single operator** (DevOps engineer or platform lead) managing
an Open edX cluster. The restore path must be executable by one person under stress
(production down, students unable to access courses).

**Design constraint:** Every restore step must be a single command or a short script
that can be copy-pasted from a runbook. No multi-tool orchestration (Velero + etcd + manual
PVC matching) during a crisis.

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
  Longhorn → block-level snapshots → incremental S3 backup
  Mechanism: Longhorn built-in backup (cluster-longhorn.tf)
  RPO: 6 hours (configurable via RecurringJob)
  Note: crash-consistent, not application-consistent (see Step 3 for insurance)

Level 2.5: mysqldump insurance (logical backup, optional but recommended)
──────────────────────────────────────────────────────────────────────────
  CronJob → mysqldump --single-transaction → S3
  Mechanism: K8s CronJob (Tutor layer, not this module)
  RPO: 24 hours (nightly)
  Note: guarantees application-consistent MySQL restore

Upgrade flow:
─────────────
  rke2_version change
    → null_resource.pre_upgrade_snapshot (etcd + Longhorn VolumeSnapshot)
    → RKE2 upgrade (SUC or manual)
    → null_resource.cluster_health_check
    → IF FAIL → operator executes rollback (Step 6)

Rollback:
─────────
  Fast path: etcd restore + Longhorn snapshot revert (< 5 min, for upgrade failures)
  Full path: etcd restore + Longhorn restore from S3 (< 15 min, for data loss)
```

### Why Two Levels?

| Layer | What it protects | When to use |
|-------|-----------------|-------------|
| etcd snapshot | All K8s objects: Deployments, Services, ConfigMaps, Secrets, CRDs, RBAC, PVCs (metadata) | Always — control plane state |
| Longhorn snapshot | Block-level PV data: MySQL files, MongoDB files, MeiliSearch indexes | Fast rollback — instant, local |
| Longhorn S3 backup | Same as above, off-cluster | Disaster recovery — cluster destroyed |
| mysqldump (optional) | Logical MySQL export | Ultimate insurance — guaranteed consistent |

etcd snapshot alone restores PVC *claims* but not the *data on the volumes*.
Longhorn snapshot alone restores *data* but not the *Kubernetes objects that reference it*.
Both levels together = complete rollback.

### Why NOT Three Levels (Velero)

See next section.

---

## Why NOT Velero + Kopia

The previous plan (PLAN-operational-readiness.md v1) proposed Velero + Kopia for PVC backup.
This was rejected for operational simplicity reasons.

### Complexity comparison

| Aspect | Velero + Kopia + Hetzner CSI | Longhorn native |
|--------|:----------------------------:|:---------------:|
| **Components to deploy** | 4 (Velero server, node-agent DaemonSet, AWS plugin, BSL Secret) | 1 (Longhorn Helm chart) |
| **Components in restore path** | 3 (Velero CLI, node-agent, BSL) | 1 (Longhorn UI or kubectl) |
| **S3 workarounds needed** | Yes (`checksumAlgorithm=""` for aws-sdk-go-v2, see issue #8660) | TBD — Longhorn uses own S3 client |
| **VolumeSnapshot support** | ❌ Hetzner CSI has none (issue #849) | ✅ Native |
| **Pre-upgrade snapshot** | 30+ min (file-level copy of entire PV to S3) | Instant (COW block snapshot, local) |
| **Restore command** | `velero restore create --from-backup <name> --wait` + wait for node-agent | `kubectl -n longhorn-system ...` or Longhorn UI click |
| **Failure modes in restore** | Velero pod crash, node-agent OOM, BSL credential rotation, S3 rate limit, Kopia index corruption | Longhorn engine crash, replica rebuild timeout |
| **Debug surface area** | Velero logs + node-agent logs + BSL status + S3 access logs | Longhorn manager logs |
| **"Can I restore from another cluster?"** | Yes (Velero designed for cross-cluster) | Yes (Longhorn backup → any Longhorn cluster) |
| **Hetzner CSI dependency** | Required (Velero backs up CSI PVCs) | Replaces it (Longhorn IS the CSI driver) |

### The critical difference: restore under stress

When production is down and the operator is under pressure:

**Velero restore path:**
1. Check Velero server pod is running
2. Check node-agent DaemonSet is running on target nodes
3. Check BSL (BackupStorageLocation) is "Available"
4. `velero backup get` — find the right backup
5. `velero restore create --from-backup <name> --wait`
6. Watch node-agent logs for progress — Kopia downloads files one by one
7. If Kopia index is corrupted → `velero backup describe <name> --details` → diagnose
8. Wait 10-30 min for 16G of files to download from S3
9. Verify PVCs are bound and pods can mount them

**Longhorn restore path (from local snapshot):**
1. Longhorn UI → Volumes → Select volume → Snapshots → Revert
2. Or: `kubectl -n longhorn-system patch volume <name> ...`
3. Done. Instant. COW revert, no S3 download.

**Longhorn restore path (from S3 backup, after cluster rebuild):**
1. Longhorn UI → Backup → Select backup → Restore
2. Or: one kubectl command (see Runbook 3 in Step 7)
3. Wait for download from S3 (same speed as Velero, but one component)
4. PVC auto-created by Longhorn

### Decision

Velero adds 4 components + 1 workaround to the restore path. Longhorn adds 0 new
components to restore (it's already the storage driver). For a single operator under stress,
fewer moving parts = faster MTTR.

**Trade-off accepted:** Longhorn block-level snapshots are crash-consistent, not
application-consistent. MySQL InnoDB crash recovery handles this for typical Open edX
workloads. For guaranteed consistency, add mysqldump CronJob (Step 3) as insurance.

---

## Step 1: etcd Backup (K8s State → S3)

> **No changes from previous plan.** etcd backup via RKE2 native is the correct approach.
> Included here for completeness.

RKE2 natively supports S3-compatible backup via `config.yaml` parameters.
See: https://docs.rke2.io/datastore/backup_restore

Hetzner Object Storage endpoints: `{location}.your-objectstorage.com` (fsn1, nbg1, hel1).
See: https://docs.hetzner.com/storage/object-storage/overview

### 1a. Variables

Extend `cluster_configuration` in `variables.tf` — add `etcd_backup` object:

```hcl
etcd_backup = optional(object({
  enabled              = optional(bool, false)
  schedule_cron        = optional(string, "0 */6 * * *")   # Every 6h
  retention            = optional(number, 10)
  s3_retention         = optional(number, 10)               # Available since RKE2 v1.34.0+
  compress             = optional(bool, true)
  s3_endpoint          = optional(string, "")               # Auto-filled from lb_location if empty
  s3_bucket            = optional(string, "")
  s3_folder            = optional(string, "")               # Defaults to cluster_name
  s3_access_key        = optional(string, "")
  s3_secret_key        = optional(string, "")
  s3_region            = optional(string, "eu-central")
  s3_bucket_lookup_type = optional(string, "path")          # Required for Hetzner Object Storage
}), {})
```

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
    error_message = "etcd_backup.enabled=true requires s3_bucket, s3_access_key, and s3_secret_key."
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
etcd-s3-bucket-lookup-type: ${ETCD_S3_BUCKET_LOOKUP_TYPE}
etcd-s3-retention: ${ETCD_S3_RETENTION}
%{ endif }
```

### 1d. Update templatefile() calls

In `main.tf`, add template variables to `hcloud_server.master` and `hcloud_server.additional_masters`:

```hcl
ETCD_BACKUP_ENABLED        = var.cluster_configuration.etcd_backup.enabled
ETCD_SNAPSHOT_SCHEDULE     = var.cluster_configuration.etcd_backup.schedule_cron
ETCD_SNAPSHOT_RETENTION    = var.cluster_configuration.etcd_backup.retention
ETCD_SNAPSHOT_COMPRESS     = var.cluster_configuration.etcd_backup.compress
ETCD_S3_ENDPOINT           = local.etcd_s3_endpoint
ETCD_S3_BUCKET             = var.cluster_configuration.etcd_backup.s3_bucket
ETCD_S3_FOLDER             = local.etcd_s3_folder
ETCD_S3_ACCESS_KEY         = var.cluster_configuration.etcd_backup.s3_access_key
ETCD_S3_SECRET_KEY         = var.cluster_configuration.etcd_backup.s3_secret_key
ETCD_S3_REGION             = var.cluster_configuration.etcd_backup.s3_region
ETCD_S3_BUCKET_LOOKUP_TYPE = var.cluster_configuration.etcd_backup.s3_bucket_lookup_type
ETCD_S3_RETENTION          = var.cluster_configuration.etcd_backup.s3_retention
```

### 1e. Computed locals

Add to `locals.tf`:

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

---

## Step 2: PVC Backup via Longhorn (Application Data → S3)

### Why Longhorn (not Velero)

| Factor | Decision |
|--------|----------|
| Hetzner CSI has no VolumeSnapshot | Longhorn has native snapshots — instant, COW-based |
| Velero adds 4 components to restore path | Longhorn is already the storage driver — 0 new components |
| Velero + Hetzner S3 requires `checksumAlgorithm=""` workaround | Longhorn uses own S3 client |
| Velero file-level backup = slow (10-30 min for 16G) | Longhorn incremental block backup = faster |
| Pre-upgrade snapshot via Velero = 30 min wait | Longhorn VolumeSnapshot = instant (COW) |

### What Longhorn provides

1. **Distributed block storage** on local NVMe SSDs (replaces Hetzner Block Storage)
2. **Replication** — RF=2 or RF=3 across workers (survives node failure)
3. **Local snapshots** — instant COW, for fast rollback
4. **S3 backup** — incremental block-level backup to Hetzner Object Storage
5. **Restore from S3** — rebuild volume from backup on any Longhorn cluster
6. **VolumeSnapshot CSI** — standard K8s VolumeSnapshot API support
7. **UI** — web dashboard for volume management, snapshot, backup, restore

### 2a. Variables

Add `longhorn` to `cluster_configuration` in `variables.tf`:

```hcl
longhorn = optional(object({
  version               = optional(string, "1.7.3")
  preinstall            = optional(bool, false)            # Experimental, disabled by default
  replica_count         = optional(number, 2)              # 2 = balance between safety and disk usage
  default_storage_class = optional(bool, true)             # Make longhorn the default SC
  backup_target         = optional(string, "")             # S3 URL: s3://bucket@region/folder
  backup_schedule       = optional(string, "0 */6 * * *") # Every 6h, matches etcd schedule
  backup_retain         = optional(number, 10)             # Keep 10 backups
  s3_endpoint           = optional(string, "")             # Auto-filled from lb_location if empty
  s3_access_key         = optional(string, "")
  s3_secret_key         = optional(string, "")

  # Tuning (see Appendix A)
  guaranteed_instance_manager_cpu  = optional(number, 12)  # % of node CPU for instance managers
  storage_over_provisioning        = optional(number, 100) # % — 100 = no overprovisioning
  storage_minimal_available        = optional(number, 15)  # % — minimum free disk before Longhorn stops scheduling
  snapshot_max_count               = optional(number, 5)   # Max snapshots per volume before auto-cleanup
}), {})
```

### 2b. New file: cluster-longhorn.tf

```hcl
# ──────────────────────────────────────────────────────────────────────────────
# Longhorn — distributed block storage with native backup
# https://longhorn.io/
#
# DECISION: Longhorn replaces Velero + Kopia for PVC backup
# Why: Fewer components in restore path (1 vs 4). Native VolumeSnapshot
#      (Hetzner CSI has none — issue #849). Instant pre-upgrade snapshots.
#      Integrated storage + backup in single component.
#
# DECISION: Longhorn replaces Hetzner CSI as primary storage driver
# Why: Replication across workers (HA). Local NVMe IOPS (~50K vs ~10K).
#      VolumeSnapshot support. Native S3 backup.
#
# NOTE: Longhorn is marked EXPERIMENTAL. Hetzner CSI retained as fallback.
# TODO: Promote Longhorn to default after battle-tested in production.
# ──────────────────────────────────────────────────────────────────────────────

# NOTE: All check {} blocks go to guardrails.tf (not here).
# This follows the existing codebase pattern where all cross-variable
# consistency checks are centralized in guardrails.tf.
# See: Step 2f for the guardrail definitions.

# --- Locals ---

locals {
  longhorn_s3_endpoint = (
    trimspace(var.cluster_configuration.longhorn.s3_endpoint) != ""
    ? var.cluster_configuration.longhorn.s3_endpoint
    : "https://${var.lb_location}.your-objectstorage.com"
  )

  longhorn_backup_target = (
    trimspace(var.cluster_configuration.longhorn.backup_target) != ""
    ? var.cluster_configuration.longhorn.backup_target
    : ""
  )
}

# --- Namespace ---

resource "kubernetes_namespace_v1" "longhorn" {
  depends_on = [null_resource.wait_for_cluster_ready]
  count      = var.cluster_configuration.longhorn.preinstall ? 1 : 0
  metadata {
    name = "longhorn-system"
  }
  lifecycle {
    ignore_changes = [metadata[0].annotations, metadata[0].labels]
  }
}

# --- S3 Credentials Secret ---

resource "kubernetes_secret_v1" "longhorn_s3" {
  depends_on = [kubernetes_namespace_v1.longhorn]
  count = (
    var.cluster_configuration.longhorn.preinstall &&
    trimspace(var.cluster_configuration.longhorn.backup_target) != ""
  ) ? 1 : 0

  metadata {
    name      = "longhorn-s3-credentials"
    namespace = "longhorn-system"
  }

  data = {
    AWS_ACCESS_KEY_ID     = var.cluster_configuration.longhorn.s3_access_key
    AWS_SECRET_ACCESS_KEY = var.cluster_configuration.longhorn.s3_secret_key
    AWS_ENDPOINTS         = local.longhorn_s3_endpoint
  }
}

# --- Helm Release ---

resource "helm_release" "longhorn" {
  depends_on = [
    kubernetes_namespace_v1.longhorn,
    helm_release.hccm,                        # CCM must be ready for node labels
    null_resource.wait_for_cluster_ready,
  ]
  count      = var.cluster_configuration.longhorn.preinstall ? 1 : 0

  repository = "https://charts.longhorn.io"
  chart      = "longhorn"
  name       = "longhorn"
  namespace  = "longhorn-system"
  version    = var.cluster_configuration.longhorn.version
  timeout    = 600

  values = [templatefile("${path.module}/templates/values/longhorn.yaml", {
    REPLICA_COUNT                      = var.cluster_configuration.longhorn.replica_count
    DEFAULT_STORAGE_CLASS              = var.cluster_configuration.longhorn.default_storage_class
    BACKUP_TARGET                      = local.longhorn_backup_target
    BACKUP_TARGET_CREDENTIAL_SECRET    = trimspace(var.cluster_configuration.longhorn.backup_target) != "" ? "longhorn-s3-credentials" : ""
    BACKUP_SCHEDULE                    = var.cluster_configuration.longhorn.backup_schedule
    BACKUP_RETAIN                      = var.cluster_configuration.longhorn.backup_retain
    GUARANTEED_INSTANCE_MANAGER_CPU    = var.cluster_configuration.longhorn.guaranteed_instance_manager_cpu
    STORAGE_OVER_PROVISIONING          = var.cluster_configuration.longhorn.storage_over_provisioning
    STORAGE_MINIMAL_AVAILABLE          = var.cluster_configuration.longhorn.storage_minimal_available
    SNAPSHOT_MAX_COUNT                 = var.cluster_configuration.longhorn.snapshot_max_count
  })]
}
```

### 2c. New file: templates/values/longhorn.yaml

```yaml
# ──────────────────────────────────────────────────────────────────────────────
# Longhorn Helm values — production-tuned for Open edX on Hetzner
# ──────────────────────────────────────────────────────────────────────────────

defaultSettings:
  # --- Storage ---
  defaultReplicaCount: ${REPLICA_COUNT}
  # DECISION: Workers-only for data replicas. Protects master disk/etcd.
  # Longhorn manager DaemonSet still runs on masters (for orchestration),
  # but no data is stored on master nodes.
  # NOTE: This label requires explicit configuration in rke-worker.sh.tpl.
  # RKE2 does NOT auto-label workers (only masters get role labels).
  # The label is set via RKE2 config: node-label: ["node-role.kubernetes.io/worker=true"]
  # See: Step 2d for cloud-init changes.
  systemManagedComponentsNodeSelector: "node-role.kubernetes.io/worker:true"
  createDefaultDiskLabeledNodes: true

  # --- Backup ---
  backupTarget: "${BACKUP_TARGET}"
  backupTargetCredentialSecret: "${BACKUP_TARGET_CREDENTIAL_SECRET}"

  # --- Tuning (see Appendix A of operational readiness plan) ---
  # DECISION: Reserve CPU for instance managers to prevent starvation under load.
  # Default 12% per node. Prevents MySQL I/O stalls during Longhorn replica rebuild.
  guaranteedInstanceManagerCPU: ${GUARANTEED_INSTANCE_MANAGER_CPU}
  # DECISION: No overprovisioning. Hetzner NVMe is finite, no thin provisioning tricks.
  storageOverProvisioningPercentage: ${STORAGE_OVER_PROVISIONING}
  # DECISION: 15% minimum free disk. Alert threshold before Longhorn stops scheduling.
  storageMinimalAvailablePercentage: ${STORAGE_MINIMAL_AVAILABLE}
  # DECISION: Max 5 snapshots per volume. Prevents local disk fill from snapshot chains.
  snapshotMaxCount: ${SNAPSHOT_MAX_COUNT}
  # Auto-delete old snapshots when max is reached
  autoCleanupSnapshotWhenDeleteBackup: true

  # --- Resilience ---
  # DECISION: Auto-salvage replicas after unexpected detachment (node reboot, OOM kill).
  # Without this, volumes stay faulted and require manual intervention.
  autoSalvage: true
  # DECISION: Node drain policy — allow pod eviction during drain, Longhorn handles
  # replica rebuild automatically. Required for rolling upgrades.
  nodeDrainPolicy: "allow-if-replica-is-stopped"
  # DECISION: Concurrent replica rebuild limit per node. Prevents network saturation
  # during multiple volume recovery. Default 5 is too aggressive for shared 10Gbit NIC.
  concurrentReplicaRebuildPerNodeLimit: 3

persistence:
  defaultClass: ${DEFAULT_STORAGE_CLASS}
  defaultClassReplicaCount: ${REPLICA_COUNT}
  reclaimPolicy: Retain

longhornUI:
  # DECISION: Enable UI for operational visibility. Access via kubectl port-forward
  # or Ingress (not exposed by default — operator must configure access).
  enabled: true

# --- Recurring Jobs (backup schedule) ---
# DECISION: Default recurring job for all volumes — snapshot + backup to S3.
# Every volume tagged "default" gets automatic backup.
# RecurringJob runs at the same schedule as etcd backup for synchronized RPO.
%{ if BACKUP_TARGET != "" }
recurringJobSelector:
  - name: "backup-all"
    isGroup: true

longhornRecurringJobs:
  - name: "snapshot-and-backup"
    task: "backup"
    cron: "${BACKUP_SCHEDULE}"
    retain: ${BACKUP_RETAIN}
    concurrency: 2
    labels:
      recurring-job-group.longhorn.io/default: "enabled"
%{ endif }
```

### 2d. Cloud-Init (open-iscsi prerequisite)

Modify `scripts/rke-worker.sh.tpl` and `scripts/rke-master.sh.tpl`:

```bash
%{ if LONGHORN_ENABLED }
# DECISION: open-iscsi required by Longhorn for iSCSI target management.
# Installed at cloud-init time (before K8s) to avoid DaemonSet startup failures.
apt-get install -y open-iscsi
systemctl enable iscsid
systemctl start iscsid
%{ endif }
```

Add worker node label (in `scripts/rke-worker.sh.tpl` RKE2 config generation):

```bash
%{ if LONGHORN_ENABLED }
# DECISION: Label workers explicitly for Longhorn node selector.
# Why: RKE2 auto-labels masters (control-plane, etcd, master) but NOT workers.
#      Longhorn systemManagedComponentsNodeSelector needs this label to schedule
#      data replicas only on workers, protecting master disk space and etcd.
# See: https://docs.rke2.io/reference/linux_agent_config
node-label:
  - "node-role.kubernetes.io/worker=true"
%{ endif }
```

Update `templatefile()` calls in `main.tf`:

```hcl
LONGHORN_ENABLED = var.cluster_configuration.longhorn.preinstall
```

### 2e. Add to cluster-harmony.tf

```hcl
# Add helm_release.longhorn to Harmony's depends_on
depends_on = [
  # ... existing deps ...
  helm_release.longhorn,  # Storage must be ready before app workloads
]
```

### 2f. Add guardrails to guardrails.tf

```hcl
# Cross-addon guardrail: only one default StorageClass
check "longhorn_and_csi_default_sc_exclusivity" {
  assert {
    condition = !(
      var.cluster_configuration.longhorn.preinstall &&
      var.cluster_configuration.longhorn.default_storage_class &&
      var.cluster_configuration.hcloud_csi.preinstall &&
      var.cluster_configuration.hcloud_csi.default_storage_class
    )
    error_message = "Both Longhorn and Hetzner CSI are set as default StorageClass. Set only one as default."
  }
}

check "longhorn_experimental_warning" {
  assert {
    condition = !var.cluster_configuration.longhorn.preinstall
    error_message = "WARNING: Longhorn is EXPERIMENTAL. Test thoroughly before production use. See PLAN-operational-readiness.md Appendix A for tuning guidance."
  }
}
```

---

## Step 3: mysqldump Insurance (Logical Backup → S3)

### Why: crash-consistent ≠ application-consistent

Longhorn snapshots are **crash-consistent** — they capture the block device state at a
point in time, as if power was pulled. For MySQL InnoDB, this is equivalent to a crash
recovery scenario: InnoDB replays the redo log on startup and recovers to a consistent state.

**This works for 99.9% of Open edX workloads.** InnoDB is designed for crash recovery.

However, for the paranoid operator (recommended), a nightly `mysqldump` provides a
**guaranteed application-consistent** backup as insurance:

### Recommended CronJob (Tutor layer, not this module)

```yaml
# deploy via: kubectl apply -f mysqldump-cronjob.yaml
# Or add to Tutor plugin as k8s_override
apiVersion: batch/v1
kind: CronJob
metadata:
  name: mysqldump-to-s3
  namespace: openedx                      # Tutor default namespace
spec:
  schedule: "0 3 * * *"                   # 3 AM daily
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: mysqldump
              image: mysql:8.0
              command:
                - /bin/sh
                - -c
                - |
                  set -e
                  DUMP_FILE="/tmp/openedx-$(date +%Y%m%d-%H%M%S).sql.gz"

                  echo "Starting mysqldump..."
                  mysqldump \
                    -h mysql \
                    -u root \
                    -p"$MYSQL_ROOT_PASSWORD" \
                    --all-databases \
                    --single-transaction \
                    --quick \
                    --routines \
                    --triggers \
                    | gzip > "$DUMP_FILE"

                  echo "Uploading to S3..."
                  # Uses aws CLI configured via env vars
                  aws s3 cp "$DUMP_FILE" \
                    "s3://${S3_BUCKET}/mysqldump/$(basename $DUMP_FILE)" \
                    --endpoint-url "https://${S3_ENDPOINT}"

                  echo "Done. Size: $(du -h $DUMP_FILE | cut -f1)"
                  rm -f "$DUMP_FILE"
              env:
                - name: MYSQL_ROOT_PASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: mysql-secret   # Tutor-created secret
                      key: password
                - name: S3_BUCKET
                  value: "my-openedx-backups"
                - name: S3_ENDPOINT
                  value: "fsn1.your-objectstorage.com"
                - name: AWS_ACCESS_KEY_ID
                  valueFrom:
                    secretKeyRef:
                      name: s3-credentials
                      key: access-key
                - name: AWS_SECRET_ACCESS_KEY
                  valueFrom:
                    secretKeyRef:
                      name: s3-credentials
                      key: secret-key
          restartPolicy: OnFailure
```

### Why this is NOT in the module

This CronJob references Tutor-specific resources (`mysql` service, `mysql-secret`,
`openedx` namespace). The Terraform module provides infrastructure; application-level
backup belongs to the application layer (Tutor).

**Module responsibility:** Provide Longhorn (block-level backup).
**Tutor responsibility:** Provide mysqldump (logical backup) if desired.

The plan documents the CronJob for the operator's convenience but does not implement it
in the module.

---

## Step 4: Health Check (null_resource)

> **CHANGED from previous plan:** Uses `templatefile()` + `file` provisioner instead of
> `remote-exec` `inline`. The `%{for}` and `%{if}` template directives are **only supported
> inside `templatefile()`** — they do NOT work in HCL heredoc strings. Placing them in
> `inline` would send literal `%{ for URL in ... }` text to bash, causing a syntax error.

### 4a. New file: scripts/health-check.sh.tpl

```bash
#!/bin/bash
# Health check script — generated by templatefile()
# Validates cluster readiness after deployment or upgrade
set -euo pipefail
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH="$PATH:/var/lib/rancher/rke2/bin"

EXPECTED=${EXPECTED_NODES}
TIMEOUT=600
ELAPSED=0

echo "=== Cluster Health Check ==="

# Check 1: API server /readyz
until [ "$(kubectl get --raw='/readyz' 2>/dev/null)" = "ok" ]; do
  [ $ELAPSED -ge $TIMEOUT ] && echo "FAIL: API /readyz" && exit 1
  sleep 5; ELAPSED=$((ELAPSED + 5))
done
echo "PASS: API /readyz"

# Check 2: All nodes Ready
while true; do
  READY=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 == "Ready" {c++} END {print c+0}')
  [ "$READY" -ge "$EXPECTED" ] && break
  [ $ELAPSED -ge $TIMEOUT ] && echo "FAIL: Nodes $READY/$EXPECTED" && exit 1
  sleep 10; ELAPSED=$((ELAPSED + 10))
done
echo "PASS: Nodes $READY/$EXPECTED Ready"

# Check 3: System pods Running
for POD_PREFIX in coredns kube-proxy cloud-controller-manager; do
  COUNT=$(kubectl get pods -A --no-headers 2>/dev/null | grep "$POD_PREFIX" | grep -c "Running" || true)
  if [ "$COUNT" -eq 0 ]; then
    echo "FAIL: No running $POD_PREFIX pods"
    exit 1
  fi
  echo "PASS: $POD_PREFIX ($COUNT running)"
done

# Check 4: Longhorn health (if installed)
%{ if LONGHORN_ENABLED }
LH_COUNT=$(kubectl get pods -n longhorn-system --no-headers 2>/dev/null | grep -c "Running" || true)
if [ "$LH_COUNT" -gt 0 ]; then
  DEGRADED=$(kubectl get volumes.longhorn.io -n longhorn-system \
    -o jsonpath='{.items[?(@.status.robustness!="healthy")].metadata.name}' 2>/dev/null || true)
  if [ -n "$DEGRADED" ]; then
    echo "WARN: Longhorn degraded volumes: $DEGRADED"
  else
    echo "PASS: Longhorn all volumes healthy"
  fi
fi
%{ endif }

# Check 5: HTTP endpoints (optional)
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
```

> **NOTE on `%%{http_code}`**: Inside `templatefile()`, `%` is the template directive
> prefix. To produce a literal `%{http_code}` for curl's `-w` format string, it must be
> escaped as `%%{http_code}`. This is a `templatefile()`-specific escaping rule.

### 4b. Terraform resource

```hcl
# DECISION: Health check via templatefile() + file provisioner, not inline heredoc
# Why: %{if}/%{for} template directives only work inside templatefile().
#      Using inline would pass literal "%{ for URL in ... }" to bash → syntax error.
resource "null_resource" "cluster_health_check" {
  depends_on = [null_resource.wait_for_cluster_ready]

  triggers = {
    rke2_version = var.rke2_version
  }

  connection {
    type        = "ssh"
    host        = hcloud_server.master[0].ipv4_address
    user        = "root"
    private_key = tls_private_key.machines.private_key_openssh
    timeout     = "15m"
  }

  provisioner "file" {
    content = templatefile("${path.module}/scripts/health-check.sh.tpl", {
      EXPECTED_NODES    = var.master_node_count + var.worker_node_count
      LONGHORN_ENABLED  = var.cluster_configuration.longhorn.preinstall
      HEALTH_CHECK_URLS = var.health_check_urls
    })
    destination = "/tmp/health-check.sh"
  }

  provisioner "remote-exec" {
    inline = ["chmod +x /tmp/health-check.sh && /tmp/health-check.sh"]
  }
}
```

### Variable

```hcl
variable "health_check_urls" {
  type        = list(string)
  default     = []
  description = <<-EOT
    HTTP(S) URLs to check after cluster operations. Each must return 2xx/3xx.
    For Open edX: ["https://yourdomain.com/heartbeat"]
  EOT
}
```

---

## Step 5: Upgrade with Pre-Snapshot

### Key change from previous plan: Longhorn snapshot instead of Velero backup

Pre-upgrade snapshot is now **instant** (Longhorn COW snapshot) instead of waiting
30+ minutes for Velero file-level backup.

### 5a. New file: scripts/pre-upgrade-snapshot.sh.tpl

> **Same fix as Step 4:** Uses `templatefile()` because `%{if}` is not supported
> in HCL heredoc strings.

```bash
#!/bin/bash
# Pre-upgrade snapshot — creates etcd + Longhorn snapshots before RKE2 version bump
set -euo pipefail
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH="$PATH:/var/lib/rancher/rke2/bin"

SNAPSHOT_NAME="pre-upgrade-$(date +%Y%m%d-%H%M%S)"

# --- Level 1: etcd snapshot ---
echo "Creating pre-upgrade etcd snapshot: $SNAPSHOT_NAME"
rke2 etcd-snapshot save --name "$SNAPSHOT_NAME"
echo "$SNAPSHOT_NAME" > /var/lib/rancher/rke2/server/last-pre-upgrade-snapshot
echo "DONE: etcd snapshot saved"

# --- Level 2: Longhorn volume snapshots (instant, COW) ---
%{ if LONGHORN_ENABLED }
echo "Creating Longhorn snapshots for all volumes..."
for VOL in $(kubectl get volumes.longhorn.io -n longhorn-system -o jsonpath='{.items[*].metadata.name}'); do
  echo "  Snapshotting: $VOL"
  kubectl -n longhorn-system apply -f - <<SNAP
apiVersion: longhorn.io/v1beta2
kind: Snapshot
metadata:
  name: pre-upgrade-$${VOL}-$(date +%s)
  namespace: longhorn-system
spec:
  volume: $VOL
  labels:
    pre-upgrade: "true"
SNAP
done
echo "DONE: Longhorn snapshots created (instant, COW)"
%{ endif }
```

### 5b. Terraform resource

```hcl
resource "null_resource" "pre_upgrade_snapshot" {
  count = var.cluster_configuration.etcd_backup.enabled ? 1 : 0

  triggers = {
    rke2_version = var.rke2_version
  }

  connection {
    type        = "ssh"
    host        = hcloud_server.master[0].ipv4_address
    user        = "root"
    private_key = tls_private_key.machines.private_key_openssh
    timeout     = "5m"
  }

  provisioner "file" {
    content = templatefile("${path.module}/scripts/pre-upgrade-snapshot.sh.tpl", {
      LONGHORN_ENABLED = var.cluster_configuration.longhorn.preinstall
    })
    destination = "/tmp/pre-upgrade-snapshot.sh"
  }

  provisioner "remote-exec" {
    inline = ["chmod +x /tmp/pre-upgrade-snapshot.sh && /tmp/pre-upgrade-snapshot.sh"]
  }
}
```

### 5c. Dependency graph

```
rke2_version change
  ↓
null_resource.pre_upgrade_snapshot [triggers on rke2_version]
  ├── rke2 etcd-snapshot save (local + S3)              ~30 sec
  └── Longhorn VolumeSnapshot per volume (COW)           ~1 sec each
  ↓
[RKE2 upgrade via SUC or manual restart]
  ↓
null_resource.cluster_health_check [triggers on rke2_version]
  ├── API /readyz
  ├── All nodes Ready
  ├── System pods Running
  ├── Longhorn volumes healthy
  └── HTTP /heartbeat (if configured)
  ↓
IF PASS → upgrade complete
IF FAIL → operator executes rollback (Step 6)
```

**Time improvement:** Previous plan = ~35 min (30 min Velero + 5 min etcd). New plan = ~2 min.

---

## Step 6: Rollback

### Rollback scenarios

| Scenario | What happened | Restore path | Time |
|----------|--------------|--------------|:----:|
| **A: Upgrade broke K8s** | RKE2 upgrade failed, API down | etcd restore + Longhorn auto-recovers | ~5 min |
| **B: Upgrade broke app data** | Django migration corrupted MySQL | Longhorn snapshot revert | ~1 min |
| **C: Node destroyed** | Hetzner server gone | Longhorn auto-rebuilds replica from other nodes | ~5 min (auto) |
| **D: Cluster destroyed** | All nodes gone | etcd restore from S3 + Longhorn restore from S3 | ~15 min |
| **E: Data corruption** | Bad deploy, accidental DELETE | Longhorn restore from S3 backup (point-in-time) | ~10 min |
| **F: MySQL logical corruption** | Bad migration, need specific state | mysqldump restore from S3 | ~10 min |

### Scenario A: Upgrade broke K8s (etcd restore)

```bash
# 1. Find the pre-upgrade snapshot
SNAPSHOT=$(cat /var/lib/rancher/rke2/server/last-pre-upgrade-snapshot)

# 2. Stop all nodes (workers first, then additional masters, then master-0)
# Workers:
for w in worker-0 worker-1 worker-2; do
  ssh root@$w "systemctl stop rke2-agent.service"
done
# Additional masters:
for m in master-1 master-2; do
  ssh root@$m "systemctl stop rke2-server.service"
done
# master-0:
systemctl stop rke2-server.service

# 3. Restore etcd on master-0
rke2 server \
  --cluster-reset \
  --cluster-reset-restore-path=/var/lib/rancher/rke2/server/db/snapshots/${SNAPSHOT}

# 4. Start master-0
systemctl start rke2-server.service
# Wait: until kubectl get --raw='/readyz' == ok  (~2 min)

# 5. Additional masters: clear etcd, rejoin
for m in master-1 master-2; do
  ssh root@$m "rm -rf /var/lib/rancher/rke2/server/db/etcd && systemctl start rke2-server.service"
done

# 6. Workers: restart
for w in worker-0 worker-1 worker-2; do
  ssh root@$w "systemctl start rke2-agent.service"
done

# 7. Verify
kubectl get nodes                     # All Ready
kubectl get --raw='/readyz'           # ok
curl -sk https://learn.example.com/heartbeat  # 200
```

**Longhorn volumes auto-recover.** etcd restore brings back PVC metadata →
Longhorn engine reconnects to existing replicas on local disks → no data loss.

### Scenario B: Upgrade broke app data (Longhorn snapshot revert)

```bash
# Fastest restore path — reverts a volume to pre-upgrade snapshot.
# No S3 download, no waiting. Instant COW revert.

export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

# 1. Scale down the application using the volume
kubectl -n openedx scale deployment mysql --replicas=0

# 2. Revert the Longhorn volume to pre-upgrade snapshot
# Via UI: Longhorn UI → Volume → Snapshots → select pre-upgrade → Revert
# Via CLI:
VOLUME_NAME="pvc-xxxxxxxx"  # from: kubectl get pv -o jsonpath='{.items[*].spec.csi.volumeHandle}'
SNAPSHOT_NAME="pre-upgrade-20260217-120000-${VOLUME_NAME}"

kubectl -n longhorn-system patch volumes.longhorn.io "$VOLUME_NAME" \
  --type=merge \
  -p "{\"spec\":{\"revertSnapshotRequested\":\"$SNAPSHOT_NAME\"}}"

# 3. Scale back up
kubectl -n openedx scale deployment mysql --replicas=1

# 4. Verify
kubectl -n openedx exec deploy/mysql -- mysql -e "SELECT 1"
curl -sk https://learn.example.com/heartbeat
```

**Time: ~1 minute.** No S3 involved. Pure local operation.

### Scenario D: Cluster destroyed (full S3 restore)

```bash
# 1. Rebuild cluster with Terraform
tofu apply  # Creates new nodes, installs RKE2, deploys Longhorn

# 2. Restore etcd from S3
SNAPSHOT="pre-upgrade-20260217-120000"  # or latest scheduled
rke2 server \
  --cluster-reset \
  --cluster-reset-restore-path=${SNAPSHOT} \
  --etcd-s3 \
  --etcd-s3-endpoint=fsn1.your-objectstorage.com \
  --etcd-s3-bucket=my-etcd-backups \
  --etcd-s3-access-key=<key> \
  --etcd-s3-secret-key=<secret> \
  --etcd-s3-folder=openedx-production

# 3. Restart cluster (same as Scenario A, steps 4-6)

# 4. Restore Longhorn volumes from S3 backups
# Via UI: Longhorn UI → Backup → select backup → Restore Volume
# Via CLI (for each volume):
kubectl -n longhorn-system create -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata:
  name: mysql-data-restore
  namespace: longhorn-system
spec:
  fromBackup: "s3://my-openedx-backups@eu-central/longhorn-backups?volume=pvc-xxxxx&backup=backup-xxxxx"
  numberOfReplicas: 2
  accessMode: rwo
  size: "20Gi"
EOF

# 5. Rebind PVC to restored volume (if PVC names changed)
# Or: etcd restore brought back original PVC metadata → Longhorn matches by volume name

# 6. Verify
kubectl get pvc -n openedx                  # All Bound
curl -sk https://learn.example.com/heartbeat  # 200
```

### Scenario F: MySQL logical corruption (mysqldump restore)

```bash
# Use when: Django migration broke data, need specific point-in-time restore
# Requires: mysqldump CronJob from Step 3

# 1. Download dump from S3
aws s3 cp s3://my-openedx-backups/mysqldump/openedx-20260216-030000.sql.gz /tmp/ \
  --endpoint-url https://fsn1.your-objectstorage.com

# 2. Scale down LMS/CMS (prevent writes during restore)
kubectl -n openedx scale deployment lms cms --replicas=0

# 3. Restore
gunzip -c /tmp/openedx-20260216-030000.sql.gz | \
  kubectl -n openedx exec -i deploy/mysql -- mysql -u root -p"$PASSWORD"

# 4. Scale back up
kubectl -n openedx scale deployment lms cms --replicas=1

# 5. Verify
curl -sk https://learn.example.com/heartbeat
```

### What gets rolled back

| Component | Restored by | Notes |
|-----------|------------|-------|
| K8s objects (Deployments, Services, etc.) | etcd restore | Full state |
| PVC data (MySQL, MongoDB, etc.) | Longhorn snapshot revert OR S3 restore | Depends on scenario |
| Longhorn volume metadata | etcd restore | PVC ↔ Longhorn volume binding |
| RKE2 binary version | Manual reinstall | `INSTALL_RKE2_VERSION=<old> curl -sfL https://get.rke2.io \| sh -` |
| OS-level changes | Out of scope | Hetzner server snapshot (external) |

---

## Step 7: Restore Runbooks

Pre-written, copy-pasteable scripts for each restore scenario. Designed for a single
operator under stress.

### Runbook 1: "App is down after upgrade — fast rollback"

**Symptoms:** `/heartbeat` returns 500 or timeout after RKE2/Tutor upgrade.
**Time to resolve:** ~5 minutes.

```bash
#!/bin/bash
# RUNBOOK 1: Fast rollback after failed upgrade
# Prerequisites: SSH access to master-0, pre-upgrade snapshot exists
set -e

MASTER0="<master-0-ip>"
MASTERS=("<master-1-ip>" "<master-2-ip>")
WORKERS=("<worker-0-ip>" "<worker-1-ip>" "<worker-2-ip>" "<worker-3-ip>")

echo "=== ROLLBACK: Finding pre-upgrade snapshot ==="
SNAPSHOT=$(ssh root@$MASTER0 "cat /var/lib/rancher/rke2/server/last-pre-upgrade-snapshot")
echo "Snapshot: $SNAPSHOT"

echo "=== ROLLBACK: Stopping workers ==="
for w in "${WORKERS[@]}"; do ssh root@$w "systemctl stop rke2-agent.service" & done; wait

echo "=== ROLLBACK: Stopping additional masters ==="
for m in "${MASTERS[@]}"; do ssh root@$m "systemctl stop rke2-server.service" & done; wait

echo "=== ROLLBACK: Stopping master-0 ==="
ssh root@$MASTER0 "systemctl stop rke2-server.service"

echo "=== ROLLBACK: Restoring etcd ==="
ssh root@$MASTER0 "rke2 server --cluster-reset --cluster-reset-restore-path=/var/lib/rancher/rke2/server/db/snapshots/$SNAPSHOT"

echo "=== ROLLBACK: Starting master-0 ==="
ssh root@$MASTER0 "systemctl start rke2-server.service"
echo "Waiting for API..."
until ssh root@$MASTER0 "/var/lib/rancher/rke2/bin/kubectl --kubeconfig=/etc/rancher/rke2/rke2.yaml get --raw='/readyz'" 2>/dev/null | grep -q "ok"; do sleep 5; done
echo "API ready"

echo "=== ROLLBACK: Starting additional masters ==="
for m in "${MASTERS[@]}"; do
  ssh root@$m "rm -rf /var/lib/rancher/rke2/server/db/etcd && systemctl start rke2-server.service" &
done; wait

echo "=== ROLLBACK: Starting workers ==="
for w in "${WORKERS[@]}"; do ssh root@$w "systemctl start rke2-agent.service" & done; wait

echo "=== ROLLBACK: Waiting for cluster ==="
sleep 30
ssh root@$MASTER0 "/var/lib/rancher/rke2/bin/kubectl --kubeconfig=/etc/rancher/rke2/rke2.yaml get nodes"

echo "=== ROLLBACK COMPLETE ==="
echo "Verify: curl -sk https://learn.example.com/heartbeat"
```

### Runbook 2: "MySQL data is corrupt — revert to snapshot"

**Symptoms:** Application errors referencing database integrity, broken migrations.
**Time to resolve:** ~1 minute.

```bash
#!/bin/bash
# RUNBOOK 2: Revert MySQL volume to last Longhorn snapshot
set -e

export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
KC=/var/lib/rancher/rke2/bin/kubectl
NAMESPACE="openedx"

echo "=== Finding MySQL PVC ==="
PV=$($KC get pvc mysql -n $NAMESPACE -o jsonpath='{.spec.volumeName}')
VOLUME=$($KC get pv $PV -o jsonpath='{.spec.csi.volumeHandle}')
echo "Longhorn volume: $VOLUME"

echo "=== Finding latest pre-upgrade snapshot ==="
SNAPSHOT=$($KC get snapshots.longhorn.io -n longhorn-system \
  -l "pre-upgrade=true" \
  --sort-by='.metadata.creationTimestamp' \
  -o jsonpath='{.items[-1].metadata.name}')
echo "Snapshot: $SNAPSHOT"

echo "=== Scaling down MySQL ==="
$KC -n $NAMESPACE scale deployment mysql --replicas=0
sleep 5

echo "=== Reverting volume to snapshot ==="
$KC -n longhorn-system patch volumes.longhorn.io "$VOLUME" \
  --type=merge \
  -p "{\"spec\":{\"revertSnapshotRequested\":\"$SNAPSHOT\"}}"
sleep 3

echo "=== Scaling up MySQL ==="
$KC -n $NAMESPACE scale deployment mysql --replicas=1

echo "=== Waiting for MySQL ==="
$KC -n $NAMESPACE wait --for=condition=ready pod -l app=mysql --timeout=120s

echo "=== REVERT COMPLETE ==="
echo "Verify: curl -sk https://learn.example.com/heartbeat"
```

### Runbook 3: "Cluster destroyed — rebuild from S3"

**Symptoms:** All nodes destroyed, need full rebuild.
**Time to resolve:** ~20 minutes (including Terraform apply).

```bash
#!/bin/bash
# RUNBOOK 3: Full cluster rebuild from S3 backups
# Prerequisites: Terraform state intact, S3 backups exist
set -e

echo "=== REBUILD: Step 1 — Terraform apply ==="
cd /path/to/terraform
tofu apply -auto-approve
# Wait for cluster to be ready (~10 min)

MASTER0=$(tofu output -raw master_ipv4)

echo "=== REBUILD: Step 2 — Restore etcd from S3 ==="
ssh root@$MASTER0 << 'REMOTE'
  systemctl stop rke2-server.service

  # Find latest snapshot in S3
  rke2 etcd-snapshot list \
    --etcd-s3 \
    --etcd-s3-endpoint=fsn1.your-objectstorage.com \
    --etcd-s3-bucket=my-etcd-backups \
    --etcd-s3-access-key=$S3_ACCESS_KEY \
    --etcd-s3-secret-key=$S3_SECRET_KEY \
    --etcd-s3-folder=openedx-production

  # Restore (replace SNAPSHOT with the chosen one)
  rke2 server \
    --cluster-reset \
    --cluster-reset-restore-path=SNAPSHOT \
    --etcd-s3 \
    --etcd-s3-endpoint=fsn1.your-objectstorage.com \
    --etcd-s3-bucket=my-etcd-backups \
    --etcd-s3-access-key=$S3_ACCESS_KEY \
    --etcd-s3-secret-key=$S3_SECRET_KEY \
    --etcd-s3-folder=openedx-production

  systemctl start rke2-server.service
REMOTE

echo "=== REBUILD: Step 3 — Wait for Longhorn ==="
echo "Longhorn will auto-detect backup target and show available backups in UI."
echo "Navigate to: kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80"
echo "Then: Backup tab → Select volume → Restore"
echo ""
echo "Or restore via CLI for each volume:"
echo "  kubectl -n longhorn-system create -f restore-volume.yaml"
echo ""
echo "=== REBUILD: Manual steps required ==="
echo "1. Open Longhorn UI (port-forward above)"
echo "2. Go to Backup tab"
echo "3. For each volume: click Restore"
echo "4. Verify PVCs are Bound: kubectl get pvc -n openedx"
echo "5. Verify: curl -sk https://learn.example.com/heartbeat"
```

---

## Step 8: Documentation

### Updates to ARCHITECTURE.md

Add section **"Operations: Backup, Upgrade, Rollback"**:

- Backup architecture diagram (etcd → S3, Longhorn → S3)
- Deployment order: HCCM → Longhorn → cert-manager → Harmony
- Longhorn marked as experimental
- Rollback commands summary (Runbook 1)
- RPO/RTO targets table

### Updates to Addon Stack diagram

```
Layer 4: Application (Tutor / Harmony)
Layer 3: Addons (cert-manager, ingress-nginx)
Layer 2: Storage (Longhorn [primary] OR Hetzner CSI [legacy])
Layer 1: Cloud Provider (HCCM — node labels, LB, network)
Layer 0: Cluster (RKE2 — etcd, control plane, kubelet)
```

### Compromise Log entry

> **Longhorn experimental, Hetzner CSI retained.**
> Longhorn provides HA storage + native backup + VolumeSnapshot.
> Hetzner CSI retained for budget-constrained or simple deployments.
> Longhorn will become default after battle-tested in production.
> Velero dropped — Longhorn native backup provides simpler restore path.

---

## Files Changed

| File | Change type | What changes |
|------|:-----------:|-------------|
| `variables.tf` | MODIFY | Add `longhorn` to `cluster_configuration`, add `etcd_backup`, add `health_check_urls` |
| `guardrails.tf` | MODIFY | Add `etcd_backup_requires_s3_config`, `longhorn_backup_requires_s3_config`, `longhorn_minimum_workers`, `longhorn_and_csi_default_sc_exclusivity`, `longhorn_experimental_warning` |
| `scripts/rke-master.sh.tpl` | MODIFY | Add conditional etcd S3 params, add conditional open-iscsi install |
| `scripts/rke-worker.sh.tpl` | MODIFY | Add conditional open-iscsi install, add worker node-label for Longhorn |
| `scripts/health-check.sh.tpl` | **NEW** | Health check script (templatefile — fixes `%{if}` limitation) |
| `scripts/pre-upgrade-snapshot.sh.tpl` | **NEW** | Pre-upgrade etcd + Longhorn snapshot script (templatefile) |
| `main.tf` | MODIFY | Add templatefile() vars, `pre_upgrade_snapshot`, `cluster_health_check` |
| `locals.tf` | MODIFY | Add `etcd_s3_endpoint`, `etcd_s3_folder`, `longhorn_s3_endpoint`, `longhorn_backup_target` |
| `cluster-longhorn.tf` | **NEW** | Longhorn namespace + S3 secret + Helm release (guardrails in guardrails.tf) |
| `templates/values/longhorn.yaml` | **NEW** | Longhorn Helm values template |
| `cluster-csi.tf` | MODIFY | Add TODO comment for future removal |
| `cluster-harmony.tf` | MODIFY | Add `helm_release.longhorn` to depends_on |
| `output.tf` | MODIFY | Add `longhorn_enabled`, `storage_driver`, `etcd_backup_enabled` |
| `docs/ARCHITECTURE.md` | MODIFY | Add Operations section, update diagrams |
| `tests/conditional_logic.tftest.hcl` | MODIFY | Longhorn resource count tests |
| `tests/guardrails.tftest.hcl` | MODIFY | Longhorn guardrail tests |
| `examples/openedx-tutor/main.tf` | MODIFY | Add Longhorn config example |

**Removed from previous plan:**
- ~~`cluster-velero.tf`~~ — Velero dropped
- ~~`var.velero`~~ — Velero variable dropped
- ~~Velero guardrails~~ — Velero dropped

---

## Verification

```bash
# Safe, no credentials needed:
tofu fmt -check          # Formatting
tofu validate            # Syntax (run in test-rke2-module/)
tofu test                # All tests (~75+), ~3s, $0

# With credentials:
cd examples/openedx-tutor
tofu init && tofu plan   # Verify Longhorn resources in plan
```

### E2E Verification (REQUIRED before merge)

```bash
# 1. Deploy cluster with Longhorn enabled + S3 backup target
# 2. Create MySQL PVC + write known data
# 3. Wait for Longhorn recurring backup to complete (or trigger manually via UI)
# 4. Verify backup in S3: Longhorn UI → Backup tab → volume listed
# 5. Create a Longhorn snapshot (test instant snapshot)
# 6. Write new data to MySQL
# 7. Revert to snapshot (Runbook 2)
# 8. Verify original data is back
# 9. Delete volume, restore from S3 backup (Runbook 3)
# 10. Verify data is back
# 11. Check Longhorn logs for any S3 errors (Appendix B)
```

---

## Key Decisions

| Decision | Rationale |
|----------|-----------|
| **Longhorn for PVC backup (not Velero)** | Fewer components in restore path (1 vs 4). No `checksumAlgorithm` workaround. Instant pre-upgrade snapshots. Single operator can restore under stress. |
| **Longhorn replaces Hetzner CSI as primary storage** | Replication (RF=2), native VolumeSnapshot, local NVMe IOPS (~50K vs ~10K). Hetzner CSI has no snapshot support (issue #849). |
| **Hetzner CSI retained as legacy fallback** | For budget-constrained deployments (<€40/mo). TODO for demotion, not removal. |
| **etcd backup via RKE2 native** | Zero dependencies, configured in cloud-init. |
| **mysqldump CronJob as insurance (Tutor layer)** | Longhorn = crash-consistent. mysqldump = application-consistent. Defense in depth. Module documents it, Tutor implements it. |
| **crash-consistent OK for MySQL InnoDB** | InnoDB redo log replay recovers to consistent state. Tested extensively in VMware/KVM crash scenarios. Explicit trade-off for operational simplicity. |
| **Workers-only data scheduling** | `systemManagedComponentsNodeSelector: worker`. Protects master disk/etcd from Longhorn data I/O. |
| **open-iscsi in cloud-init** | Required by Longhorn, installed conditionally before K8s starts. |
| **Longhorn UI enabled** | Critical for operational visibility during restore. Not exposed externally — operator uses `kubectl port-forward`. |
| **Pre-upgrade snapshot via Longhorn (not Velero)** | Instant COW snapshot vs 30+ min file-level copy. Reduces pre-upgrade time from 35 min to 2 min. |
| **Restore runbooks as copy-paste scripts** | Single operator under stress needs one script, not a decision tree. |
| **Separate S3 credentials (etcd vs Longhorn)** | Module's self-contained addon pattern. Each addon owns its config. Operators can share at invocation level. |
| **RF=2 default (not RF=3)** | 2 replicas = survive 1 node failure. RF=3 uses 50% more disk. For 2-3 worker clusters, RF=3 impossible. |
| **`snapshotMaxCount: 5`** | Prevents local disk fill from snapshot chains. Oldest auto-deleted. |
| **`concurrentReplicaRebuildPerNodeLimit: 3`** | Prevents network saturation during multi-volume recovery on shared 10Gbit NIC. |

---

## MTTR Breakdown

### Scenario B: App data rollback (Longhorn snapshot revert)

| Phase | Duration | Cumulative |
|-------|:--------:|:----------:|
| Scale down MySQL | ~5 sec | 5 sec |
| Longhorn snapshot revert (COW) | ~1 sec | 6 sec |
| Scale up MySQL | ~30 sec | 36 sec |
| InnoDB recovery (if needed) | ~10 sec | 46 sec |
| Health check | ~15 sec | **~1 min** |

### Scenario A: Full cluster rollback (etcd + Longhorn)

| Phase | Duration | Cumulative |
|-------|:--------:|:----------:|
| Stop RKE2 on all nodes | ~1 min | 1 min |
| etcd restore on master-0 | ~1 min | 2 min |
| Start master-0, wait for API | ~3 min | 5 min |
| Restart additional masters | ~2 min | 7 min |
| Restart workers | ~2 min | 9 min |
| Longhorn reconnects to local replicas | ~1 min | 10 min |
| Health check | ~1 min | **~11 min** |

**Improvement over previous plan:** No Velero PVC restore step (was 3-5 min). Longhorn
volumes survive etcd restore because data lives on local disks, not in etcd.

### Scenario D: Full rebuild from S3

| Phase | Duration | Cumulative |
|-------|:--------:|:----------:|
| Terraform apply (new cluster) | ~10 min | 10 min |
| etcd restore from S3 | ~2 min | 12 min |
| Start cluster | ~5 min | 17 min |
| Longhorn restore volumes from S3 (62G) | ~5-8 min | 25 min |
| Health check | ~1 min | **~26 min** |

> NOTE: Full rebuild exceeds 15 min MTTR target. This is acceptable — full cluster
> destruction is a rare catastrophic event. Scenarios A and B (the common cases)
> are well within target.

---

## RPO / RTO Targets

| Metric | Target | Mechanism |
|--------|--------|-----------|
| **RPO (etcd)** | 6 hours | `etcd-snapshot-schedule-cron: "0 */6 * * *"` |
| **RPO (PVC — block level)** | 6 hours | Longhorn RecurringJob backup to S3 |
| **RPO (PVC — logical, MySQL)** | 24 hours | mysqldump CronJob (optional, Tutor layer) |
| **RPO (pre-upgrade)** | 0 | On-demand etcd snapshot + Longhorn VolumeSnapshot |
| **RTO (app data rollback)** | < 1 min | Longhorn snapshot revert (Scenario B) |
| **RTO (cluster rollback)** | < 15 min | etcd restore + Longhorn auto-recovery (Scenario A) |
| **RTO (full rebuild)** | < 30 min | Terraform + etcd S3 + Longhorn S3 (Scenario D) |

---

## Appendix A: Longhorn Tuning for Production

### Critical settings and why

| Setting | Value | Why | Risk if wrong |
|---------|-------|-----|---------------|
| `guaranteedInstanceManagerCPU` | 12% | Reserves CPU for Longhorn instance managers (engine + replica processes). Prevents I/O stalls when node CPU is saturated by application workload. | Too low → MySQL writes stall during peak load. Too high → wastes CPU. |
| `storageOverProvisioningPercentage` | 100 | No overprovisioning. Hetzner NVMe has fixed capacity (160G on CX43). Overprovisioning leads to out-of-disk panics. | >100 → volumes may fail when physical disk is full. |
| `storageMinimalAvailablePercentage` | 15 | Longhorn stops scheduling new replicas when <15% free. Early warning threshold. | Too low → disk fills up, Longhorn faults all volumes. |
| `snapshotMaxCount` | 5 | Limits snapshot chain depth per volume. COW snapshots consume space proportional to write rate. | No limit → disk fills from old snapshots. |
| `autoSalvage` | true | Auto-recovers volumes after unexpected detachment (node reboot, OOM kill). Without this, volumes stay faulted until manual intervention. | false → every node reboot requires manual volume recovery. |
| `nodeDrainPolicy` | allow-if-replica-is-stopped | Allows `kubectl drain` during rolling upgrades. Longhorn rebuilds replica from remaining copies. | block-if-contains-last-replica → drain hangs, upgrade blocked. |
| `concurrentReplicaRebuildPerNodeLimit` | 3 | Limits parallel replica rebuilds per node. Prevents network saturation on shared 10Gbit NIC (Hetzner CX series). | Default 5 → network congestion during multi-node recovery. |

### Monitoring alerts (recommended)

Longhorn exposes Prometheus metrics. Recommended alerts:

| Alert | Condition | Severity |
|-------|-----------|----------|
| LonghornVolumesDegraded | `longhorn_volume_robustness{robustness="degraded"} > 0` for 5m | WARNING |
| LonghornVolumesFaulted | `longhorn_volume_robustness{robustness="faulted"} > 0` for 1m | CRITICAL |
| LonghornNodeStorageHigh | `longhorn_node_storage_usage / longhorn_node_storage_capacity > 0.80` | WARNING |
| LonghornNodeStorageCritical | `longhorn_node_storage_usage / longhorn_node_storage_capacity > 0.90` | CRITICAL |
| LonghornBackupFailed | `longhorn_backup_state{state="Error"} > 0` | CRITICAL |

### Disk space calculation for Open edX

| PVC | Size | RF=2 actual | RF=3 actual |
|-----|:----:|:-----------:|:-----------:|
| MySQL | 20G | 40G | 60G |
| MongoDB | 20G | 40G | 60G |
| MeiliSearch | 10G | 20G | 30G |
| Redis | 2G | 4G | 6G |
| **Total** | **52G** | **104G** | **156G** |

With CX43 (160G SSD per worker), 3 workers (480G total):
- RF=2: 104G / 480G = **22% utilization** ✅
- RF=3: 156G / 480G = **33% utilization** ✅

Add monitoring (Prometheus 30G + Loki 20G + Grafana 2G) at RF=2: +104G → **43%** ✅

---

## Appendix B: Hetzner S3 Compatibility

### Known issues with Hetzner Object Storage

| Issue | Affects | Status | Mitigation |
|-------|---------|--------|------------|
| `aws-chunked` transfer encoding rejected (HTTP 400) | Velero + aws-sdk-go-v2 | Open (issue #8660) | Velero removed from plan. Longhorn uses own S3 client — TBD. |
| Path-style only (virtual-hosted not supported) | All S3 clients | Permanent | Force path-style in all configs |
| Rate limit 750 req/s | Large restores | Permanent | Longhorn uses incremental backup (fewer requests) |
| Max object size 5GB (single PUT) | Large volume backups | TBD | Longhorn uses multipart upload — needs E2E test |

### E2E test requirement

Before production use, verify Longhorn backup → Hetzner Object Storage:

```bash
# 1. Create 10G test volume with known data
# 2. Trigger Longhorn backup to Hetzner S3
# 3. Check Longhorn manager logs for errors:
kubectl -n longhorn-system logs -l app=longhorn-manager --tail=100 | grep -i "error\|fail\|s3"
# 4. Verify backup in S3 (via Hetzner Console or mc/aws CLI)
# 5. Delete volume
# 6. Restore from S3
# 7. Verify data integrity
```

If Longhorn has S3 compatibility issues with Hetzner, the fallback is:
- Use MinIO as S3 proxy (adds one component but isolates S3 compatibility)
- Or use a different S3 provider (AWS S3, Cloudflare R2) for backups only

---

## Appendix C: Hetzner CSI Retention (Legacy Path)

### When to use Hetzner CSI instead of Longhorn

| Scenario | Recommendation |
|----------|---------------|
| Budget < €40/mo (CX22/CX32 workers) | Hetzner CSI — Longhorn overhead doesn't fit |
| Dev/staging with no backup requirement | Hetzner CSI — simpler, no configuration |
| Single worker node (no replication possible) | Hetzner CSI — Longhorn RF=2 needs 2+ workers |
| Longhorn has proven S3 incompatibility with Hetzner | Hetzner CSI + manual backup |

### What Hetzner CSI users lose

| Feature | Longhorn | Hetzner CSI |
|---------|:--------:|:-----------:|
| VolumeSnapshot | ✅ | ❌ |
| Replication | ✅ RF=2/3 | ❌ single-attach |
| S3 backup (native) | ✅ | ❌ |
| Pre-upgrade instant snapshot | ✅ | ❌ |
| IOPS | ~50K (NVMe) | ~10K (network) |
| Restore path simplicity | ✅ 1 component | ❌ needs Velero or manual |

### Hetzner CSI users are responsible for their own PVC backup

The module provides Longhorn as the recommended backup path.
If you choose Hetzner CSI, your options:

1. **mysqldump CronJob → S3** (Step 3 of this plan)
2. **Velero + Kopia** (not included in module — deploy yourself, see previous plan v1)
3. **Hetzner Server Snapshots** (via API/Console — captures entire server, not PVC-level)
4. **No backup** (acceptable for dev/staging only)

```hcl
# cluster-csi.tf
# TODO: Demote Hetzner CSI to optional/legacy after Longhorn is battle-tested.
#       Do NOT remove — budget and simple deployments still need it.
# See: PLAN-operational-readiness.md — Appendix C
```

---

## Appendix D: Cluster Sizing Reference

### Minimum for Longhorn

| Requirement | Value | Why |
|-------------|-------|-----|
| Workers | ≥ 2 (recommended ≥ 3) | RF=2 needs 2 nodes; RF=3 needs 3 |
| Worker type | ≥ CX43 (8C/16G/160G SSD) | Longhorn overhead ~2.5G RAM + 1C CPU per node |
| Total cluster SSD | ≥ 320G (2×CX43) | 52G Open edX PVCs × RF=2 = 104G + headroom |

**Below this threshold:** Use Hetzner CSI + manual backup (Appendix C).

### Recommended for production Open edX (5K DAU)

| Role | Count | Type | Total |
|------|:-----:|------|-------|
| Master | 3 | CX33 (4C/8G) | 12C / 24G |
| Worker | 3-4 | CX43 (8C/16G) | 24-32C / 48-64G |
| LB | 2 | lb11 | — |
| **Total** | | | **~€55-66/mo** |

### Scaling path

| DAU | Change needed |
|:---:|--------------|
| 5K → 10K | Add 1 worker CX43 |
| 10K → 15K | Upgrade Worker-DB to CX53 (32G RAM) for MySQL buffer pool |
| 15K → 25K | Add LMS replicas, consider MySQL read replica (ProxySQL) |
| >25K | Managed database (Hetzner Managed MySQL or external) |
