# ──────────────────────────────────────────────────────────────────────────────
# Minimal RKE2 cluster — smallest viable configuration
#
# DECISION: This example serves dual purpose:
# 1. Documentation: shows minimum required inputs for the module
# 2. Testing: used by tests/examples.tftest.hcl for plan validation
# Why: Having a testable minimal example catches regressions in default values
#      and ensures the module remains usable with just required variables.
# ──────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    # NOTE: Only the hcloud provider is needed at the example level.
    # All other providers (aws, cloudinit, tls, random, local) are
    # declared inside the module and configured via passthrough variables.
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = ">= 1.44.0, < 3.0.0"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token

  # DECISION: No poll_interval or poll_function overrides — use provider defaults.
  # Why: minimal example should demonstrate the simplest working config.
}

locals {
  # NOTE: Example metadata and conventions.
  # Why: This example is used for both docs and unit tests; keeping a small
  #      locals bag makes it easier to extend without rewriting the module call.
  example_identity = {
    name        = "minimal"
    managed_by  = "opentofu"
    intent      = "smallest-viable-cluster"
    cost_target = "as-low-as-possible"
  }

  defaults = {
    control_plane_count = 1
    agent_node_count    = 0
  }
}

module "rke2" {
  source = "../.."

  hcloud_api_token = var.hcloud_token
  cluster_domain   = var.cluster_domain

  # Single master, no workers — cheapest possible cluster
  control_plane_count = local.defaults.control_plane_count
  agent_node_count    = local.defaults.agent_node_count

  # Defaults: no Harmony, no DNS. L4 addons deployed separately via Helmfile.
}

# ──────────────────────────────────────────────────────────────────────────────
# Outputs
# ──────────────────────────────────────────────────────────────────────────────

output "kubeconfig" {
  description = "Kubeconfig for cluster access"
  value       = module.rke2.kube_config
  sensitive   = true
}

output "control_plane_lb_ipv4" {
  description = "Control-plane LB IP"
  value       = module.rke2.control_plane_lb_ipv4
}


