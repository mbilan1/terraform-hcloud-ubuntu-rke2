# ──────────────────────────────────────────────────────────────────────────────
# Open edX cluster on Hetzner Cloud with Harmony
#
# This example creates a production-ready RKE2 cluster with all prerequisites
# for deploying Open edX via Tutor + openedx-k8s-harmony.
# ──────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.44"
    }
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

provider "aws" {
  region     = var.aws_region
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
}

# ──────────────────────────────────────────────────────────────────────────────
# RKE2 Cluster
# ──────────────────────────────────────────────────────────────────────────────

module "rke2" {
  source = "../.."

  hcloud_api_token  = var.hcloud_token
  cluster_domain    = var.cluster_domain
  rke2_cluster_name = var.rke2_cluster_name

  # DNS managed separately via Route53 module below
  create_dns_record = false

  control_plane_count     = 3
  agent_node_count        = 3
  master_node_server_type = "cx23"
  worker_node_server_type = "cx33"
  # DECISION: Demonstrate split placement:
  # - masters across 3 EU cities
  # - workers confined to Germany (lower storage RTT for sync-heavy workloads)
  master_node_locations = ["hel1", "nbg1", "fsn1"]
  worker_node_locations = ["nbg1", "fsn1"]

  # Backward-compat fallback (unused when master/worker lists are set).
  node_locations = ["hel1", "nbg1", "fsn1"]

  cni_plugin = "cilium"

  # DECISION: Enable Harmony for ingress-nginx DaemonSet + ingress LB.
  # Why: Open edX requires HTTPS ingress; Harmony provides ingress-nginx
  #      with proper Hetzner LB integration.
  harmony_enabled = true

  # ── Backup configuration ─────────────────────────────────────────────────
  # etcd snapshots to Hetzner Object Storage (same DC as cluster)
  cluster_configuration = {
    etcd_backup = {
      enabled       = var.enable_backups
      s3_bucket     = var.backup_s3_bucket
      s3_access_key = var.backup_s3_access_key
      s3_secret_key = var.backup_s3_secret_key
    }
  }

  # Health check: verify /heartbeat after upgrades
  health_check_urls = var.enable_backups ? ["https://${var.cluster_domain}/heartbeat"] : []

  # Security: restrict in production
  # ssh_allowed_cidrs     = ["YOUR_IP/32"]
  # k8s_api_allowed_cidrs = ["YOUR_IP/32"]
}

# ──────────────────────────────────────────────────────────────────────────────
# Route53 DNS
# ──────────────────────────────────────────────────────────────────────────────

# DECISION: Using Terraform Registry source with exact version pin instead of git+commit hash
# Why: Registry modules with exact version pins are immutable (registry prevents version overwrites).
#      Git URL with commit hash would lose submodule resolution and registry signature verification.
#      CKV_TF_1 is designed for git-sourced modules where tags can be moved.
module "route53" {
  #checkov:skip=CKV_TF_1:Registry module pinned to exact version 6.1.1 — immutable via registry
  source  = "terraform-aws-modules/route53/aws"
  version = "6.1.1"

  create_zone   = false
  name          = "${var.route53_zone_name}."
  private_zone  = false
  force_destroy = false

  records = {
    apex = {
      name    = var.route53_record_name
      type    = "A"
      ttl     = 300
      records = [module.rke2.ingress_lb_ipv4]
    }
    wildcard = {
      name    = "*.${var.route53_record_name}"
      type    = "CNAME"
      ttl     = 300
      records = ["${var.route53_record_name}.${var.route53_zone_name}"]
    }
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Outputs
# ──────────────────────────────────────────────────────────────────────────────

output "kubeconfig" {
  description = "Kubeconfig for cluster access"
  value       = module.rke2.kube_config
  sensitive   = true
}

output "ingress_lb_ipv4" {
  description = "Ingress LB IPv4 — target for DNS A record"
  value       = module.rke2.ingress_lb_ipv4
}

output "lms_url" {
  description = "LMS URL (main Open edX site)"
  value       = "https://${var.cluster_domain}"
}

output "studio_url" {
  description = "Studio URL (CMS)"
  value       = "https://studio.${var.cluster_domain}"
}

output "mfe_url" {
  description = "MFE URL (Micro-Frontends)"
  value       = "https://apps.${var.cluster_domain}"
}
