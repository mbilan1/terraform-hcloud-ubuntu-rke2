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
  # SECURITY: user_data contains RKE2 join token (random_password.rke2_token).
  # Hetzner provider does NOT mark user_data as sensitive, so without sensitive()
  # the entire cloud-init script (with plaintext token) would appear in plan/apply
  # output and CI logs. Wrapping with sensitive() forces OpenTofu to redact it.
  user_data = sensitive(templatefile("${path.module}/scripts/rke-master.sh.tpl", {
    RKE_TOKEN                  = random_password.rke2_token.result
    INITIAL_MASTER             = !local.cluster_loadbalancer_running
    SERVER_ADDRESS             = hcloud_load_balancer.control_plane.ipv4
    INSTALL_RKE2_VERSION       = var.rke2_version
    RKE2_CNI                   = var.rke2_cni
    DISABLE_INGRESS            = var.harmony.enabled
    ENABLE_SECRETS_ENCRYPTION  = var.enable_secrets_encryption
    ETCD_BACKUP_ENABLED        = var.cluster_configuration.etcd_backup.enabled
    ETCD_SNAPSHOT_SCHEDULE     = var.cluster_configuration.etcd_backup.schedule_cron
    ETCD_SNAPSHOT_RETENTION    = var.cluster_configuration.etcd_backup.retention
    ETCD_SNAPSHOT_COMPRESS     = var.cluster_configuration.etcd_backup.compress
    ETCD_S3_ENDPOINT           = local.etcd_s3_endpoint
    ETCD_S3_BUCKET             = var.cluster_configuration.etcd_backup.s3_bucket
    ETCD_S3_FOLDER             = local.etcd_s3_folder
    ETCD_S3_ACCESS_KEY         = var.cluster_configuration.etcd_backup.s3_access_key
    ETCD_S3_SECRET_KEY         = var.cluster_configuration.etcd_backup.s3_secret_key
    ETCD_S3_REGION             = var.cluster_configuration.etcd_backup.s3_region
    ETCD_S3_BUCKET_LOOKUP_TYPE = var.cluster_configuration.etcd_backup.s3_bucket_lookup_type
    ETCD_S3_RETENTION          = var.cluster_configuration.etcd_backup.s3_retention
  }))

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
  # SECURITY: user_data contains RKE2 join token — see master[0] comment.
  user_data = sensitive(templatefile("${path.module}/scripts/rke-master.sh.tpl", {
    RKE_TOKEN                  = random_password.rke2_token.result
    INITIAL_MASTER             = false
    SERVER_ADDRESS             = hcloud_load_balancer.control_plane.ipv4
    INSTALL_RKE2_VERSION       = var.rke2_version
    RKE2_CNI                   = var.rke2_cni
    DISABLE_INGRESS            = var.harmony.enabled
    ENABLE_SECRETS_ENCRYPTION  = var.enable_secrets_encryption
    ETCD_BACKUP_ENABLED        = var.cluster_configuration.etcd_backup.enabled
    ETCD_SNAPSHOT_SCHEDULE     = var.cluster_configuration.etcd_backup.schedule_cron
    ETCD_SNAPSHOT_RETENTION    = var.cluster_configuration.etcd_backup.retention
    ETCD_SNAPSHOT_COMPRESS     = var.cluster_configuration.etcd_backup.compress
    ETCD_S3_ENDPOINT           = local.etcd_s3_endpoint
    ETCD_S3_BUCKET             = var.cluster_configuration.etcd_backup.s3_bucket
    ETCD_S3_FOLDER             = local.etcd_s3_folder
    ETCD_S3_ACCESS_KEY         = var.cluster_configuration.etcd_backup.s3_access_key
    ETCD_S3_SECRET_KEY         = var.cluster_configuration.etcd_backup.s3_secret_key
    ETCD_S3_REGION             = var.cluster_configuration.etcd_backup.s3_region
    ETCD_S3_BUCKET_LOOKUP_TYPE = var.cluster_configuration.etcd_backup.s3_bucket_lookup_type
    ETCD_S3_RETENTION          = var.cluster_configuration.etcd_backup.s3_retention
  }))

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
  # SECURITY: user_data contains RKE2 join token — see master[0] comment.
  user_data = sensitive(templatefile("${path.module}/scripts/rke-worker.sh.tpl", {
    RKE_TOKEN            = random_password.rke2_token.result
    SERVER_ADDRESS       = hcloud_load_balancer.control_plane.ipv4
    INSTALL_RKE2_VERSION = var.rke2_version
  }))

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

