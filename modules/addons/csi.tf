# ──────────────────────────────────────────────────────────────────────────────
# Hetzner Cloud CSI Driver — Persistent volume provisioner
# https://github.com/hetznercloud/csi-driver
#
# Provides ReadWriteOnce persistent volumes backed by Hetzner Cloud Volumes.
# The driver reuses the existing "hcloud" secret in kube-system that is also
# shared with the Hetzner Cloud Controller Manager (HCCM).
#
# TODO: Demote Hetzner CSI to optional/legacy after Longhorn is battle-tested.
#       Do NOT remove — budget and simple deployments still need it.
# See: docs/PLAN-operational-readiness.md — Appendix C
# ──────────────────────────────────────────────────────────────────────────────

locals {
  deploy_csi = var.cluster_configuration.hcloud_csi.preinstall
  # The CSI driver requires the "hcloud" secret. When HCCM is enabled, it already
  # creates this secret. We only create a standalone copy when HCCM is disabled.
  csi_needs_own_secret = local.deploy_csi && !local.deploy_hccm
}

# Standalone "hcloud" secret — created only when HCCM is NOT managing one.
# DECISION: Share the same secret name ("hcloud") rather than creating a separate CSI-specific secret.
# Why: Both HCCM and CSI expect the secret at "hcloud" in kube-system. Using a single
#      name avoids Helm values overrides and matches the upstream chart defaults.
resource "kubernetes_secret_v1" "hcloud_csi" {
  depends_on = [terraform_data.wait_for_infrastructure]

  for_each = local.csi_needs_own_secret ? toset(["hcloud-csi"]) : toset([])

  metadata {
    name      = "hcloud"
    namespace = "kube-system"
    labels = {
      "app.kubernetes.io/component" = "csi-driver"
      "managed-by"                  = "opentofu"
    }
  }

  data = {
    token   = var.hcloud_api_token
    network = var.network_name
  }

  lifecycle {
    ignore_changes = [metadata[0].annotations, metadata[0].labels]
  }
}

resource "helm_release" "hcloud_csi" {
  depends_on = [
    terraform_data.wait_for_infrastructure,
    kubernetes_secret_v1.cloud_controller_token, # shared secret when HCCM manages it
    kubernetes_secret_v1.hcloud_csi,             # standalone secret when HCCM is off
  ]

  for_each = local.deploy_csi ? toset(["hcloud-csi"]) : toset([])

  name       = "hcloud-csi"
  repository = "https://charts.hetzner.cloud"
  chart      = "hcloud-csi"
  namespace  = "kube-system"
  version    = var.cluster_configuration.hcloud_csi.version
  timeout    = 300

  # DECISION: Configure storage class inline via Helm values.
  # Why: The Hetzner CSI chart supports storageClasses[] in values.yaml,
  #      which is cleaner than creating a separate StorageClass resource.
  values = [yamlencode({
    storageClasses = [{
      name                = "hcloud-volumes"
      defaultStorageClass = var.cluster_configuration.hcloud_csi.default_storage_class
      reclaimPolicy       = var.cluster_configuration.hcloud_csi.reclaim_policy
    }]
    controller = {
      hcloudVolumeDefaultLocation = ""
    }
  })]
}
