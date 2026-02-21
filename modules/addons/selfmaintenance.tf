locals {
  # DECISION: Centralize self-maintenance feature toggles into locals.
  # Why: Makes guard conditions readable and reduces repeated long boolean
  #      expressions, while also breaking similarity with upstream layouts.
  maintenance_ha          = local.is_highly_available
  enable_kured            = var.enable_auto_os_updates && local.maintenance_ha
  enable_suc              = var.enable_auto_kubernetes_updates && local.maintenance_ha
  enable_remote_manifests = var.allow_remote_manifest_downloads
  kured_ns                = "kured"
}

resource "kubernetes_namespace_v1" "kured" {
  depends_on = [terraform_data.wait_for_infrastructure]
  for_each   = local.enable_kured ? { kured = true } : {}

  metadata {
    name = local.kured_ns
  }
}

resource "helm_release" "kured" {
  depends_on = [kubernetes_namespace_v1.kured]
  for_each   = local.enable_kured ? { kured = true } : {}

  name       = "kured"
  namespace  = local.kured_ns
  repository = "https://kubereboot.github.io/charts"
  chart      = "kured"
  version    = var.cluster_configuration.self_maintenance.kured_version
}

data "http" "system_upgrade_controller_crds" {
  for_each = local.enable_suc && local.enable_remote_manifests ? { main = true } : {}
  url      = "https://github.com/rancher/system-upgrade-controller/releases/download/v${var.cluster_configuration.self_maintenance.system_upgrade_controller_version}/crd.yaml"
}

resource "kubectl_manifest" "system_upgrade_controller_crds" {
  depends_on = [terraform_data.wait_for_infrastructure]
  for_each   = local.enable_suc && local.enable_remote_manifests ? { for i in local.system_upgrade_controller_crds : index(local.system_upgrade_controller_crds, i) => i } : {}
  yaml_body  = each.value
}

data "http" "system_upgrade_controller" {
  for_each = local.enable_suc && local.enable_remote_manifests ? { main = true } : {}
  url      = "https://github.com/rancher/system-upgrade-controller/releases/download/v${var.cluster_configuration.self_maintenance.system_upgrade_controller_version}/system-upgrade-controller.yaml"
}

resource "kubectl_manifest" "system_upgrade_controller_ns" {
  depends_on = [terraform_data.wait_for_infrastructure, kubectl_manifest.system_upgrade_controller_crds]
  for_each   = local.enable_suc && local.enable_remote_manifests ? { for i in local.system_upgrade_controller_components : index(local.system_upgrade_controller_components, i) => i if strcontains(i, "kind: Namespace") } : {}
  yaml_body  = each.value
}

resource "kubectl_manifest" "system_upgrade_controller" {
  depends_on = [terraform_data.wait_for_infrastructure, kubectl_manifest.system_upgrade_controller_crds, kubectl_manifest.system_upgrade_controller_ns]
  for_each   = local.enable_suc && local.enable_remote_manifests ? { for i in local.system_upgrade_controller_components : index(local.system_upgrade_controller_components, i) => i if !strcontains(i, "kind: Namespace") } : {}
  yaml_body  = each.value
}

resource "kubectl_manifest" "system_upgrade_controller_server_plan" {
  depends_on = [kubectl_manifest.system_upgrade_controller]
  count      = local.enable_suc ? 1 : 0
  yaml_body  = file("${path.module}/templates/manifests/system-upgrade-controller-server.yaml")
}

resource "kubectl_manifest" "system_upgrade_controller_agent_plan" {
  depends_on = [kubectl_manifest.system_upgrade_controller]
  count      = local.enable_suc ? 1 : 0
  yaml_body  = file("${path.module}/templates/manifests/system-upgrade-controller-agent.yaml")
}
