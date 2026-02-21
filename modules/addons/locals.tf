# ──────────────────────────────────────────────────────────────────────────────
# Addons module — computed locals
# ──────────────────────────────────────────────────────────────────────────────

locals {
  is_highly_available = var.master_node_count >= 3

  # --- System Upgrade Controller manifests ---
  # WORKAROUND: Default to empty lists instead of null.
  # Why: In `tofu test` with mock_provider, data.http responses may be unknown/null.
  #      Using [] keeps downstream for_each expressions plan-time evaluable.
  system_upgrade_controller_crds       = try(split("---", data.http.system_upgrade_controller_crds[0].response_body), [])
  system_upgrade_controller_components = try(split("---", data.http.system_upgrade_controller[0].response_body), [])

  # --- Longhorn S3 endpoint auto-detection ---
  # DECISION: Auto-detect Hetzner Object Storage endpoint from lb_location for Longhorn.
  # Why: Reduces configuration burden — operator only needs backup_target + credentials.
  # See: https://docs.hetzner.com/storage/object-storage/overview
  longhorn_s3_endpoint = (
    trimspace(var.cluster_configuration.longhorn.s3_endpoint) != ""
    ? var.cluster_configuration.longhorn.s3_endpoint
    : "https://${var.lb_location}.your-objectstorage.com"
  )

  longhorn_backup_target = (
    trimspace(var.cluster_configuration.longhorn.backup_target) != ""
    ? var.cluster_configuration.longhorn.backup_target
    : ""
  )

  # --- Harmony infrastructure values ---
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

    # cert-manager is installed by the Terraform module (certmanager.tf)
    # with Route53 DNS-01 / HTTP-01 ClusterIssuer. Harmony must not install a second one.
    cert-manager = {
      enabled = false
    }
  }
}
