# ──────────────────────────────────────────────────────────────────────────────
# OpenEdx Harmony Chart — educational platform orchestration layer
# https://github.com/openedx/openedx-k8s-harmony
#
# DECISION: Deploy Harmony via its own Helm release with infrastructure-specific
#   overrides computed in locals.tf (harmony_infrastructure_values).
# Why: Harmony bundles ingress-nginx + cert-manager sub-charts. We disable
#      cert-manager (managed in certmanager.tf) and configure ingress-nginx
#      for hostPort+DaemonSet to work with Hetzner's single-LB architecture.
# ──────────────────────────────────────────────────────────────────────────────

locals {
  deploy_harmony = var.harmony.enabled
}

resource "kubernetes_namespace_v1" "harmony" {
  depends_on = [terraform_data.wait_for_infrastructure]

  for_each = local.deploy_harmony ? toset(["harmony"]) : toset([])

  metadata {
    name = "harmony"
    labels = {
      "app.kubernetes.io/part-of" = "openedx-harmony"
      "managed-by"                = "opentofu"
    }
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
    helm_release.certificate_manager,
    helm_release.cloud_controller,
    helm_release.hcloud_csi,
    helm_release.longhorn, # Storage must be ready before app workloads
  ]

  for_each = local.deploy_harmony ? toset(["harmony"]) : toset([])

  name       = "harmony"
  repository = "https://openedx.github.io/openedx-k8s-harmony"
  chart      = "harmony-chart"
  namespace  = "harmony"
  version    = var.harmony.version != "" ? var.harmony.version : null
  timeout    = 900

  # DECISION: Infrastructure values first, then user overrides via concat.
  # Why: User-provided extra_values can override any infrastructure default
  #      (Helm last-wins semantics), giving operators full control while
  #      still providing sensible defaults for Hetzner Cloud.
  values = concat(
    [yamlencode(local.harmony_infrastructure_values)],
    var.harmony.extra_values,
  )

  # cert-manager CRDs are installed by certmanager.tf; skip bundled CRDs
  skip_crds = true
}
