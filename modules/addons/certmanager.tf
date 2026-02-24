# ──────────────────────────────────────────────────────────────────────────────
# cert-manager — Automated TLS certificate lifecycle management
#
# DECISION: Deploy cert-manager via official Jetstack Helm chart.
# Why: Industry-standard for automated TLS in Kubernetes. Supports both
#      HTTP-01 (ingress-based) and DNS-01 (Route53) ACME solvers.
#      Alternatives (ambassador, traefik-native) are ingress-controller-specific
#      and don't support the flexible solver switching we need.
# ──────────────────────────────────────────────────────────────────────────────

locals {
  # Pre-compute whether cert-manager should be deployed at all.
  # Used across namespace, secret, helm release, and ClusterIssuer resources.
  deploy_cert_manager = var.cluster_configuration.cert_manager.preinstall

  # Route53 DNS-01 solver is available only when both keys are provided.
  # When unavailable, fall back to HTTP-01 (ingress-based challenge).
  route53_solver_available = var.aws_access_key != "" && var.route53_zone_id != ""

  # DECISION: Build the ACME solvers list dynamically based on credential availability.
  # Why: DNS-01 is required for wildcard certs (*.domain). HTTP-01 is simpler for
  #      single-domain setups or when AWS credentials are not provided. The solver
  #      selection is transparent to the operator — provide Route53 credentials and
  #      you get DNS-01 automatically.
  # WORKAROUND: Build two complete ClusterIssuer YAML bodies instead of a single
  # conditional solver list. OpenTofu requires both ternary branches to have the
  # same object schema, but dns01 and http01 solver shapes are structurally
  # different. Building the full manifest per-variant avoids this type limitation.
  # TODO: Revisit if OpenTofu gains union types or jsonencode-in-ternary support.
  cluster_issuer_yaml = local.route53_solver_available ? yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = var.cluster_issuer_name
    }
    spec = {
      acme = {
        email  = var.letsencrypt_issuer
        server = "https://acme-v02.api.letsencrypt.org/directory"
        privateKeySecretRef = {
          name = var.cluster_issuer_name
        }
        solvers = [
          {
            dns01 = {
              route53 = {
                region       = var.aws_region
                hostedZoneID = var.route53_zone_id
                accessKeyID  = var.aws_access_key
                secretAccessKeySecretRef = {
                  name = "route53-credentials-secret"
                  key  = "secret-access-key"
                }
              }
            }
          }
        ]
      }
    }
    }) : yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = var.cluster_issuer_name
    }
    spec = {
      acme = {
        email  = var.letsencrypt_issuer
        server = "https://acme-v02.api.letsencrypt.org/directory"
        privateKeySecretRef = {
          name = var.cluster_issuer_name
        }
        solvers = [
          {
            http01 = {
              ingress = {
                class = "nginx"
              }
            }
          }
        ]
      }
    }
  })
}

resource "kubernetes_namespace_v1" "certificate_manager" {
  depends_on = [terraform_data.wait_for_infrastructure]

  for_each = local.deploy_cert_manager ? toset(["cert-manager"]) : toset([])

  metadata {
    name = each.key
    labels = {
      "app.kubernetes.io/component" = "certificate-management"
      "managed-by"                  = "opentofu"
    }
  }

  lifecycle {
    # NOTE: Kubernetes controllers and Helm inject their own annotations/labels
    # (app.kubernetes.io/managed-by, meta.helm.sh/release-*). Ignoring these
    # prevents noisy diffs on every subsequent plan.
    ignore_changes = [
      metadata[0].annotations,
      metadata[0].labels,
    ]
  }
}

# DECISION: Store Route53 secret key in a dedicated Kubernetes Secret.
# Why: Secret values in ClusterIssuer spec are stored in etcd unencrypted
#      by default. A referenced Secret is the cert-manager recommended pattern
#      and integrates with RBAC policies and future external-secrets-operator.
# See: https://cert-manager.io/docs/configuration/acme/dns01/route53/
resource "kubernetes_secret_v1" "dns_solver_credentials" {
  depends_on = [kubernetes_namespace_v1.certificate_manager]

  # NOTE: count (not for_each) because the condition references var.aws_access_key
  # which is marked sensitive — OpenTofu forbids sensitive values in for_each keys.
  count = local.deploy_cert_manager && var.aws_access_key != "" ? 1 : 0

  metadata {
    name      = "route53-credentials-secret"
    namespace = "cert-manager"
  }

  data = {
    secret-access-key = var.aws_secret_key
  }

  lifecycle {
    ignore_changes = [metadata[0].annotations, metadata[0].labels]
  }
}

resource "helm_release" "certificate_manager" {
  depends_on = [kubernetes_namespace_v1.certificate_manager]

  for_each = local.deploy_cert_manager ? toset(["cert-manager"]) : toset([])

  # Official cert-manager Helm chart from Jetstack
  # Ref: https://cert-manager.io/docs/installation/helm/
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  namespace  = "cert-manager"
  version    = var.cluster_configuration.cert_manager.version
  timeout    = 600

  # DECISION: Use yamlencode for Helm values instead of individual set blocks.
  # Why: Structured values are easier to read, review, and extend than flat
  #      set blocks. All CRD-related flags grouped in one values object.
  values = [yamlencode({
    crds = {
      enabled = true
      keep    = true
    }
    startupapicheck = {
      timeout = "5m"
    }
  })]
}

# DECISION: Build ClusterIssuer via yamlencode() instead of heredoc YAML.
# Why: yamlencode produces deterministic output and prevents indentation bugs
#      that are common with heredoc templates. The full manifest is pre-built
#      in local.cluster_issuer_yaml to work around OpenTofu's ternary type
#      constraints (dns01 and http01 have incompatible object shapes).
resource "kubectl_manifest" "letsencrypt_cluster_issuer" {
  depends_on = [kubernetes_secret_v1.dns_solver_credentials, helm_release.certificate_manager]

  for_each = var.cluster_configuration.cert_manager.use_for_preinstalled_components ? toset(["issuer"]) : toset([])

  yaml_body = local.cluster_issuer_yaml
}

# ──────────────────────────────────────────────────────────────────────────────
# Harmony: default TLS bootstrap certificate
#
# WORKAROUND: Harmony's built-in echo Ingress is HTTP-only (no spec.tls).
# Why: ingress-nginx will otherwise serve its self-signed "Fake Certificate" for
#      the HTTPS catch-all vhost, which looks like a broken platform.
#      Issuing a real cert for var.cluster_domain and configuring ingress-nginx with
#      --default-ssl-certificate fixes the UX without requiring Tutor/Open edX.
# See: https://kubernetes.github.io/ingress-nginx/user-guide/tls/#default-ssl-certificate
# See: https://cert-manager.io/docs/usage/certificate/
resource "kubectl_manifest" "harmony_default_tls_certificate" {
  depends_on = [
    kubernetes_namespace_v1.harmony,
    helm_release.harmony,
    kubectl_manifest.letsencrypt_cluster_issuer,
  ]

  for_each = (
    var.harmony.enabled
    && local.deploy_cert_manager
    && var.cluster_configuration.cert_manager.use_for_preinstalled_components
    && local.harmony_enable_default_tls_certificate
  ) ? toset(["harmony-tls"]) : toset([])

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "harmony-default-tls"
      namespace = "harmony"
    }
    spec = {
      secretName = local.harmony_default_tls_secret_name
      dnsNames   = [var.cluster_domain]
      issuerRef = {
        name = var.cluster_issuer_name
        kind = "ClusterIssuer"
      }
    }
  })
}
