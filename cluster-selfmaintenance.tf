resource "kubernetes_namespace_v1" "kured" {
  depends_on = [null_resource.wait_for_cluster_ready]
  count      = var.enable_auto_os_updates && local.is_ha_cluster ? 1 : 0
  metadata {
    name = "kured"
  }

  lifecycle {
    ignore_changes = [
      metadata[0].annotations,
    ]
  }
}

# Warn when auto-update flags are true but cluster is non-HA (single master).
# Kured and System Upgrade Controller are only deployed on HA clusters (>= 3 masters)
# because rebooting/upgrading a single control-plane node causes full downtime.
check "auto_updates_require_ha" {
  assert {
    condition     = local.is_ha_cluster || (!var.enable_auto_os_updates && !var.enable_auto_kubernetes_updates)
    error_message = "enable_auto_os_updates and enable_auto_kubernetes_updates have no effect on non-HA clusters (master_node_count < 3). Kured and System Upgrade Controller are only deployed on HA clusters."
  }
}

resource "helm_release" "kured" {
  depends_on = [kubernetes_namespace_v1.kured]
  count      = var.enable_auto_os_updates && local.is_ha_cluster ? 1 : 0
  repository = "https://kubereboot.github.io/charts"
  chart      = "kured"
  name       = "kured"
  namespace  = kubernetes_namespace_v1.kured[0].metadata[0].name
  version    = var.cluster_configuration.self_maintenance.kured_version
}

data "http" "system_upgrade_controller_crds" {
  count = var.enable_auto_kubernetes_updates && local.is_ha_cluster ? 1 : 0
  url   = "https://github.com/rancher/system-upgrade-controller/releases/download/v${var.cluster_configuration.self_maintenance.system_upgrade_controller_version}/crd.yaml"
}

resource "kubectl_manifest" "system_upgrade_controller_crds" {
  depends_on = [null_resource.wait_for_cluster_ready]
  for_each   = var.enable_auto_kubernetes_updates && local.is_ha_cluster ? { for i in local.system_upgrade_controller_crds : index(local.system_upgrade_controller_crds, i) => i } : {}
  yaml_body  = each.value
}

data "http" "system_upgrade_controller" {
  count = var.enable_auto_kubernetes_updates && local.is_ha_cluster ? 1 : 0
  url   = "https://github.com/rancher/system-upgrade-controller/releases/download/v${var.cluster_configuration.self_maintenance.system_upgrade_controller_version}/system-upgrade-controller.yaml"
}

resource "kubectl_manifest" "system_upgrade_controller_ns" {
  depends_on = [null_resource.wait_for_cluster_ready, kubectl_manifest.system_upgrade_controller_crds]
  for_each   = var.enable_auto_kubernetes_updates && local.is_ha_cluster ? { for i in local.system_upgrade_controller_components : index(local.system_upgrade_controller_components, i) => i if strcontains(i, "kind: Namespace") } : {}
  yaml_body  = each.value
}

resource "kubectl_manifest" "system_upgrade_controller" {
  depends_on = [null_resource.wait_for_cluster_ready, kubectl_manifest.system_upgrade_controller_crds, kubectl_manifest.system_upgrade_controller_ns]
  for_each   = var.enable_auto_kubernetes_updates && local.is_ha_cluster ? { for i in local.system_upgrade_controller_components : index(local.system_upgrade_controller_components, i) => i if !strcontains(i, "kind: Namespace") } : {}
  yaml_body  = each.value
}

resource "kubectl_manifest" "system_upgrade_controller_server_plan" {
  depends_on = [kubectl_manifest.system_upgrade_controller]
  count      = var.enable_auto_kubernetes_updates && local.is_ha_cluster ? 1 : 0
  yaml_body  = file("${path.module}/templates/manifests/system-upgrade-controller-server.yaml")
}

resource "kubectl_manifest" "system_upgrade_controller_agent_plan" {
  depends_on = [kubectl_manifest.system_upgrade_controller]
  count      = var.enable_auto_kubernetes_updates && local.is_ha_cluster ? 1 : 0
  yaml_body  = file("${path.module}/templates/manifests/system-upgrade-controller-agent.yaml")
}