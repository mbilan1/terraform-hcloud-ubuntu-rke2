# ──────────────────────────────────────────────────────────────────────────────
# Provider declarations — root-level configuration passed to child modules
#
# DECISION: All providers configured exclusively in the root module.
# Why: OpenTofu/Terraform best practice — child modules (modules/infrastructure)
#      declare required_providers for version constraints only, but never
#      contain provider {} blocks. The root module owns configuration.
# NOTE: This module is NOT a root deployment. No backend is configured here.
#      Deployments live in examples/ or external repositories.
#
# DECISION: L4 providers (kubernetes, helm, kubectl, http) removed.
# Why: L4 (addon Helm charts, K8s resources) is managed outside Terraform
#      via Helmfile/ArgoCD/Flux. Terraform owns only L3 (infrastructure).
#      All addons — including HCCM — deploy via Helmfile after bootstrap.
# See: docs/ARCHITECTURE.md — Layer Separation
# ──────────────────────────────────────────────────────────────────────────────

terraform {
  # DECISION: Bump to >= 1.7.0 for `removed {}` block support.
  # Why: Addon resources (helm_release, kubernetes_*, kubectl_manifest) were
  #      moved to external management (Helmfile/ArgoCD). `removed {}` blocks
  #      tell OpenTofu to drop them from state without destroying the live
  #      K8s objects. Requires OpenTofu >= 1.7.0.
  # See: https://opentofu.org/docs/language/resources/syntax/#removing-resources
  required_version = ">= 1.7.0"

  required_providers {
    # ── Hetzner Cloud platform ──────────────────────────────────────────────
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = ">= 1.44.0, < 2.0.0"
    }

    # ── AWS (Route53 DNS only) ──────────────────────────────────────────────
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"
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
  }
}

locals {
  # WORKAROUND: Keep AWS provider auth logic centralized and readable.
  # Why: The AWS provider eagerly validates credentials during init. We support
  #      Route53-optional clusters, so we must supply dummy values when DNS is
  #      unused — but we also want the conditional logic to be easy to audit.
  aws_dns_is_enabled = var.route53_zone_id != ""

  aws_access_key_effective = (!local.aws_dns_is_enabled && var.aws_access_key == "") ? "unused" : var.aws_access_key
  aws_secret_key_effective = (!local.aws_dns_is_enabled && var.aws_secret_key == "") ? "unused" : var.aws_secret_key

  # DECISION: Keep provider locals strictly behavior-driving.
  # Why: Removing unused metadata placeholders avoids dead config that can
  #      confuse reviews and static analysis without adding runtime value.
  aws_skip_validation = !local.aws_dns_is_enabled
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
  access_key = local.aws_access_key_effective
  secret_key = local.aws_secret_key_effective

  skip_credentials_validation = local.aws_skip_validation
  skip_requesting_account_id  = local.aws_skip_validation
  skip_metadata_api_check     = local.aws_skip_validation
}