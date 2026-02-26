# ──────────────────────────────────────────────────────────────────────────────
# Provider declarations — root-level configuration passed to child modules
#
# NOTE: Provider version constraints are listed in the VERSION REGISTRY
#       table in versions.tf. They MUST remain as string literals here
#       (OpenTofu limitation — required_providers does not support variables).
#       When updating a constraint, also update the table in versions.tf.
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
    # NOTE: Exact version pin. See versions.tf for the version registry.
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "= 1.60.1"
    }

    # ── AWS (Route53 DNS only) ──────────────────────────────────────────────
    # NOTE: Exact version pin. See versions.tf for the version registry.
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.33.0"
    }

    # ── Server bootstrap and provisioning ───────────────────────────────────
    # NOTE: Exact version pins. See versions.tf for the version registry.
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "= 2.3.7"
    }
    # DECISION: tenstad/remote provider removed, replaced by hashicorp/external.
    # Why: Kubeconfig retrieval now uses data "external" + bash script
    #      (scripts/fetch_kubeconfig.sh). Zero third-party providers needed.
    # See: modules/infrastructure/data.tf, modules/infrastructure/scripts/fetch_kubeconfig.sh

    # ── Kubeconfig retrieval ────────────────────────────────────────────────
    # NOTE: Exact version pin. See versions.tf for the version registry.
    external = {
      source  = "hashicorp/external"
      version = "= 2.3.5"
    }

    # ── Cryptography, randomness, local filesystem ──────────────────────────
    # NOTE: Exact version pins. See versions.tf for the version registry.
    tls = {
      source  = "hashicorp/tls"
      version = "= 4.2.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "= 3.8.1"
    }
    local = {
      source  = "hashicorp/local"
      version = "= 2.7.0"
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