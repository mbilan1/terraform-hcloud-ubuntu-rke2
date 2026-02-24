# ──────────────────────────────────────────────────────────────────────────────
# Unit Tests: Firewall Rules
#
# DECISION: Separate test file for firewall rule coverage.
# Why: Firewall misconfigurations are silent at plan time — missing UDP 8472
#      passes validation but breaks cross-node pod networking at runtime.
#      Explicit assertions catch rule deletions before they reach apply.
#
# Root cause this tests against:
#   Canal CNI uses VXLAN (UDP 8472) to tunnel pod traffic between nodes.
#   Hetzner Cloud Firewall is host-based and applies to ALL interfaces,
#   including the private network NIC — not just eth0 (public). Without
#   UDP 8472 open in the internal CIDR, pods on different nodes cannot
#   communicate: webhooks time out, services across nodes fail silently.
#   Discovered when cert-manager startupapicheck could not reach the webhook
#   pod on a different node (context deadline exceeded).
# See: modules/infrastructure/firewall.tf
# ──────────────────────────────────────────────────────────────────────────────

# ── Mock all providers (same boilerplate as other test files) ────────────────

mock_provider "hcloud" {
  mock_resource "hcloud_network" {
    defaults = { id = "10001" }
  }
  mock_resource "hcloud_network_subnet" {
    defaults = { id = "10002" }
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
    defaults = { id = "10005" }
  }
  mock_resource "hcloud_firewall" {
    defaults = { id = "10006" }
  }
  mock_resource "hcloud_load_balancer_network" {
    defaults = { id = "10007" }
  }
  mock_resource "hcloud_load_balancer_service" {
    defaults = { id = "10008" }
  }
  mock_resource "hcloud_load_balancer_target" {
    defaults = { id = "10009" }
  }
  mock_resource "hcloud_firewall_attachment" {
    defaults = { id = "10010" }
  }
  mock_data "hcloud_load_balancers" {
    defaults = { load_balancers = [] }
  }
}

mock_provider "remote" {
  mock_data "remote_file" {
    defaults = { content = "" }
  }
}

mock_provider "aws" {}
mock_provider "kubectl" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "cloudinit" {}
mock_provider "random" {}
mock_provider "tls" {}
mock_provider "local" {}
mock_provider "http" {}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-FW01: Canal VXLAN UDP 8472 is open on internal network                 ║
# ║                                                                            ║
# ║  Regression: absence of this rule broke cert-manager webhook and any       ║
# ║  cross-node pod communication when nodes are in different locations.       ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "firewall_has_canal_vxlan_udp_8472" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    domain           = "test.example.com"
  }

  assert {
    condition     = module.infrastructure._test_firewall.has_udp_8472
    error_message = "REGRESSION: Firewall is missing UDP 8472 (Canal VXLAN). Without this rule, pods on different nodes cannot communicate — webhooks time out, cross-node services fail. See firewall.tf."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-FW02: Canal VXLAN is NOT exposed to the public internet                ║
# ║                                                                            ║
# ║  VXLAN must only accept from the internal private network CIDR.            ║
# ║  Opening to 0.0.0.0/0 would expose the overlay to external packets.       ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "firewall_vxlan_not_open_to_internet" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    domain           = "test.example.com"
  }

  assert {
    condition     = module.infrastructure._test_firewall.vxlan_not_public
    error_message = "SECURITY: UDP 8472 (Canal VXLAN) must be restricted to the internal network CIDR, not open to 0.0.0.0/0. See firewall.tf."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-FW03: Canal WireGuard encrypted overlay ports present                  ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "firewall_has_canal_wireguard_udp_51820_51821" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    domain           = "test.example.com"
  }

  assert {
    condition     = module.infrastructure._test_firewall.has_udp_51820_51821
    error_message = "Firewall is missing UDP 51820-51821 (Canal WireGuard). Required if encrypted overlay is enabled. See firewall.tf."
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  UT-FW04: Essential internal TCP ports present                             ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
run "firewall_has_essential_internal_tcp_rules" {
  command = plan

  variables {
    cluster_domain   = "example.com"
    hcloud_api_token = "mock-token"
    domain           = "test.example.com"
  }

  assert {
    condition     = module.infrastructure._test_firewall.has_tcp_9345
    error_message = "Firewall is missing TCP 9345 (RKE2 supervisor). Nodes cannot register without this rule."
  }

  assert {
    condition     = module.infrastructure._test_firewall.has_tcp_10250
    error_message = "Firewall is missing TCP 10250 (kubelet API). Pod logs, exec, and health probes will not work."
  }

  assert {
    condition     = module.infrastructure._test_firewall.has_tcp_etcd
    error_message = "Firewall is missing TCP 2379-2380 (etcd). HA control plane requires etcd peer traffic between masters."
  }
}
