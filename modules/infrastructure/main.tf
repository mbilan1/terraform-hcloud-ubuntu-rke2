# ──────────────────────────────────────────────────────────────────────────────
# Infrastructure module — Server resources (L3)
#
# DECISION: All server resources live in the infrastructure module.
# Why: Servers are cloud infrastructure, not Kubernetes addons. They consume
#      user_data from the bootstrap module (L2) and feed into the addons (L4).
# ──────────────────────────────────────────────────────────────────────────────

resource "random_string" "master_node_suffix" {
  count   = var.master_node_count
  length  = 6
  special = false
}

resource "random_password" "rke2_token" {
  length  = 48
  special = false
}

locals {
  # DECISION: Support separate master/worker placement lists.
  # Why: Masters can be spread across more DCs for control-plane resilience,
  #      while workers can be confined to fewer DCs (e.g., Germany-only) to
  #      minimize cross-DC storage latency for stateful workloads.
  # NOTE: Empty lists fall back to node_locations for backward compatibility.
  effective_master_node_locations = length(var.master_node_locations) > 0 ? var.master_node_locations : var.node_locations
  effective_worker_node_locations = length(var.worker_node_locations) > 0 ? var.worker_node_locations : var.node_locations
}

resource "hcloud_server" "master" {
  depends_on = [
    hcloud_network_subnet.main
  ]
  count        = 1
  name         = "${var.cluster_name}-master-${lower(random_string.master_node_suffix[0].result)}"
  server_type  = var.master_node_server_type
  image        = var.master_node_image
  location     = element(local.effective_master_node_locations, 0)
  ssh_keys     = [hcloud_ssh_key.main.id]
  firewall_ids = [hcloud_firewall.cluster.id]
  # SECURITY: user_data contains RKE2 join token (random_password.rke2_token).
  # Hetzner provider does NOT mark user_data as sensitive, so without sensitive()
  # the entire cloud-init config (with plaintext token) would appear in plan/apply
  # output and CI logs. Wrapping with sensitive() forces OpenTofu to redact it.
  # DECISION: Use cloudinit_config data source for structured multipart MIME.
  # Why: HashiCorp best practice — write_files for config, shell for runtime logic.
  # See: cloudinit.tf
  user_data = sensitive(data.cloudinit_config.master.rendered)

  network {
    network_id = hcloud_network.main.id
    alias_ips  = []
  }

  lifecycle {
    # Compromise note:
    # - A hard prevent_destroy guard on master-0 protects against accidental replacement,
    #   but it also blocks legitimate `tofu destroy` flows for ephemeral/dev environments.
    # - We prioritize predictable full lifecycle management in this module baseline.
    #   For production, use branch protection + review + targeted plans as the primary
    #   control against accidental control-plane replacement.

    ignore_changes = [
      user_data,
      image,
      server_type
    ]
    create_before_destroy = true
  }
}

# Additional master nodes — created AFTER LB registration service is ready
# so they can reach master[0] via LB port 9345
resource "hcloud_server" "additional_masters" {
  depends_on = [
    hcloud_network_subnet.main,
    hcloud_load_balancer_service.cp_register,
  ]
  count        = var.master_node_count > 1 ? var.master_node_count - 1 : 0
  name         = "${var.cluster_name}-master-${lower(random_string.master_node_suffix[count.index + 1].result)}"
  server_type  = var.master_node_server_type
  image        = var.master_node_image
  # NOTE: Use modulo to allow shorter location lists than master_node_count.
  # This keeps behavior predictable (round-robin) while avoiding index errors.
  location     = element(local.effective_master_node_locations, (count.index + 1) % length(local.effective_master_node_locations))
  ssh_keys     = [hcloud_ssh_key.main.id]
  firewall_ids = [hcloud_firewall.cluster.id]
  # SECURITY: user_data contains RKE2 join token — see master[0] comment.
  # See: cloudinit.tf for structured cloud-init config.
  user_data = sensitive(data.cloudinit_config.additional_master[count.index].rendered)

  network {
    network_id = hcloud_network.main.id
    alias_ips  = []
  }

  lifecycle {
    ignore_changes = [
      user_data,
      image,
      server_type
    ]
    create_before_destroy = true
  }
}

resource "random_string" "worker_node_suffix" {
  count   = var.worker_node_count
  length  = 6
  special = false
}

resource "hcloud_server" "worker" {
  depends_on = [
    hcloud_network_subnet.main,
    hcloud_load_balancer_service.cp_register,
  ]
  count        = var.worker_node_count
  name         = "${var.cluster_name}-worker-${lower(random_string.worker_node_suffix[count.index].result)}"
  server_type  = var.worker_node_server_type
  image        = var.worker_node_image
  location     = element(local.effective_worker_node_locations, count.index % length(local.effective_worker_node_locations))
  ssh_keys     = [hcloud_ssh_key.main.id]
  firewall_ids = [hcloud_firewall.cluster.id]
  # SECURITY: user_data contains RKE2 join token — see master[0] comment.
  # See: cloudinit.tf for structured cloud-init config.
  user_data = sensitive(data.cloudinit_config.worker[count.index].rendered)

  network {
    network_id = hcloud_network.main.id
    alias_ips  = []
  }

  lifecycle {
    ignore_changes = [
      user_data,
      image,
      server_type
    ]
    # WORKAROUND: Do not use create_before_destroy for Hetzner servers with stable names.
    # Why: Hetzner enforces unique server names. Our names are derived from a random
    #      suffix resource that does not automatically rotate on replacement, so
    #      create_before_destroy can fail with "server name is already used".
    #      For controlled rotations, drain/cordon nodes before apply.
    create_before_destroy = false
  }
}
