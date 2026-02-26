# ──────────────────────────────────────────────────────────────────────────────
# Private network — L2 isolation per cluster
# ──────────────────────────────────────────────────────────────────────────────

locals {
  # NOTE: Compute network resource name once to keep it consistent across
  # the network and subnet resources. Format: "{cluster}-private-network".
  private_network_name = "${var.rke2_cluster_name}-private-network"
}

resource "hcloud_network" "cluster" {
  name     = local.private_network_name
  ip_range = var.hcloud_network_cidr

  labels = {
    "managed-by"   = "opentofu"
    "cluster-name" = var.rke2_cluster_name
    "purpose"      = "node-connectivity"
  }

  delete_protection = false
}

# DECISION: Single subnet spanning the full network range.
# Why: RKE2 nodes need L2 adjacency for VXLAN overlay (Canal/Calico).
#      Multiple subnets would require explicit routing and complicate CNI.
#      The subnet CIDR is intentionally separate from the network CIDR to
#      leave room for future subnets (e.g., bastion, monitoring) without
#      re-IPing the entire network.
resource "hcloud_network_subnet" "nodes" {
  network_id   = hcloud_network.cluster.id
  type         = "cloud"
  network_zone = var.hcloud_network_zone
  ip_range     = var.subnet_address

  depends_on = [hcloud_network.cluster]
}
