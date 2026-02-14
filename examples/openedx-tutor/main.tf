# ──────────────────────────────────────────────────────────────────────────────
# Open edX cluster on Hetzner Cloud with Harmony
#
# This example creates a production-ready RKE2 cluster with all prerequisites
# for deploying Open edX via Tutor + openedx-k8s-harmony.
# ──────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.5.0"

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

  hetzner_token = var.hcloud_token
  domain        = var.domain
  cluster_name  = var.cluster_name

  # DNS managed separately via Route53 module below
  create_dns_record = false

  master_node_count       = 3
  worker_node_count       = 3
  master_node_server_type = "cx23"
  worker_node_server_type = "cx33"
  node_locations          = ["hel1", "nbg1", "fsn1"]

  rke2_cni = "cilium"

  cluster_configuration = {
    hcloud_controller = { preinstall = true }
    hcloud_csi        = { preinstall = true, default_storage_class = true }
    cert_manager      = { preinstall = true }
  }

  harmony = {
    enabled = true
  }

  letsencrypt_issuer = var.letsencrypt_email

  # Security: restrict in production
  # ssh_allowed_cidrs     = ["YOUR_IP/32"]
  # k8s_api_allowed_cidrs = ["YOUR_IP/32"]
}

# ──────────────────────────────────────────────────────────────────────────────
# Route53 DNS
# ──────────────────────────────────────────────────────────────────────────────

module "route53" {
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
  value       = "https://${var.domain}"
}

output "studio_url" {
  description = "Studio URL (CMS)"
  value       = "https://studio.${var.domain}"
}

output "mfe_url" {
  description = "MFE URL (Micro-Frontends)"
  value       = "https://apps.${var.domain}"
}
