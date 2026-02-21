# ──────────────────────────────────────────────────────────────────────────────
# OpenEdx Harmony Chart
# https://github.com/openedx/openedx-k8s-harmony
#
# Deploys the Harmony Helm chart with infrastructure-specific values for
# Hetzner Cloud (hostPort ingress, single LB, cert-manager disabled).
# ──────────────────────────────────────────────────────────────────────────────

resource "kubernetes_namespace_v1" "harmony" {
  depends_on = [terraform_data.wait_for_infrastructure]
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
    helm_release.hcloud_ccm,
    helm_release.hcloud_csi,
    helm_release.longhorn, # Storage must be ready before app workloads
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

  # Wait for cert-manager CRDs to be available (installed by certmanager.tf)
  skip_crds = true
}
