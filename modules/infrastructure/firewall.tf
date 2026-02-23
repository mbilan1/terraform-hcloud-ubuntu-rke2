resource "hcloud_firewall" "cluster" {
  name = "${var.rke2_cluster_name}-firewall"

  # Allow HTTP
  rule {
    description = "Ingress, external: HTTP web traffic to ingress controller (workers)"
    direction   = "in"
    protocol    = "tcp"
    port        = "80"
    source_ips = [
      "0.0.0.0/0",
      "::/0"
    ]
  }

  # Allow HTTPS
  rule {
    description = "Ingress, external: HTTPS/TLS web traffic to ingress controller (workers)"
    direction   = "in"
    protocol    = "tcp"
    port        = "443"
    source_ips = [
      "0.0.0.0/0",
      "::/0"
    ]
  }

  # Allow SSH — restricted to ssh_allowed_cidrs.
  # Uses dynamic block so the rule is omitted entirely when list is empty,
  # rather than creating a rule with zero source_ips (which Hetzner rejects).
  # Default is open (0.0.0.0/0) because provisioners SSH into master[0] —
  # see variables.tf comment block for full rationale.
  dynamic "rule" {
    for_each = length(var.ssh_allowed_cidrs) > 0 ? [1] : []
    content {
      description = "Ingress, external: SSH remote access (restricted by ssh_allowed_cidrs)"
      direction   = "in"
      protocol    = "tcp"
      port        = "22"
      source_ips  = var.ssh_allowed_cidrs
    }
  }

  # Allow Kubernetes API — restricted to k8s_api_allowed_cidrs.
  # Unlike SSH, this is a static rule because the Kubernetes API must always
  # be reachable (helm/kubernetes providers connect to it during apply).
  rule {
    description = "Ingress, external: Kubernetes API for kubectl and Terraform providers (restricted by k8s_api_allowed_cidrs)"
    direction   = "in"
    protocol    = "tcp"
    port        = "6443"
    source_ips  = var.k8s_api_allowed_cidrs
  }

  # Allow RKE2 supervisor (node registration) — internal network only
  rule {
    description = "Ingress, internal: RKE2 supervisor for node registration and cluster join"
    direction   = "in"
    protocol    = "tcp"
    port        = "9345"
    source_ips = [
      var.hcloud_network_cidr
    ]
  }

  # Allow etcd — internal network only
  rule {
    description = "Ingress, internal: etcd peer and client traffic between masters"
    direction   = "in"
    protocol    = "tcp"
    port        = "2379-2380"
    source_ips = [
      var.hcloud_network_cidr
    ]
  }

  # Allow kubelet API — internal network only
  rule {
    description = "Ingress, internal: kubelet API for pod logs, exec, and metrics"
    direction   = "in"
    protocol    = "tcp"
    port        = "10250"
    source_ips = [
      var.hcloud_network_cidr
    ]
  }

  # Allow NodePort range — internal network only
  rule {
    description = "Ingress, internal: NodePort range for LB health checks and service routing"
    direction   = "in"
    protocol    = "tcp"
    port        = "30000-32767"
    source_ips = [
      var.hcloud_network_cidr
    ]
  }

  # Allow Canal CNI VXLAN overlay — internal network only
  # DECISION: UDP 8472 must be open on the private network interface.
  # Why: Hetzner Cloud Firewall is host-based and applies to ALL interfaces,
  #      including the private network NIC — not just the public interface.
  #      Canal (default RKE2 CNI) uses VXLAN on UDP 8472 to encapsulate
  #      cross-node pod traffic. Without this rule, pods on different nodes
  #      cannot communicate: webhooks time out, services across nodes fail,
  #      inter-pod traffic is silently dropped.
  # See: https://docs.rke2.io/install/requirements#networking
  rule {
    description = "Ingress, internal: Canal CNI VXLAN overlay for cross-node pod networking"
    direction   = "in"
    protocol    = "udp"
    port        = "8472"
    source_ips = [
      var.hcloud_network_cidr
    ]
  }

  # Allow WireGuard (Canal encrypted overlay) — internal network only
  # NOTE: Only used if Canal WireGuard encryption is enabled (not default in RKE2).
  #       Included preemptively to avoid silent breakage if encryption is toggled.
  # See: https://docs.rke2.io/install/requirements#networking
  rule {
    description = "Ingress, internal: Canal WireGuard encrypted overlay (UDP 51820/51821)"
    direction   = "in"
    protocol    = "udp"
    port        = "51820-51821"
    source_ips = [
      var.hcloud_network_cidr
    ]
  }

  # Allow ICMP (ping)
  rule {
    description = "Ingress, external: ICMP ping for diagnostics and LB health probes"
    direction   = "in"
    protocol    = "icmp"
    source_ips = [
      "0.0.0.0/0",
      "::/0"
    ]
  }
}
