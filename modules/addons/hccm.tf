# ──────────────────────────────────────────────────────────────────────────────
# Hetzner Cloud Controller Manager (HCCM)
#
# DECISION: Deploy via official Helm chart from charts.hetzner.cloud.
# Why: Hetzner-maintained chart. Provides node lifecycle management (IP
#      assignment, labeling), cloud route configuration for pod networking,
#      and Load Balancer reconciliation with the Hetzner Cloud API.
# See: https://github.com/hetznercloud/hcloud-cloud-controller-manager
# ──────────────────────────────────────────────────────────────────────────────

locals {
  # Pre-compute deployment flag once; reused by secret and helm release.
  deploy_hccm = var.cluster_configuration.hcloud_controller.preinstall
}

# DECISION: Store Hetzner API token in a dedicated Kubernetes Secret.
# Why: Helm values end up in the release ConfigMap (visible in etcd). A
#      proper Secret integrates with RBAC, is auditable via K8s audit logs,
#      and supports future migration to external-secrets-operator.
resource "kubernetes_secret_v1" "cloud_controller_token" {
  depends_on = [terraform_data.wait_for_infrastructure]

  for_each = local.deploy_hccm ? toset(["hcloud-ccm"]) : toset([])

  metadata {
    name      = "hcloud"
    namespace = "kube-system"
    labels = {
      "app.kubernetes.io/component" = "cloud-controller"
      "managed-by"                  = "opentofu"
    }
  }

  data = {
    token   = var.hcloud_api_token
    network = var.network_name
  }

  lifecycle {
    # NOTE: Kubernetes adds internal annotations (kubectl.kubernetes.io/last-applied-configuration)
    # that should not trigger a diff on every plan.
    ignore_changes = [metadata[0].annotations, metadata[0].labels]
  }
}

resource "helm_release" "cloud_controller" {
  depends_on = [kubernetes_secret_v1.cloud_controller_token]

  for_each = local.deploy_hccm ? toset(["hccm"]) : toset([])

  name       = "hccm"
  repository = "https://charts.hetzner.cloud"
  chart      = "hcloud-cloud-controller-manager"
  namespace  = "kube-system"
  version    = var.cluster_configuration.hcloud_controller.version
  timeout    = 300

  # DECISION: Enable networking integration for cloud route configuration.
  # Why: HCCM sets up cloud routes for pod-to-pod traffic across nodes on
  #      the Hetzner private network. Without this, inter-node pod traffic
  #      relies solely on the CNI overlay (VXLAN), which adds latency.
  values = [yamlencode({
    networking = {
      enabled     = true
      clusterCIDR = "10.42.0.0/16"
    }
    env = {
      HCLOUD_LOAD_BALANCERS_ENABLED = {
        value = "true"
      }
    }
  })]
}
