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
  description = "Enable etcd + Velero backup to Hetzner Object Storage."
}

variable "backup_s3_bucket" {
  type        = string
  default     = ""
  description = "S3 bucket name for etcd and Velero backups (Hetzner Object Storage)."
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
