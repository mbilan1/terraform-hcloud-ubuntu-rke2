# ──────────────────────────────────────────────────────────────────────────────
# Hetzner Cloud CSI Driver
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

# The CSI driver requires the same "hcloud" secret as HCCM. When HCCM is
# disabled but CSI is enabled we must still ensure the secret exists.
resource "kubernetes_secret_v1" "hcloud_csi" {
  depends_on = [terraform_data.wait_for_infrastructure]

  # Only create stand-alone secret when HCCM is NOT creating one.
  count = var.cluster_configuration.hcloud_csi.preinstall && !var.cluster_configuration.hcloud_controller.preinstall ? 1 : 0

  metadata {
    name      = "hcloud"
    namespace = "kube-system"
  }

  data = {
    token   = var.hetzner_token
    network = var.network_name
  }

  lifecycle {
    ignore_changes = [
      metadata[0].annotations,
    ]
  }
}

resource "helm_release" "hcloud_csi" {
  depends_on = [
    terraform_data.wait_for_infrastructure,
    kubernetes_secret_v1.hccm_credentials, # wait for the shared secret if HCCM creates it
    kubernetes_secret_v1.hcloud_csi,       # or the one we create ourselves
  ]

  count = var.cluster_configuration.hcloud_csi.preinstall ? 1 : 0

  repository = "https://charts.hetzner.cloud"
  chart      = "hcloud-csi"
  name       = "hcloud-csi"
  namespace  = "kube-system"
  version    = var.cluster_configuration.hcloud_csi.version

  values = [yamlencode({
    storageClasses = [{
      name                = "hcloud-volumes"
      defaultStorageClass = var.cluster_configuration.hcloud_csi.default_storage_class
      reclaimPolicy       = var.cluster_configuration.hcloud_csi.reclaim_policy
    }]
  })]
}
