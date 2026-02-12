# ──────────────────────────────────────────────────────────────────────────────
# OpenEdx Harmony Chart
# https://github.com/openedx/openedx-k8s-harmony
#
# Deploys the Harmony Helm chart with infrastructure-specific values for
# Hetzner Cloud (hostPort ingress, single LB, cert-manager disabled).
# ──────────────────────────────────────────────────────────────────────────────

# Cross-variable safety checks
check "harmony_requires_cert_manager" {
  assert {
    condition     = !var.harmony.enabled || var.cluster_configuration.cert_manager.preinstall
    error_message = "Harmony requires cert-manager CRDs. Set cluster_configuration.cert_manager.preinstall = true when harmony.enabled = true."
  }
}

check "harmony_requires_workers_for_lb" {
  assert {
    condition     = !var.harmony.enabled || var.worker_node_count > 0
    error_message = "Harmony routes HTTP/HTTPS through worker node targets on the ingress LB. Set worker_node_count >= 1 when harmony.enabled = true, or traffic will not reach ingress-nginx."
  }
}

locals {
  harmony_infrastructure_values = {
    clusterDomain     = var.domain
    notificationEmail = var.letsencrypt_issuer

    # Use hostPort + DaemonSet so traffic flows through the single management LB
    # instead of HCCM creating a second Hetzner Cloud LB via Service type LoadBalancer.
    ingress-nginx = {
      controller = {
        kind = "DaemonSet"
        hostPort = {
          enabled = true
        }
        service = {
          type = "ClusterIP"
        }
        config = {
          proxy-body-size = var.nginx_ingress_proxy_body_size
        }
      }
    }

    # cert-manager is installed by the Terraform module (cluster-certmanager.tf)
    # with Route53 DNS-01 / HTTP-01 ClusterIssuer. Harmony must not install a second one.
    cert-manager = {
      enabled = false
    }
  }
}

resource "kubernetes_namespace_v1" "harmony" {
  depends_on = [null_resource.wait_for_cluster_ready]
  count      = var.harmony.enabled ? 1 : 0

  metadata {
    name = "harmony"
  }

  lifecycle {
    ignore_changes = [
      metadata[0].annotations,
      metadata[0].labels,
    ]
  }
}

resource "helm_release" "harmony" {
  depends_on = [
    kubernetes_namespace_v1.harmony,
    helm_release.cert_manager,
    helm_release.hccm,
    helm_release.hcloud_csi,
  ]
  count = var.harmony.enabled ? 1 : 0

  name       = "harmony"
  repository = "https://openedx.github.io/openedx-k8s-harmony"
  chart      = "harmony-chart"
  version    = var.harmony.version != "" ? var.harmony.version : null
  namespace  = "harmony"
  timeout    = 900

  # Infrastructure values first, then user overrides
  values = concat(
    [yamlencode(local.harmony_infrastructure_values)],
    var.harmony.extra_values,
  )

  # Wait for cert-manager CRDs to be available (installed by cluster-certmanager.tf)
  skip_crds = true
}
