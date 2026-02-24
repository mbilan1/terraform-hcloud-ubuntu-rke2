# ──────────────────────────────────────────────────────────────────────────────
# Addons module variables (L4)
#
# DECISION: Variables split into two groups:
#   1) Infrastructure outputs — wiring from module.infrastructure
#   2) Root passthrough — user-facing configuration passed from root module
# Why: Clear contract between layers. Each variable documents its source.
# ──────────────────────────────────────────────────────────────────────────────

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  From infrastructure module                                                ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

variable "cluster_ready" {
  description = "Dependency anchor from infrastructure — addons wait for this"
  type        = string
}

variable "master_ipv4" {
  description = "IPv4 of master[0] for SSH provisioners (health checks, snapshots)"
  type        = string
}

variable "ssh_private_key" {
  description = "SSH private key for remote-exec provisioners"
  type        = string
  sensitive   = true
}

variable "network_name" {
  description = "Name of the Hetzner Cloud private network (for hcloud secrets)"
  type        = string
}

variable "worker_node_names" {
  description = "Names of all worker nodes (for kubernetes_labels)"
  type        = list(string)
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  Root passthrough — user-facing configuration                              ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

variable "hcloud_api_token" {
  description = "Hetzner Cloud API token (for hcloud secrets)"
  type        = string
  sensitive   = true
}

variable "cluster_configuration" {
  description = "Addon configuration — HCCM, CSI, cert-manager, self-maintenance, Longhorn"
  type = object({
    hcloud_controller = object({
      version    = string
      preinstall = bool
    })
    hcloud_csi = object({
      version               = string
      preinstall            = bool
      default_storage_class = bool
      reclaim_policy        = string
    })
    cert_manager = object({
      version                         = string
      preinstall                      = bool
      use_for_preinstalled_components = bool
    })
    self_maintenance = object({
      system_upgrade_controller_version = string
      kured_version                     = string
    })
    longhorn = object({
      version                         = string
      preinstall                      = bool
      replica_count                   = number
      default_storage_class           = bool
      backup_target                   = string
      backup_schedule                 = string
      backup_retain                   = number
      s3_endpoint                     = string
      s3_access_key                   = string
      s3_secret_key                   = string
      guaranteed_instance_manager_cpu = number
      storage_over_provisioning       = number
      storage_minimal_available       = number
      snapshot_max_count              = number
    })
  })
}

variable "harmony" {
  description = "Harmony chart (openedx-k8s-harmony) integration"
  type = object({
    enabled      = bool
    version      = string
    extra_values = list(string)

    # NOTE: Optional knobs for TLS bootstrap (see root variables.tf).
    enable_default_tls_certificate = optional(bool, true)
    default_tls_secret_name        = optional(string, "harmony-default-tls")
  })
}

variable "cluster_domain" {
  description = "Domain for the cluster (used in Harmony values)"
  type        = string
}

variable "letsencrypt_issuer" {
  description = "Email for Let's Encrypt ACME account"
  type        = string
}

variable "cluster_issuer_name" {
  description = "Name of the cert-manager ClusterIssuer"
  type        = string
}

variable "aws_region" {
  description = "AWS region for Route53 DNS-01 solver"
  type        = string
}

variable "aws_access_key" {
  description = "AWS access key for Route53 credentials secret"
  type        = string
  sensitive   = true
}

variable "aws_secret_key" {
  description = "AWS secret key for Route53 credentials secret"
  type        = string
  sensitive   = true
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID for ClusterIssuer solver config"
  type        = string
}

variable "enable_nginx_modsecurity_waf" {
  description = "Enable ModSecurity WAF on RKE2 built-in ingress controller"
  type        = bool
}

variable "nginx_ingress_proxy_body_size" {
  description = "Default max request body size for nginx ingress controller"
  type        = string
}

variable "enable_auto_os_updates" {
  description = "Enable automatic OS updates (kured)"
  type        = bool
}

variable "enable_auto_kubernetes_updates" {
  description = "Enable automatic Kubernetes version updates (SUC)"
  type        = bool
}

variable "allow_remote_manifest_downloads" {
  description = "Allow downloading external manifests from GitHub (SUC)"
  type        = bool
}

variable "kubernetes_version" {
  description = "RKE2 version — used as health check trigger"
  type        = string
}

variable "agent_node_count" {
  description = "Number of worker nodes (for Longhorn labels count)"
  type        = number
}

variable "control_plane_count" {
  description = "Number of master nodes (for is_ha_cluster computation)"
  type        = number
}

variable "load_balancer_location" {
  description = "LB location (for Longhorn S3 endpoint auto-detection)"
  type        = string
}
