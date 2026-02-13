resource "kubernetes_namespace_v1" "istio_system" {
  count      = var.cluster_configuration.istio_service_mesh.preinstall ? 1 : 0
  depends_on = [null_resource.wait_for_cluster_ready]
  metadata {
    name = "istio-system"
  }

  lifecycle {
    ignore_changes = [
      metadata[0].annotations,
    ]
  }
}

resource "helm_release" "istio_base" {
  count      = var.cluster_configuration.istio_service_mesh.preinstall ? 1 : 0
  depends_on = [kubernetes_namespace_v1.istio_system[0]]
  repository = local.istio_charts_url
  chart      = "base"
  name       = "istio-base"
  namespace  = kubernetes_namespace_v1.istio_system[0].metadata[0].name
  version    = var.cluster_configuration.istio_service_mesh.version
}

resource "helm_release" "istiod" {
  count      = var.cluster_configuration.istio_service_mesh.preinstall ? 1 : 0
  repository = local.istio_charts_url
  chart      = "istiod"
  name       = "istiod"
  namespace  = kubernetes_namespace_v1.istio_system[0].metadata[0].name
  version    = var.cluster_configuration.istio_service_mesh.version
  depends_on = [helm_release.istio_base[0], kubectl_manifest.gateway_api]
  values     = local.istio_values
}

data "http" "gateway_api" {
  # Supply-chain/reproducibility toggle:
  # keep current behavior by default, but allow operators to disable plan-time
  # remote downloads for stricter/offline environments.
  count = var.preinstall_gateway_api_crds && var.allow_remote_manifest_downloads ? 1 : 0
  url   = "https://github.com/kubernetes-sigs/gateway-api/releases/download/${var.gateway_api_version}/standard-install.yaml"
}

resource "kubectl_manifest" "gateway_api" {
  depends_on = [null_resource.wait_for_cluster_ready]
  for_each   = var.preinstall_gateway_api_crds && var.allow_remote_manifest_downloads ? { for i in local.gateway_api_crds : index(local.gateway_api_crds, i) => i } : {}
  yaml_body  = each.value
}
