# ──────────────────────────────────────────────────────────────────────────────
# Addons module — computed locals
# ──────────────────────────────────────────────────────────────────────────────

locals {
  is_ha_cluster = var.control_plane_count >= 3

  # --- Harmony TLS bootstrap ---
  # DECISION: Configure a default TLS certificate for Harmony's ingress-nginx.
  # Why: ingress-nginx uses a self-signed "Fake Certificate" for the HTTPS catch-all
  #      server unless --default-ssl-certificate is set. This causes an immediate
  #      "TLS error" impression on https://<domain>/ even when the cluster is healthy.
  #      We keep this opt-out (enabled by default) so the module feels "working" out
  #      of the box, while still allowing advanced operators to manage TLS differently.
  # See: https://kubernetes.github.io/ingress-nginx/user-guide/tls/#default-ssl-certificate
  harmony_enable_default_tls_certificate = (
    var.harmony.enabled && try(var.harmony.enable_default_tls_certificate, true)
  )

  harmony_default_tls_secret_name = (
    trimspace(try(var.harmony.default_tls_secret_name, "")) != ""
    ? trimspace(var.harmony.default_tls_secret_name)
    : "harmony-default-tls"
  )

  # --- System Upgrade Controller manifests ---
  suc_crd_documents        = try(split("---", data.http.suc_crd_manifest[0].response_body), null)
  suc_controller_documents = try(split("---", data.http.suc_controller_manifest[0].response_body), null)

  # --- Longhorn S3 endpoint auto-detection ---
  # DECISION: Auto-detect Hetzner Object Storage endpoint from load_balancer_location for Longhorn.
  # Why: Reduces configuration burden — operator only needs backup_target + credentials.
  # See: https://docs.hetzner.com/storage/object-storage/overview
  longhorn_s3_endpoint = (
    trimspace(var.cluster_configuration.longhorn.s3_endpoint) != ""
    ? var.cluster_configuration.longhorn.s3_endpoint
    : "https://${var.load_balancer_location}.your-objectstorage.com"
  )

  longhorn_backup_target = (
    trimspace(var.cluster_configuration.longhorn.backup_target) != ""
    ? var.cluster_configuration.longhorn.backup_target
    : ""
  )

  # --- Harmony infrastructure values ---
  harmony_infrastructure_values = {
    clusterDomain     = var.cluster_domain
    notificationEmail = var.letsencrypt_issuer

    # Use hostPort + DaemonSet so traffic flows through the single management LB
    # instead of HCCM creating a second Hetzner Cloud LB via Service type LoadBalancer.
    ingress-nginx = {
      controller = {
        kind = "DaemonSet"
        hostPort = {
          enabled = true
        }

        # WORKAROUND: Provide a valid default HTTPS certificate even when an Ingress
        # resource does not define spec.tls (e.g. Harmony's echo Ingress).
        # Why: Without this, ingress-nginx serves the self-signed "Fake Certificate"
        #      on the catch-all server and browsers show a scary TLS error.
        # See: https://kubernetes.github.io/ingress-nginx/user-guide/tls/#default-ssl-certificate
        extraArgs = local.harmony_enable_default_tls_certificate ? {
          "default-ssl-certificate" = "harmony/${local.harmony_default_tls_secret_name}"
        } : {}

        service = {
          type = "ClusterIP"
        }
        config = {
          proxy-body-size = var.nginx_ingress_proxy_body_size
        }
      }
    }

    # cert-manager is installed by the Terraform module (certmanager.tf)
    # with Route53 DNS-01 / HTTP-01 ClusterIssuer. Harmony must not install a second one.
    cert-manager = {
      enabled = false
    }
  }
}
