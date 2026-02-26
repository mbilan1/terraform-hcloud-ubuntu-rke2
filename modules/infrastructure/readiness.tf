# ──────────────────────────────────────────────────────────────────────────────
# Cluster readiness checks, kubeconfig retrieval, and operational lifecycle
#
# DECISION: Readiness checks live in infrastructure module (not addons).
# Why: They validate that the CLUSTER is functional before any addon deployment.
#      Addons depend on cluster_ready anchor output from this module.
#      SSH provisioners connect to infrastructure (master[0]), not to K8s API.
# ──────────────────────────────────────────────────────────────────────────────

# --- Wait for RKE2 API server on master[0] ---

resource "terraform_data" "wait_for_api" {
  depends_on = [
    hcloud_load_balancer_service.cp_k8s_api,
    hcloud_server.initial_control_plane,
  ]

  provisioner "remote-exec" {
    # WORKAROUND: cloud-init status --wait is called with explicit error handling.
    # Why: Redirecting stderr to /dev/null swallowed the exit code when cloud-init
    #      reports status=error, causing the loop below to spin forever waiting for
    #      a kubectl binary that was never installed (rke2-server had already failed).
    #      The bare `until` loop had no timeout, so apply hung indefinitely.
    # Fix: (1) fail loudly on cloud-init error and dump the log, (2) time-bound
    #      the kubectl wait loop with a hard 600s ceiling, (3) dump diagnostics
    #      (cloud-init log + rke2-server journal tail) on any failure path so the
    #      operator sees the root cause without SSHing in manually.
    inline = [
      "echo 'Starting RKE2 readiness check...'",
      <<-EOT
      set -eu
      # NOTE: pipefail is bash-only; remote-exec runs /bin/sh.
      KC=/var/lib/rancher/rke2/bin/kubectl
      KUBECONFIG=/etc/rancher/rke2/rke2.yaml
      TIMEOUT=600
      ELAPSED=0

      _dump_diagnostics() {
        echo "=== cloud-init status ==="
        cloud-init status --long 2>/dev/null || true
        echo "=== last 40 lines of cloud-init output ==="
        tail -40 /var/log/cloud-init-output.log 2>/dev/null || true
        echo "=== rke2-server last 30 journal lines ==="
        journalctl -u rke2-server.service --no-pager -n 30 2>/dev/null || true
      }

      echo "Waiting for cloud-init to finish..."
      if ! cloud-init status --wait 2>/dev/null; then
        echo "ERROR: cloud-init finished with a non-zero status."
        _dump_diagnostics
        exit 1
      fi

      CI_STATUS=$(cloud-init status 2>/dev/null | awk '{print $2}')
      if [ "$CI_STATUS" = "error" ]; then
        echo "ERROR: cloud-init status=error — RKE2 bootstrap script likely failed."
        _dump_diagnostics
        exit 1
      fi
      echo "cloud-init finished (status=$CI_STATUS)."

      echo "Waiting for RKE2 API server (timeout $${TIMEOUT}s)..."
      until $KC --kubeconfig "$KUBECONFIG" get nodes >/dev/null 2>&1; do
        if [ $ELAPSED -ge $TIMEOUT ]; then
          echo "ERROR: RKE2 API server did not become reachable within $${TIMEOUT}s."
          _dump_diagnostics
          exit 1
        fi
        echo "Waiting for API server... $${ELAPSED}s / $${TIMEOUT}s"
        sleep 10
        ELAPSED=$((ELAPSED + 10))
      done
      echo "RKE2 API server is ready!"
      EOT
    ]

    connection {
      type        = "ssh"
      host        = hcloud_server.initial_control_plane[0].ipv4_address
      user        = "root"
      private_key = tls_private_key.ssh_identity.private_key_openssh
      timeout     = "15m"
    }
  }
}

# --- Wait for ALL nodes to become Ready ---

