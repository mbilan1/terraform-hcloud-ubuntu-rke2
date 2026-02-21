locals {
  # DECISION: Use for_each for cert-manager primitives.
  # Why: Makes conditional resources explicit and helps avoid upstream-derived
  #      count/index patterns in the generated graph.
  cert_manager_enabled = var.cluster_configuration.cert_manager.preinstall
  cert_manager_ns      = "cert-manager"
}

resource "kubernetes_namespace_v1" "cert_manager" {
  depends_on = [terraform_data.wait_for_infrastructure]
  for_each   = local.cert_manager_enabled ? { ns = true } : {}

  metadata {
    name = local.cert_manager_ns
  }
}

resource "kubernetes_secret_v1" "cert_manager" {
  depends_on = [kubernetes_namespace_v1.cert_manager]
  count      = var.cluster_configuration.cert_manager.preinstall && var.aws_access_key != "" ? 1 : 0
  metadata {
    name      = "route53-credentials-secret"
    namespace = "cert-manager"
  }

  data = {
    secret-access-key = var.aws_secret_key
  }

  lifecycle {
    ignore_changes = [
      metadata[0].annotations,
    ]
  }
}

resource "helm_release" "cert_manager" {
  depends_on = [kubernetes_namespace_v1.cert_manager]
  for_each   = local.cert_manager_enabled ? { release = true } : {}

  name = "cert-manager"
  # https://cert-manager.io/docs/installation/helm/
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = var.cluster_configuration.cert_manager.version

  namespace = local.cert_manager_ns
  timeout   = 600

  set = [
    {
      name  = "crds.enabled"
      value = "true"
    },
    {
      name  = "crds.keep"
      value = "true"
    },
    {
      name  = "startupapicheck.timeout"
      value = "5m"
    },
  ]
}

resource "kubectl_manifest" "cert_manager_issuer" {
  depends_on = [kubernetes_secret_v1.cert_manager, helm_release.cert_manager]
  count      = var.cluster_configuration.cert_manager.use_for_preinstalled_components ? 1 : 0
  yaml_body  = <<YAML
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${var.cluster_issuer_name}
spec:
  acme:
    email: ${var.letsencrypt_issuer}
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: ${var.cluster_issuer_name}
    solvers:
%{if var.route53_zone_id != ""}
    - dns01:
        route53:
          region: ${var.aws_region}
          hostedZoneID: ${var.route53_zone_id}
%{if var.aws_access_key != ""}
          accessKeyID: ${var.aws_access_key}
          secretAccessKeySecretRef:
            name: route53-credentials-secret
            key: secret-access-key
%{endif}
%{else}
    - http01:
        ingress:
          class: nginx
%{endif}
YAML
}
