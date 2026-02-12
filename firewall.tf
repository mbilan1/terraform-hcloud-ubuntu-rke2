resource "hcloud_firewall" "cluster" {
  name = "${var.cluster_name}-firewall"

  # Allow HTTP
  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "80"
    source_ips = [
      "0.0.0.0/0",
      "::/0"
    ]
  }

  # Allow HTTPS
  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "443"
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
      direction  = "in"
      protocol   = "tcp"
      port       = "22"
      source_ips = var.ssh_allowed_cidrs
    }
  }

  # Allow Kubernetes API — restricted to k8s_api_allowed_cidrs.
  # Unlike SSH, this is a static rule because the Kubernetes API must always
  # be reachable (helm/kubernetes providers connect to it during apply).
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6443"
    source_ips = var.k8s_api_allowed_cidrs
  }

  # Allow RKE2 supervisor (node registration) — internal network only
  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "9345"
    source_ips = [
      var.network_address
    ]
  }

  # Allow etcd — internal network only
  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "2379-2380"
    source_ips = [
      var.network_address
    ]
  }

  # Allow kubelet API — internal network only
  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "10250"
    source_ips = [
      var.network_address
    ]
  }

  # Allow NodePort range — internal network only
  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "30000-32767"
    source_ips = [
      var.network_address
    ]
  }

  # Allow ICMP (ping)
  rule {
    direction = "in"
    protocol  = "icmp"
    source_ips = [
      "0.0.0.0/0",
      "::/0"
    ]
  }
}

