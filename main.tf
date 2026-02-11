resource "random_string" "master_node_suffix" {
  count   = var.master_node_count
  length  = 6
  special = false
}

resource "time_sleep" "wait_30_seconds" {
  depends_on = [null_resource.wait_for_api]

  create_duration = "60s"
}

resource "random_password" "rke2_token" {
  length  = 48
  special = false
}

resource "hcloud_server" "master" {
  depends_on = [
    hcloud_network_subnet.main
  ]
  count       = 1
  name        = "${var.cluster_name}-master-${lower(random_string.master_node_suffix[0].result)}"
  server_type = var.master_node_server_type
  image       = var.master_node_image
  location    = element(var.node_locations, 0)
  ssh_keys    = [hcloud_ssh_key.main.id]
  user_data = templatefile("${path.module}/scripts/rke-master.sh.tpl", {
    EXPOSE_METRICS       = var.cluster_configuration.monitoring_stack.preinstall || var.expose_kubernetes_metrics
    RKE_TOKEN            = random_password.rke2_token.result
    INITIAL_MASTER       = !local.cluster_loadbalancer_running
    SERVER_ADDRESS       = hcloud_load_balancer.management_lb.ipv4
    INSTALL_RKE2_VERSION = var.rke2_version
    RKE2_CNI             = var.rke2_cni
    OIDC_URL             = "https://${local.oidc_issuer_subdomain}"
  })

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

# Additional master nodes — created AFTER LB registration service is ready
# so they can reach master[0] via LB port 9345
resource "hcloud_server" "additional_masters" {
  depends_on = [
    hcloud_network_subnet.main,
    hcloud_load_balancer_service.management_lb_register_service,
  ]
  count       = var.master_node_count > 1 ? var.master_node_count - 1 : 0
  name        = "${var.cluster_name}-master-${lower(random_string.master_node_suffix[count.index + 1].result)}"
  server_type = var.master_node_server_type
  image       = var.master_node_image
  location    = element(var.node_locations, count.index + 1)
  ssh_keys    = [hcloud_ssh_key.main.id]
  user_data = templatefile("${path.module}/scripts/rke-master.sh.tpl", {
    EXPOSE_METRICS       = var.cluster_configuration.monitoring_stack.preinstall || var.expose_kubernetes_metrics
    RKE_TOKEN            = random_password.rke2_token.result
    INITIAL_MASTER       = false
    SERVER_ADDRESS       = hcloud_load_balancer.management_lb.ipv4
    INSTALL_RKE2_VERSION = var.rke2_version
    RKE2_CNI             = var.rke2_cni
    OIDC_URL             = "https://${local.oidc_issuer_subdomain}"
  })

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
    hcloud_load_balancer_service.management_lb_register_service,
  ]
  count       = var.worker_node_count
  name        = "${var.cluster_name}-worker-${lower(random_string.worker_node_suffix[count.index].result)}"
  server_type = var.worker_node_server_type
  image       = var.worker_node_image
  location    = element(var.node_locations, count.index)
  ssh_keys    = [hcloud_ssh_key.main.id]
  user_data = templatefile("${path.module}/scripts/rke-worker.sh.tpl", {
    RKE_TOKEN            = random_password.rke2_token.result
    SERVER_ADDRESS       = hcloud_load_balancer.management_lb.ipv4
    INSTALL_RKE2_VERSION = var.rke2_version
  })

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
