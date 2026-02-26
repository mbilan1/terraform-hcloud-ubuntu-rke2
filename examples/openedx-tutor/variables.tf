# ──────────────────────────────────────────────────────────────────────────────
# Hetzner Cloud credentials
# ──────────────────────────────────────────────────────────────────────────────

variable "hcloud_token" {
  description = "Read/write API token for the Hetzner Cloud project that will host the Kubernetes nodes and load balancers."
  sensitive   = true
  nullable    = false
  type        = string
}

# ──────────────────────────────────────────────────────────────────────────────
# Cluster identity
# ──────────────────────────────────────────────────────────────────────────────

variable "rke2_cluster_name" {
  description = "Short alphanumeric prefix for every Hetzner resource created by this deployment (servers, LBs, network, firewall rules)."
  nullable    = false
  type        = string
  default     = "openedx"

  validation {
    condition     = can(regex("^[a-z0-9]{1,20}$", var.rke2_cluster_name))
    error_message = "Cluster name: lowercase alphanumeric only, max 20 characters."
  }
}

variable "cluster_domain" {
  description = "Fully-qualified base domain for the cluster. Must equal '<route53_record_name>.<route53_zone_name>' so that DNS records resolve correctly."
  nullable    = false
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]+[a-z0-9]$", var.cluster_domain))
    error_message = "cluster_domain must be a valid DNS name (lowercase, dots, hyphens)."
  }

  validation {
    condition     = var.cluster_domain == "${var.route53_record_name}.${var.route53_zone_name}"
    error_message = "cluster_domain must equal route53_record_name + '.' + route53_zone_name."
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# AWS credentials and Route53 zone
# ──────────────────────────────────────────────────────────────────────────────

variable "aws_access_key" {
  description = "IAM access key for Route53 DNS record management and cert-manager ACME DNS-01 challenges."
  sensitive   = true
  nullable    = false
  type        = string
}

variable "aws_secret_key" {
  description = "IAM secret key (pair of aws_access_key) for Route53 and cert-manager operations."
  sensitive   = true
  nullable    = false
  type        = string
}

variable "aws_region" {
  description = "AWS region identifier passed to the Route53 provider (Route53 is global, but the provider still expects a region)."
  nullable    = false
  type        = string
  default     = "eu-central-1"
}

variable "route53_zone_name" {
  description = "Name of the Route53 hosted zone that owns the cluster domain (e.g. 'example.com'). Must NOT include a trailing dot."
  nullable    = false
  type        = string

  validation {
    condition     = !endswith(var.route53_zone_name, ".")
    error_message = "route53_zone_name must not end with a trailing dot."
  }
}

variable "route53_record_name" {
  description = "Subdomain label prepended to the zone to form the cluster domain (e.g. 'campus' → campus.example.com)."
  nullable    = false
  type        = string

  validation {
    condition     = length(var.route53_record_name) >= 1 && length(var.route53_record_name) <= 63
    error_message = "route53_record_name must be 1–63 characters (DNS label limit)."
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Backup (etcd snapshots + Longhorn volumes → Hetzner Object Storage)
# ──────────────────────────────────────────────────────────────────────────────

variable "enable_backups" {
  description = "Activate scheduled etcd snapshots and Longhorn volume backups to an S3-compatible object store."
  nullable    = false
  type        = bool
  default     = false
}

variable "backup_s3_bucket" {
  description = "S3 bucket name provisioned in Hetzner Object Storage (or any S3-compatible endpoint) for cluster backups."
  nullable    = false
  type        = string
  default     = ""
}

variable "backup_s3_access_key" {
  description = "S3 access key for authenticating to the backup bucket."
  sensitive   = true
  nullable    = false
  type        = string
  default     = ""
}

variable "backup_s3_secret_key" {
  description = "S3 secret key for authenticating to the backup bucket."
  sensitive   = true
  nullable    = false
  type        = string
  default     = ""
}
