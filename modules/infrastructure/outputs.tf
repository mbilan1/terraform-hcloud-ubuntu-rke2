# ──────────────────────────────────────────────────────────────────────────────
# Infrastructure module outputs (L3)
#
# DECISION: Infrastructure module delivers a working cluster.
# Why: L3 ensures API readiness, outputs kubeconfig credentials, and provides
#      all values that downstream L4 (addons) needs.
# ──────────────────────────────────────────────────────────────────────────────

# --- Kubeconfig credentials ---

output "cluster_host" {
  description = "The Kubernetes API server endpoint URL"
  value       = "https://${hcloud_load_balancer.control_plane.ipv4}:6443"
}

output "cluster_ca" {
  description = "The cluster CA certificate (PEM-encoded)"
  value       = local.cluster_ca
  sensitive   = true
}

output "client_cert" {
  description = "The client certificate for cluster authentication (PEM-encoded)"
  value       = local.client_cert
  sensitive   = true
}

output "client_key" {
  description = "The client private key for cluster authentication (PEM-encoded)"
  value       = local.client_key
  sensitive   = true
}

output "kube_config" {
  description = "The full kubeconfig file content for cluster access"
  value       = local.kube_config
  sensitive   = true
}

# --- Network ---

output "network_id" {
  description = "The ID of the Hetzner Cloud private network"
  value       = hcloud_network.cluster.id
}

output "network_name" {
  description = "The name of the Hetzner Cloud private network"
  value       = hcloud_network.cluster.name
}

# --- Load Balancers ---

output "control_plane_lb_ipv4" {
  description = "The IPv4 address of the control-plane load balancer"
  value       = hcloud_load_balancer.control_plane.ipv4
}

output "ingress_lb_ipv4" {
  description = "The IPv4 address of the ingress load balancer. Null when harmony is disabled."
  value       = var.harmony_enabled ? hcloud_load_balancer.ingress[0].ipv4 : null
}

# --- Nodes ---

output "master_nodes_ipv4" {
  description = "The public IPv4 addresses of all master nodes"
  value       = concat(hcloud_server.initial_control_plane[*].ipv4_address, hcloud_server.control_plane[*].ipv4_address)
}

output "worker_nodes_ipv4" {
  description = "The public IPv4 addresses of all worker nodes"
  value       = hcloud_server.agent[*].ipv4_address
}

output "worker_node_names" {
  description = "The names of all worker nodes (for kubernetes_labels in addons)"
  value       = hcloud_server.agent[*].name
}

# --- SSH (for provisioners in addons module) ---

output "master_ipv4" {
  description = "IPv4 of master[0] for SSH provisioners"
  value       = hcloud_server.initial_control_plane[0].ipv4_address
}

output "ssh_private_key" {
  description = "The SSH private key for remote-exec provisioners"
  value       = tls_private_key.ssh_identity.private_key_openssh
  sensitive   = true
}

# --- Dependency anchors ---

output "cluster_ready" {
  description = "Dependency anchor — downstream modules should depend on this"
  value       = terraform_data.wait_for_cluster_ready.id
}

# --- Control-plane LB name (used in tests) ---

output "control_plane_lb_name" {
  description = "Name of the control-plane load balancer"
  value       = hcloud_load_balancer.control_plane.name
}

# --- Diagnostic resource counts (for unit testing conditional logic) ---
#
# NOTE: These outputs expose conditional resource counts so that root-level
# tests can verify feature toggles without accessing module internals.
# OpenTofu test assertions can only reference module outputs, not internal
# resources of child modules.
output "_test_counts" {
  description = "Resource counts for unit testing. Not part of the public API."
  value = {
    ingress_lb           = length(hcloud_load_balancer.ingress)
    additional_masters   = length(hcloud_server.control_plane)
    masters              = length(hcloud_server.initial_control_plane)
    workers              = length(hcloud_server.agent)
    cp_ssh_service       = length(hcloud_load_balancer_service.cp_ssh)
    ssh_key_file         = length(local_sensitive_file.ssh_private_key)
    dns_record           = length(aws_route53_record.wildcard)
    ingress_lb_targets   = length(hcloud_load_balancer_target.ingress_workers)
    pre_upgrade_snapshot = length(terraform_data.pre_upgrade_snapshot)
  }
}

# NOTE: Exposes computed booleans (not the raw rule set) so assertions are
# readable and resilient to mock provider edge cases with nested blocks.
output "_test_firewall" {
  description = "Firewall rule presence flags for unit testing. Not part of the public API."
  value = {
    # Canal VXLAN — required for cross-node pod networking (e.g. cert-manager webhook)
    has_udp_8472 = anytrue([
      for r in hcloud_firewall.cluster.rule :
      r.protocol == "udp" && r.port == "8472"
    ])
    # Canal WireGuard — required if encrypted overlay is enabled
    has_udp_51820_51821 = anytrue([
      for r in hcloud_firewall.cluster.rule :
      r.protocol == "udp" && r.port == "51820-51821"
    ])
    # VXLAN must NOT be open to the internet (should be internal CIDR only)
    vxlan_not_public = !anytrue([
      for r in hcloud_firewall.cluster.rule :
      r.protocol == "udp" && r.port == "8472" && contains(r.source_ips, "0.0.0.0/0")
    ])
    # RKE2 supervisor — required for node join
    has_tcp_9345 = anytrue([
      for r in hcloud_firewall.cluster.rule :
      r.protocol == "tcp" && r.port == "9345"
    ])
    # kubelet API — required for logs, exec, health probes
    has_tcp_10250 = anytrue([
      for r in hcloud_firewall.cluster.rule :
      r.protocol == "tcp" && r.port == "10250"
    ])
    # etcd — required for HA control plane
    has_tcp_etcd = anytrue([
      for r in hcloud_firewall.cluster.rule :
      r.protocol == "tcp" && r.port == "2379-2380"
    ])
  }
}
