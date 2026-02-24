# ──────────────────────────────────────────────────────────────────────────────
# Provider declarations — root-level configuration passed to child modules
#
# DECISION: All providers configured exclusively in the root module.
# Why: OpenTofu/Terraform best practice — child modules (modules/infrastructure,
#      modules/addons) declare required_providers for version constraints only,
#      but never contain provider {} blocks. The root module owns configuration.
# NOTE: This module is NOT a root deployment. No backend is configured here.
#      Deployments live in examples/ or external repositories.
# ──────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    # ── Hetzner Cloud platform ──────────────────────────────────────────────
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = ">= 1.44.0, < 2.0.0"
    }

    # ── AWS (Route53 DNS only) ──────────────────────────────────────────────
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0, < 6.0.0"
    }

    # ── Kubernetes resource management ──────────────────────────────────────
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.23.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.11.0"
    }
    # COMPROMISE: Using gavinbunney/kubectl instead of hashicorp/kubernetes for raw manifests
    # Why: kubernetes provider doesn't support applying arbitrary YAML manifests.
    #      alekc/kubectl is a maintained fork with more features (v2.x), but migration
    #      is a breaking change requiring provider source swap + state surgery.
    # See: docs/ARCHITECTURE.md — Provider Constraints
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.19.0, < 2.0.0"
    }

    # ── Server bootstrap and provisioning ───────────────────────────────────
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = ">= 2.3.0, < 3.0.0"
    }
    remote = {
      source  = "tenstad/remote"
      version = ">= 0.2.0, < 1.0.0"
    }

    # ── Cryptography, randomness, local filesystem ──────────────────────────
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0.0, < 5.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.0, < 4.0.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.4.0, < 3.0.0"
    }

    # ── HTTP data fetching (System Upgrade Controller manifests) ────────────
    http = {
      source  = "hashicorp/http"
      version = ">= 3.4.0, < 4.0.0"
    }
  }
}

# ── Hetzner Cloud ────────────────────────────────────────────────────────────

provider "hcloud" {
  token = var.hcloud_api_token
}

# ── AWS (Route53 DNS management) ─────────────────────────────────────────────
# DECISION: Provide dummy credentials when Route53 is unused.
# Why: The AWS provider validates credentials eagerly at init time. Without
#      dummy values, operators who don't use Route53 would need to export
#      AWS_* environment variables or the plan fails before reaching any
#      AWS resource. The skip_* flags disable unnecessary API calls entirely.
provider "aws" {
  region     = var.aws_region
  access_key = var.route53_zone_id == "" && var.aws_access_key == "" ? "unused" : var.aws_access_key
  secret_key = var.route53_zone_id == "" && var.aws_secret_key == "" ? "unused" : var.aws_secret_key

  skip_credentials_validation = var.route53_zone_id == ""
  skip_requesting_account_id  = var.route53_zone_id == ""
  skip_metadata_api_check     = var.route53_zone_id == ""
}

# ── Kubernetes ecosystem (credentials from infrastructure module output) ─────
#
# DECISION: All three K8s-facing providers consume kubeconfig credentials
# produced by module.infrastructure after cluster bootstrap completes.
# Why: Ensures addons deploy to the correct cluster with valid mTLS. The
#      infrastructure module outputs are empty strings during initial plan
#      (before any apply) which providers handle gracefully.

provider "kubernetes" {
  host = module.infrastructure.cluster_host

  cluster_ca_certificate = module.infrastructure.cluster_ca
  client_certificate     = module.infrastructure.client_cert
  client_key             = module.infrastructure.client_key
}

provider "helm" {
  kubernetes = {
    host = module.infrastructure.cluster_host

    cluster_ca_certificate = module.infrastructure.cluster_ca
    client_certificate     = module.infrastructure.client_cert
    client_key             = module.infrastructure.client_key
  }
}

provider "kubectl" {
  host             = module.infrastructure.cluster_host
  load_config_file = false

  cluster_ca_certificate = module.infrastructure.cluster_ca
  client_certificate     = module.infrastructure.client_cert
  client_key             = module.infrastructure.client_key
}