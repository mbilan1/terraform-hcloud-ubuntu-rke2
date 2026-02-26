# ──────────────────────────────────────────────────────────────────────────────
# Infrastructure module — external data sources
#
# DECISION: Keep data sources in dedicated data.tf.
# Why: This keeps readiness/provisioning resources focused on lifecycle logic
#      while centralizing external reads (remote files, http, etc.) in one place.
# ──────────────────────────────────────────────────────────────────────────────

# --- Fetch kubeconfig from master[0] ---
# DECISION: Replace tenstad/remote provider with data "external" + bash script.
# Why: Eliminates the only third-party non-HashiCorp provider. The bash script
#      performs a simple idempotent `ssh cat` — same SSH mechanism already used
#      by readiness provisioners (remote-exec), so no new attack surface.
# See: modules/infrastructure/scripts/fetch_kubeconfig.sh
#
# Security model:
#   - SSH private key is base64-encoded for JSON transport, never written
#     to a persistent file (script uses mktemp + trap for cleanup)
#   - Kubeconfig content is base64-encoded in transit, decoded in locals.tf
#   - Terraform marks all outputs as sensitive — never appears in plan/logs
#   - No new credentials or providers required

data "external" "kubeconfig" {
  depends_on = [
    # DECISION: Fetch kubeconfig only after full node readiness.
    # Why: Addon consumers use this artifact immediately; fetching it only
    #      after cluster-wide readiness reduces first-apply race conditions
    #      where API is up but node registration is still incomplete.
    terraform_data.wait_for_cluster_ready
  ]

  program = ["${path.module}/scripts/fetch_kubeconfig.sh"]

  query = {
    host = hcloud_server.initial_control_plane[0].ipv4_address
    user = "root"
    # DECISION: Base64-encode the SSH private key for JSON transport.
    # Why: SSH keys contain newlines that break JSON string encoding.
    #      Base64 is lossless and the script decodes it before use.
    # SECURITY: The key is Terraform-generated (tls_private_key), lives only
    #           in state (already sensitive), and is cleaned up by the script's
    #           trap handler after each invocation.
    private_key = base64encode(tls_private_key.ssh_identity.private_key_openssh)
  }
}