resource "terraform_data" "wait_for_cluster_ready" {
  depends_on = [
    terraform_data.wait_for_api,
    hcloud_server.initial_control_plane,
    hcloud_server.control_plane,
    hcloud_server.agent,
  ]

  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for all ${var.control_plane_count + var.agent_node_count} node(s) to become Ready...'",
      <<-EOT
      EXPECTED=${var.control_plane_count + var.agent_node_count}
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
      host        = hcloud_server.initial_control_plane[0].ipv4_address
      user        = "root"
      private_key = tls_private_key.ssh_identity.private_key_openssh
      timeout     = "15m"
    }
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Pre-upgrade etcd snapshot
#
# DECISION: Inline remote-exec instead of external .sh.tpl file
# Why: Cloud-init and scripts/ are immutable infrastructure — they should only
#      contain bootstrap logic. Operational scripts belong inline in their
#      Terraform resource, keeping the scripts/ directory minimal.
# See: docs/PLAN-operational-readiness.md — Step 5
# ──────────────────────────────────────────────────────────────────────────────
resource "terraform_data" "pre_upgrade_snapshot" {
  # NOTE: Only created when etcd backup is configured.
  # Without etcd backup, there is no S3 target for the snapshot.
  count = var.etcd_backup.enabled ? 1 : 0

  depends_on = [terraform_data.wait_for_cluster_ready]

  # Re-run when RKE2 version changes
  triggers_replace = [var.kubernetes_version]

  connection {
    type        = "ssh"
    host        = hcloud_server.initial_control_plane[0].ipv4_address
    user        = "root"
    private_key = tls_private_key.ssh_identity.private_key_openssh
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "export KUBECONFIG=/etc/rancher/rke2/rke2.yaml",
      "export PATH=\"$PATH:/var/lib/rancher/rke2/bin\"",
      "SNAPSHOT_NAME=\"pre-upgrade-$(date +%Y%m%d-%H%M%S)\"",
      "echo \"Creating pre-upgrade etcd snapshot: $SNAPSHOT_NAME\"",
      "rke2 etcd-snapshot save --name \"$SNAPSHOT_NAME\"",
      "echo \"$SNAPSHOT_NAME\" > /var/lib/rancher/rke2/server/last-pre-upgrade-snapshot",
      "echo 'DONE: etcd snapshot saved'",
    ]
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Cluster health check — runs after cluster operations (upgrade, restore)
#
# DECISION: Inline remote-exec instead of external .sh.tpl file
# Why: Keeps scripts/ immutable (cloud-init only). Health check logic is
#      tightly coupled to the Terraform resource lifecycle — inline is clearer.
#      HTTP URL checks use a bash loop over a Terraform-joined string.
# See: docs/PLAN-operational-readiness.md — Step 4
# ──────────────────────────────────────────────────────────────────────────────
resource "terraform_data" "cluster_health_check" {
  depends_on = [terraform_data.wait_for_cluster_ready]

  # Re-run when RKE2 version changes (triggers health check after upgrade)
  triggers_replace = [var.kubernetes_version]

  connection {
    type        = "ssh"
    host        = hcloud_server.initial_control_plane[0].ipv4_address
    user        = "root"
    private_key = tls_private_key.ssh_identity.private_key_openssh
    timeout     = "15m"
  }

  provisioner "remote-exec" {
    inline = [
      "export KUBECONFIG=/etc/rancher/rke2/rke2.yaml",
      # WORKAROUND: Set an explicit PATH for remote-exec scripts.
      # Why: In some environments the non-interactive SSH session can have an
      #      unexpectedly minimal PATH, causing basic utilities (grep/date/wc)
      #      to be "not found" and failing health checks spuriously.
      "export PATH=\"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/var/lib/rancher/rke2/bin\"",
      "EXPECTED=${var.control_plane_count + var.agent_node_count}",
      "TIMEOUT=900",
      "ELAPSED=0",
      "echo '=== Cluster Health Check ==='",
      # Check 1: API server /readyz
      "until [ \"$(kubectl get --raw='/readyz' 2>/dev/null)\" = 'ok' ]; do [ $ELAPSED -ge $TIMEOUT ] && echo 'FAIL: API /readyz' && exit 1; sleep 5; ELAPSED=$((ELAPSED + 5)); done",
      "echo 'PASS: API /readyz'",
      # Check 2: All nodes Ready
      "while true; do READY=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 == \"Ready\" {c++} END {print c+0}'); [ \"$READY\" -ge \"$EXPECTED\" ] && break; [ $ELAPSED -ge $TIMEOUT ] && echo \"FAIL: Nodes $READY/$EXPECTED\" && exit 1; sleep 10; ELAPSED=$((ELAPSED + 10)); done",
      "echo \"PASS: Nodes Ready ($EXPECTED/$EXPECTED)\"",
      # Check 3: System pods Running (tolerant wait)
      # WORKAROUND: CoreDNS is sometimes not Running immediately after all nodes
      # report Ready on fresh clusters (transient scheduling / image pull).
      # Why: Failing the whole apply on that transient makes first-time UX brittle.
      "ELAPSED=0",
      "for P in coredns kube-proxy cloud-controller-manager; do while true; do C=$(kubectl get pods -A --no-headers 2>/dev/null | grep \"$P\" | grep -c Running || true); [ \"$C\" -gt 0 ] && echo \"PASS: $P ($C running)\" && break; [ $ELAPSED -ge $TIMEOUT ] && echo \"FAIL: No running $P pods\" && exit 1; echo \"Waiting for $P pods to become Running... $ELAPSED/$TIMEOUT\"; sleep 10; ELAPSED=$((ELAPSED + 10)); done; done",
      # Check 4: HTTP endpoints (optional, Terraform-injected)
      "URLS='${join(" ", var.health_check_urls)}'",
      "for URL in $URLS; do CODE=$(curl -sk -o /dev/null -w '%%{http_code}' \"$URL\" 2>/dev/null || echo '000'); if [ \"$CODE\" -ge 200 ] && [ \"$CODE\" -lt 400 ]; then echo \"PASS: HTTP $URL ($CODE)\"; else echo \"FAIL: HTTP $URL ($CODE)\" && exit 1; fi; done",
      "echo '=== All health checks passed ==='",
    ]
  }
}