# ──────────────────────────────────────────────────────────────────────────────
# Pre-upgrade etcd snapshot + optional Velero backup
#
# DECISION: Take etcd snapshot before any RKE2 version change
# Why: Provides a rollback point if upgrade breaks the cluster. Combined with
#      Velero backup (if enabled), gives both cluster state and PVC data recovery.
# See: docs/ARCHITECTURE.md — Operations: Backup & Restore
# ──────────────────────────────────────────────────────────────────────────────
resource "null_resource" "pre_upgrade_snapshot" {
  # NOTE: Only created when etcd backup is configured.
  # Without etcd backup, there is no S3 target for the snapshot.
  count = var.cluster_configuration.etcd_backup.enabled ? 1 : 0

  depends_on = [null_resource.wait_for_cluster_ready]

  # Re-run when RKE2 version changes
  triggers = {
    rke2_version = var.rke2_version
  }

  provisioner "remote-exec" {
    inline = [
      <<-EOT
      export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
      SNAPSHOT_NAME="pre-upgrade-$(date +%%Y%%m%%d-%%H%%M%%S)"

      echo "Creating pre-upgrade etcd snapshot: $SNAPSHOT_NAME"
      /var/lib/rancher/rke2/bin/rke2 etcd-snapshot save --name "$SNAPSHOT_NAME"

      # Record snapshot name for rollback reference
      echo "$SNAPSHOT_NAME" > /var/lib/rancher/rke2/server/last-pre-upgrade-snapshot
      echo "Pre-upgrade snapshot saved: $SNAPSHOT_NAME"

      %{if var.velero.enabled}
      echo "Creating pre-upgrade Velero backup: $SNAPSHOT_NAME"
      /var/lib/rancher/rke2/bin/kubectl create -f - <<VELERO_BACKUP
      apiVersion: velero.io/v1
      kind: Backup
      metadata:
        name: $SNAPSHOT_NAME
        namespace: velero
      spec:
        includedNamespaces:
          - "*"
        defaultVolumesToFsBackup: true
        ttl: 720h0m0s
      VELERO_BACKUP

      # Wait for Velero backup to complete (timeout 30 min)
      ELAPSED=0
      while true; do
        PHASE=$(/var/lib/rancher/rke2/bin/kubectl get backup "$SNAPSHOT_NAME" -n velero -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        echo "Velero backup phase: $PHASE ($${ELAPSED}s)"
        [ "$PHASE" = "Completed" ] && break
        [ "$PHASE" = "Failed" ] && echo "WARN: Velero backup failed, continuing with etcd snapshot only" && break
        [ $ELAPSED -ge 1800 ] && echo "WARN: Velero backup timeout, continuing" && break
        sleep 15; ELAPSED=$((ELAPSED + 15))
      done
      %{endif}
      EOT
    ]

    connection {
      type        = "ssh"
      host        = hcloud_server.master[0].ipv4_address
      user        = "root"
      private_key = tls_private_key.machines.private_key_openssh
      timeout     = "30m"
    }
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Cluster health check — runs after cluster operations (upgrade, restore)
#
# DECISION: Unified health check as a Terraform resource with triggers
# Why: Provides automated verification after rke2_version changes. Validates
#      API readiness, node status, system pods, and optional HTTP endpoints.
#      Fails the apply if the cluster is unhealthy after an upgrade.
# See: docs/ARCHITECTURE.md — Operations: Backup & Restore
# ──────────────────────────────────────────────────────────────────────────────
resource "null_resource" "cluster_health_check" {
  depends_on = [null_resource.wait_for_cluster_ready]

  # Re-run when RKE2 version changes (triggers health check after upgrade)
  triggers = {
    rke2_version = var.rke2_version
  }

  provisioner "remote-exec" {
    inline = [
      <<-EOT
      export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
      KC=/var/lib/rancher/rke2/bin/kubectl
      EXPECTED=${var.master_node_count + var.worker_node_count}
      TIMEOUT=600
      ELAPSED=0

      echo "=== Cluster Health Check ==="

      # Check 1: API server /readyz
      until [ "$($KC get --raw='/readyz' 2>/dev/null)" = "ok" ]; do
        [ $ELAPSED -ge $TIMEOUT ] && echo "FAIL: API /readyz" && exit 1
        sleep 5; ELAPSED=$((ELAPSED + 5))
      done
      echo "PASS: API /readyz"

      # Check 2: All nodes Ready
      while true; do
        READY=$($KC get nodes --no-headers 2>/dev/null | awk '$2 == "Ready" {c++} END {print c+0}')
        [ "$READY" -ge "$EXPECTED" ] && break
        [ $ELAPSED -ge $TIMEOUT ] && echo "FAIL: Nodes $READY/$EXPECTED" && exit 1
        sleep 10; ELAPSED=$((ELAPSED + 10))
      done
      echo "PASS: Nodes $READY/$EXPECTED Ready"

      # Check 3: System pods Running (coredns, kube-proxy, cloud-controller-manager)
      for POD_PREFIX in coredns kube-proxy cloud-controller-manager; do
        COUNT=$($KC get pods -A --no-headers 2>/dev/null | grep "$POD_PREFIX" | grep -c "Running" || true)
        if [ "$COUNT" -eq 0 ]; then
          echo "FAIL: No running $POD_PREFIX pods"
          exit 1
        fi
        echo "PASS: $POD_PREFIX ($COUNT running)"
      done

      # Check 4: HTTP endpoints (optional, for OpenEdx /heartbeat)
      %{for URL in var.health_check_urls}
      HTTP_CODE=$(curl -sk -o /dev/null -w '%%{http_code}' '${URL}' 2>/dev/null || echo "000")
      if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 400 ]; then
        echo "PASS: HTTP ${URL} ($HTTP_CODE)"
      else
        echo "FAIL: HTTP ${URL} ($HTTP_CODE)"
        exit 1
      fi
      %{endfor}

      echo "=== All health checks passed ==="
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
