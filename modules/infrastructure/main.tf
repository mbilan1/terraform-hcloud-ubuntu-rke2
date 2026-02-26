# ──────────────────────────────────────────────────────────────────────────────
# Infrastructure module — Server resources (L3)
#
# DECISION: All server resources live in the infrastructure module.
# Why: Servers are cloud infrastructure, not Kubernetes addons. They consume
#      user_data from the bootstrap module (L2) and feed into the addons (L4).
# ──────────────────────────────────────────────────────────────────────────────

# DECISION: Use random_id (base64url) instead of random_string for node suffixes.
# Why: random_id produces URL-safe identifiers with higher entropy per character
#      (base64url = 6 bits/char vs alphanumeric = ~5.9 bits/char) and avoids the
#      special=false/upper=false boilerplate. Shorter suffix for the same entropy.
resource "random_id" "control_plane_suffix" {
  count       = var.control_plane_count
  byte_length = 4
}

resource "random_password" "cluster_join_secret" {
  length  = 48
  special = false
}

# DECISION: Generate a one-time bootstrap token for OpenBao initial access.
# Why: After Helmfile deploys OpenBao in dev mode, the operator needs a
#      pre-shared token to log in and retrieve the kubeconfig. This token
#      is used as devRootToken — the operator MUST revoke it after setting
#      up proper auth (OIDC, LDAP, UserPass).
# SECURITY: Token is 32 chars alphanumeric (no special chars for CLI safety).
#           Marked sensitive — never appears in plan output or logs.
#           Stored only in Terraform state (protect with encrypted backend).
resource "random_password" "openbao_bootstrap_token" {
  count   = var.openbao_enabled ? 1 : 0
  length  = 32
  special = false
}

locals {
  # NOTE: Root module already resolves master/worker location fallback
  # (empty → node_locations) before passing to this module. No fallback needed here.
  # See: main.tf locals.effective_master_locations / effective_worker_locations

  # Pre-compute server name prefix to avoid repeating the pattern.
  master_name_prefix = "${var.rke2_cluster_name}-master"
  worker_name_prefix = "${var.rke2_cluster_name}-worker"

  # NOTE: Centralize common labels for all servers.
  # Why: Keeps conventions consistent and avoids repeating the same map
  #      literals across resources.
  common_labels = {
    "cluster-name" = var.rke2_cluster_name
    "managed-by"   = "opentofu"
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  master-0 — Cluster bootstrap node                                         ║
# ║  This node initializes the RKE2 cluster. All other nodes join via LB.      ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

resource "hcloud_server" "initial_control_plane" {
  depends_on = [hcloud_network_subnet.nodes]

  count = 1

  name         = "${local.master_name_prefix}-${lower(random_id.control_plane_suffix[0].hex)}"
  image        = var.master_node_image
  server_type  = var.master_node_server_type
  location     = element(var.master_node_locations, 0)
  firewall_ids = [hcloud_firewall.cluster.id]
  ssh_keys     = [hcloud_ssh_key.cluster.id]

  # SECURITY: user_data contains RKE2 join token (random_password.cluster_join_secret).
  # Hetzner provider does NOT mark user_data as sensitive, so without sensitive()
  # the entire cloud-init config (with plaintext token) would appear in plan/apply
  # output and CI logs. Wrapping with sensitive() forces OpenTofu to redact it.
  # DECISION: Use cloudinit_config data source for structured multipart MIME.
  # Why: HashiCorp best practice — write_files for config, shell for runtime logic.
  # See: cloudinit.tf
  user_data = sensitive(data.cloudinit_config.initial_control_plane.rendered)

  network {
    network_id = hcloud_network.cluster.id
    alias_ips  = []
  }

  # NOTE: merge() keeps shared labels in one place.
  # Why: reduces drift and makes it obvious which labels are per-resource.
  labels = merge(
    local.common_labels,
    {
      "role"      = "control-plane"
      "bootstrap" = "true"
    }
  )

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
      server_type,
      labels,
    ]
    create_before_destroy = true
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  Additional master nodes — join via LB (port 9345)                         ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

resource "hcloud_server" "control_plane" {
  depends_on = [
    hcloud_network_subnet.nodes,
    hcloud_load_balancer_service.cp_register,
  ]

  count = var.control_plane_count > 1 ? var.control_plane_count - 1 : 0

  name         = "${local.master_name_prefix}-${lower(random_id.control_plane_suffix[count.index + 1].hex)}"
  image        = var.master_node_image
  server_type  = var.master_node_server_type
  firewall_ids = [hcloud_firewall.cluster.id]
  ssh_keys     = [hcloud_ssh_key.cluster.id]

  # NOTE: Use modulo to allow shorter location lists than control_plane_count.
  # This keeps behavior predictable (round-robin) while avoiding index errors.
  location = element(var.master_node_locations, (count.index + 1) % length(var.master_node_locations))

  # SECURITY: user_data contains RKE2 join token — see master[0] comment.
  # See: cloudinit.tf for structured cloud-init config.
  user_data = sensitive(data.cloudinit_config.additional_master[count.index].rendered)

  network {
    network_id = hcloud_network.cluster.id
    alias_ips  = []
  }

  labels = merge(
    local.common_labels,
    {
      "role" = "control-plane"
    }
  )

  lifecycle {
    ignore_changes = [
      user_data,
      image,
      server_type,
      labels,
    ]
    create_before_destroy = true
  }
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  Worker (agent) nodes — run application workloads                           ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

resource "random_id" "agent_suffix" {
  count       = var.agent_node_count
  byte_length = 4
}

resource "hcloud_server" "agent" {
  depends_on = [
    hcloud_network_subnet.nodes,
    hcloud_load_balancer_service.cp_register,
  ]

  count = var.agent_node_count

  name         = "${local.worker_name_prefix}-${lower(random_id.agent_suffix[count.index].hex)}"
  image        = var.worker_node_image
  server_type  = var.worker_node_server_type
  firewall_ids = [hcloud_firewall.cluster.id]
  ssh_keys     = [hcloud_ssh_key.cluster.id]

  location = element(var.worker_node_locations, count.index % length(var.worker_node_locations))

  # SECURITY: user_data contains RKE2 join token — see master[0] comment.
  # See: cloudinit.tf for structured cloud-init config.
  user_data = sensitive(data.cloudinit_config.agent[count.index].rendered)

  network {
    network_id = hcloud_network.cluster.id
    alias_ips  = []
  }

  labels = merge(
    local.common_labels,
    {
      "role" = "agent"
    }
  )

  lifecycle {
    ignore_changes = [
      user_data,
      image,
      server_type,
      labels,
    ]
    # WORKAROUND: Do not use create_before_destroy for Hetzner servers with stable names.
    # Why: Hetzner enforces unique server names. Our names are derived from a random
    #      suffix resource that does not automatically rotate on replacement, so
    #      create_before_destroy can fail with "server name is already used".
    #      For controlled rotations, drain/cordon nodes before apply.
    create_before_destroy = false
  }
}
