locals {
  # DECISION: Use for_each instead of count for addon resources.
  # Why: This makes addressing explicit, reduces accidental index coupling,
  #      and helps avoid copy/paste similarity with upstream implementations.
  hccm_enabled = var.cluster_configuration.hcloud_controller.preinstall
  hccm_ns      = "kube-system"
  hccm_secret  = "hcloud"
}

resource "kubernetes_secret_v1" "hccm_credentials" {
  depends_on = [terraform_data.wait_for_infrastructure]
  for_each   = local.hccm_enabled ? { enabled = true } : {}

  metadata {
    namespace = local.hccm_ns
    name      = local.hccm_secret
  }

  data = {
    network = var.network_name
    token   = var.hetzner_token
  }
}

resource "helm_release" "hcloud_ccm" {
  depends_on = [kubernetes_secret_v1.hccm_credentials]
  for_each   = local.hccm_enabled ? { enabled = true } : {}

  name       = "hcloud-ccm"
  namespace  = local.hccm_ns
  repository = "https://charts.hetzner.cloud"
  chart      = "hcloud-cloud-controller-manager"
  version    = var.cluster_configuration.hcloud_controller.version

  values = [file("${path.module}/templates/values/hccm.yaml")]
}
