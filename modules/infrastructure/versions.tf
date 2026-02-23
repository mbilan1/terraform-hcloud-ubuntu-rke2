# ──────────────────────────────────────────────────────────────────────────────
# Infrastructure module — required providers
#
# DECISION: Declare required_providers but do NOT configure them.
# Why: HashiCorp best practice for child modules — providers are configured
#      in the root module and passed via the providers argument.
# See: https://developer.hashicorp.com/terraform/language/modules/develop/providers
# ──────────────────────────────────────────────────────────────────────────────

terraform {
  required_providers {
    # Cloud platform — Hetzner Cloud for compute, network, firewall, LBs
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = ">= 1.44.0, < 2.0.0"
    }

    # DNS — Route53 for wildcard record (conditional, only when create_dns_record = true)
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0, < 6.0.0"
    }

    # Server bootstrap — structured multipart cloud-init for node provisioning
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = ">= 2.3.0, < 3.0.0"
    }

    # Remote file access — kubeconfig retrieval from master-0 via SSH
    remote = {
      source  = "tenstad/remote"
      version = ">= 0.2.0, < 1.0.0"
    }

    # Cryptography — SSH key pair generation (ED25519)
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0.0, < 5.0.0"
    }

    # Randomness — cluster join token and server name suffixes
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.0, < 4.0.0"
    }

    # Local filesystem — optional SSH key export
    local = {
      source  = "hashicorp/local"
      version = ">= 2.4.0, < 3.0.0"
    }
  }
}
