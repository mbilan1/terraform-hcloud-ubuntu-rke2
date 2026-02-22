# ──────────────────────────────────────────────────────────────────────────────
# Required variables
# ──────────────────────────────────────────────────────────────────────────────

variable "hcloud_token" {
  type        = string
  sensitive   = true
  description = "Hetzner Cloud API token."
}

variable "domain" {
  type        = string
  description = "Domain for Open edX (e.g. 'openedx.example.com'). Must match DNS records."

  validation {
    condition     = length(var.domain) > 0
    error_message = "Domain must not be empty."
  }

  # DECISION: Enforce domain == Route53 record (examples only)
  # Why: A mismatch (domain != route53_record_name + zone) leads to confusing outcomes:
  #      - DNS points one name to the ingress LB
  #      - cert-manager issues certificates for a different name
  #      - browsers see the wrong certificate or default 404 backend
  #      This validation makes the example fail fast with a clear message.
  validation {
    condition     = var.domain == "${var.route53_record_name}.${var.route53_zone_name}"
    error_message = "domain must equal '${var.route53_record_name}.${var.route53_zone_name}' to match the Route53 records created by this example."
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# AWS / Route53
# ──────────────────────────────────────────────────────────────────────────────

variable "aws_access_key" {
  type        = string
  sensitive   = true
  description = "AWS access key for Route53 DNS management."
}

variable "aws_secret_key" {
  type        = string
  sensitive   = true
  description = "AWS secret key for Route53 DNS management."
}

variable "aws_region" {
  type        = string
  default     = "eu-central-1"
  description = "AWS region for Route53 provider."
}

variable "route53_zone_name" {
  type        = string
  description = "Route53 hosted zone name (e.g. 'example.com')."
}

variable "route53_record_name" {
  type        = string
  description = "DNS record name within the zone (e.g. 'openedx' → openedx.example.com)."
}

# ──────────────────────────────────────────────────────────────────────────────
# Optional
# ──────────────────────────────────────────────────────────────────────────────

variable "cluster_name" {
  type        = string
  default     = "openedx"
  description = "Short name for the cluster, used as prefix for all Hetzner resources."
}

variable "letsencrypt_email" {
  type        = string
  default     = ""
  description = "Email for Let's Encrypt certificate notifications."
}

# ──────────────────────────────────────────────────────────────────────────────
# Backup
# ──────────────────────────────────────────────────────────────────────────────

variable "enable_backups" {
  type        = bool
  default     = false
  description = "Enable etcd + Longhorn backup to Hetzner Object Storage."
}

variable "backup_s3_bucket" {
  type        = string
  default     = ""
  description = "S3 bucket name for etcd and Longhorn backups (Hetzner Object Storage)."
}

variable "backup_s3_access_key" {
  type        = string
  default     = ""
  sensitive   = true
  description = "S3 access key for backup bucket."
}

variable "backup_s3_secret_key" {
  type        = string
  default     = ""
  sensitive   = true
  description = "S3 secret key for backup bucket."
}
