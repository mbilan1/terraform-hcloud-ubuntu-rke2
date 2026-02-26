# ──────────────────────────────────────────────────────────────────────────────
# Unit Tests: Full-Stack Configuration Patterns
#
# DECISION: Test root module directly with variable sets that match example
#           deployment patterns (e.g. openedx-tutor), instead of using
#           module { source = "./examples/..." } indirection.
# Why: Module indirection requires examples to declare all providers
#      for correct provider source resolution during tofu test. Testing root
#      module directly with equivalent variable sets provides the same coverage
#      without that maintenance burden.
# ──────────────────────────────────────────────────────────────────────────────

# ── Mock all 7 providers (same config as other test files) ──────────────────
mock_provider "hcloud" {
  mock_resource "hcloud_network" {
    defaults = {
      id = "10001"
    }
  }
  mock_resource "hcloud_network_subnet" {
    defaults = {
      id = "10002"
    }
  }
  mock_resource "hcloud_load_balancer" {
    defaults = {
      id   = "10003"
      ipv4 = "1.2.3.4"
    }
  }
  mock_resource "hcloud_server" {
    defaults = {
      id           = "10004"
      ipv4_address = "1.2.3.4"
    }
  }
  mock_resource "hcloud_ssh_key" {
    defaults = {
      id = "10005"
    }
  }
  mock_resource "hcloud_firewall" {
    defaults = {
      id = "10006"
    }
  }
  mock_data "hcloud_load_balancers" {
    defaults = {
      load_balancers = []
    }
  }
}

# NOTE: data "external" — mock not needed, provider auto-mocked.
mock_provider "external" {}

mock_provider "aws" {}
mock_provider "cloudinit" {}
mock_provider "random" {}
mock_provider "tls" {}
mock_provider "local" {}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-E01: Minimal setup — 1 master, 0 workers, all defaults                ║
# ║  Validates module is usable with absolute minimum configuration.           ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "minimal_setup_plans_successfully" {
  command = plan

  variables {
    cluster_domain      = "example.com"
    hcloud_api_token    = "mock-token"
    control_plane_count = 1
    agent_node_count    = 0
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-E02: OpenEdX-Tutor pattern — HA + Harmony + Cilium                    ║
# ║  Mirrors examples/openedx-tutor configuration.                            ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "openedx_tutor_pattern_plans_successfully" {
  command = plan

  variables {
    cluster_domain          = "example.com"
    hcloud_api_token        = "mock-token"
    rke2_cluster_name       = "openedx"
    control_plane_count     = 3
    agent_node_count        = 3
    master_node_server_type = "cx23"
    worker_node_server_type = "cx33"
    node_locations          = ["hel1", "nbg1", "fsn1"]
    cni_plugin              = "cilium"
    harmony_enabled         = true
  }
}
