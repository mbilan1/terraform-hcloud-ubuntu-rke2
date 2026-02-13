resource "random_string" "master_node_suffix" {
  count   = var.master_node_count
  length  = 6
  special = false
}

resource "null_resource" "wait_for_cluster_ready" {
  depends_on = [
    null_resource.wait_for_api,
    hcloud_server.master,
    hcloud_server.additional_masters,
    hcloud_server.worker,
  ]

  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for all ${var.master_node_count + var.worker_node_count} node(s) to become Ready...'",
      <<-EOT
      EXPECTED=${var.master_node_count + var.worker_node_count}
      export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
      KC=/var/lib/rancher/rke2/bin/kubectl

      # Phase 1: Wait for API server readiness via /readyz endpoint (timeout 300s)
      ELAPSED=0
      until [ "$($KC get --raw='/readyz' 2>/dev/null)" = "ok" ]; do
        if [ $ELAPSED -ge 300 ]; then
          echo "ERROR: API server did not become ready within 300s"
          exit 1
        fi
        echo "Waiting for API server /readyz... $${ELAPSED}s"
        sleep 5
        ELAPSED=$((ELAPSED + 5))
      done
      echo "API server is ready."

      # Phase 2: Wait for all nodes to register and report Ready (timeout 600s)
      ELAPSED=0
      while true; do
        READY=$($KC get nodes --no-headers 2>/dev/null | awk '$2 == "Ready" {c++} END {print c+0}')
        echo "Nodes Ready: $READY / $EXPECTED ($${ELAPSED}s)"
        if [ "$READY" -ge "$EXPECTED" ]; then
          echo "All $EXPECTED node(s) are Ready!"
          break
        fi
        if [ $ELAPSED -ge 600 ]; then
          echo "ERROR: Not all nodes became Ready within 600s"
          $KC get nodes --no-headers 2>/dev/null || true
          exit 1
        fi
        sleep 15
        ELAPSED=$((ELAPSED + 15))
      done
      EOT
    ]

    connection {
      type        = "ssh"
      host        = hcloud_server.master[0].ipv4_address
      user        = "root"
      private_key = tls_private_key.machines.private_key_openssh
      timeout     = "15m"
    }
  }
}

resource "random_password" "rke2_token" {
  length  = 48
  special = false
}

resource "hcloud_server" "master" {
  depends_on = [
    hcloud_network_subnet.main
  ]
  count        = 1
  name         = "${var.cluster_name}-master-${lower(random_string.master_node_suffix[0].result)}"
  server_type  = var.master_node_server_type
  image        = var.master_node_image
  location     = element(var.node_locations, 0)
  ssh_keys     = [hcloud_ssh_key.main.id]
  firewall_ids = [hcloud_firewall.cluster.id]
  user_data = templatefile("${path.module}/scripts/rke-master.sh.tpl", {
    EXPOSE_METRICS            = var.cluster_configuration.monitoring_stack.preinstall || var.expose_kubernetes_metrics
    RKE_TOKEN                 = random_password.rke2_token.result
    INITIAL_MASTER            = !local.cluster_loadbalancer_running
    SERVER_ADDRESS            = hcloud_load_balancer.control_plane.ipv4
    INSTALL_RKE2_VERSION      = var.rke2_version
    RKE2_CNI                  = var.rke2_cni
    OIDC_URL                  = var.expose_oidc_issuer_url ? "https://${local.oidc_issuer_subdomain}" : ""
    DISABLE_INGRESS           = var.harmony.enabled
    ENABLE_SECRETS_ENCRYPTION = var.enable_secrets_encryption
  })

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
  location     = element(var.node_locations, count.index + 1)
  ssh_keys     = [hcloud_ssh_key.main.id]
  firewall_ids = [hcloud_firewall.cluster.id]
  user_data = templatefile("${path.module}/scripts/rke-master.sh.tpl", {
    EXPOSE_METRICS            = var.cluster_configuration.monitoring_stack.preinstall || var.expose_kubernetes_metrics
    RKE_TOKEN                 = random_password.rke2_token.result
    INITIAL_MASTER            = false
    SERVER_ADDRESS            = hcloud_load_balancer.control_plane.ipv4
    INSTALL_RKE2_VERSION      = var.rke2_version
    RKE2_CNI                  = var.rke2_cni
    OIDC_URL                  = var.expose_oidc_issuer_url ? "https://${local.oidc_issuer_subdomain}" : ""
    DISABLE_INGRESS           = var.harmony.enabled
    ENABLE_SECRETS_ENCRYPTION = var.enable_secrets_encryption
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
    hcloud_load_balancer_service.cp_register,
  ]
  count        = var.worker_node_count
  name         = "${var.cluster_name}-worker-${lower(random_string.worker_node_suffix[count.index].result)}"
  server_type  = var.worker_node_server_type
  image        = var.worker_node_image
  location     = element(var.node_locations, count.index)
  ssh_keys     = [hcloud_ssh_key.main.id]
  firewall_ids = [hcloud_firewall.cluster.id]
  user_data = templatefile("${path.module}/scripts/rke-worker.sh.tpl", {
    RKE_TOKEN            = random_password.rke2_token.result
    SERVER_ADDRESS       = hcloud_load_balancer.control_plane.ipv4
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
