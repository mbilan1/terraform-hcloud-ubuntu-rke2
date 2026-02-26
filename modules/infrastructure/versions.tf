# ──────────────────────────────────────────────────────────────────────────────
# Infrastructure module — required providers
#
# DECISION: Declare required_providers but do NOT configure them.
# Why: HashiCorp best practice for child modules — providers are configured
#      in the root module and passed via the providers argument.
# See: https://developer.hashicorp.com/terraform/language/modules/develop/providers
# ──────────────────────────────────────────────────────────────────────────────

terraform {
  # NOTE: Keep the same minimum OpenTofu/Terraform version as the root module.
  # Why: This module is not a standalone deployment, but explicit constraints
  #      prevent subtle drift when modules are tested or reused independently.
  required_version = ">= 1.7.0"

  required_providers {
    # NOTE: Exact version pins — must match root providers.tf.
    # See: versions.tf for the centralized version registry.

    # Cloud platform — Hetzner Cloud for compute, network, firewall, LBs
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "= 1.60.1"
    }

    # DNS — Route53 for wildcard record (conditional, only when create_dns_record = true)
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.33.0"
    }

    # Server bootstrap — structured multipart cloud-init for node provisioning
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "= 2.3.7"
    }

    # DECISION: tenstad/remote provider removed, replaced by hashicorp/external.
    # Why: Kubeconfig retrieval now uses data "external" + bash script
    #      (scripts/fetch_kubeconfig.sh). Eliminates the only non-HashiCorp provider.
    # See: data.tf, scripts/fetch_kubeconfig.sh

    # Kubeconfig retrieval — data "external" calls fetch_kubeconfig.sh
    external = {
      source  = "hashicorp/external"
      version = "= 2.3.5"
    }

    # Cryptography — SSH key pair generation (ED25519)
    tls = {
      source  = "hashicorp/tls"
      version = "= 4.2.1"
    }

    # Randomness — cluster join token and server name suffixes
    random = {
      source  = "hashicorp/random"
      version = "= 3.8.1"
    }

    # Local filesystem — optional SSH key export
    local = {
      source  = "hashicorp/local"
      version = "= 2.7.0"
    }
  }
}
