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

# Cross-variable safety checks (inline with addon — self-contained pattern)
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
    condition     = !var.velero.enabled || var.cluster_configuration.hcloud_csi.preinstall
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
        disabled                   = false
        schedule                   = var.velero.backup_schedule
        useOwnerReferencesInBackup = false
        template = {
          ttl                      = var.velero.backup_ttl
          includedNamespaces       = ["*"]
          defaultVolumesToFsBackup = true
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
    helm_release.hcloud_csi, # PVCs must be provisionable before backup
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
