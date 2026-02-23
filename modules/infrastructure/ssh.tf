# ──────────────────────────────────────────────────────────────────────────────
# SSH identity — Per-cluster ephemeral key pair for node access
#
# DECISION: Generate a unique key pair per deployment rather than importing
#   a pre-existing operator key.
# Why: Ephemeral per-cluster keys keep the blast radius contained — compromising
#   one cluster's key doesn't affect others. Also enables clean `tofu destroy`
#   without orphaned authorized_keys on other infrastructure.
# ──────────────────────────────────────────────────────────────────────────────

# DECISION: ED25519 over RSA-4096 for SSH key generation.
# Why: ED25519 provides equivalent security with shorter keys (~68 chars vs ~750),
#      faster operations, and resistance to several side-channel attacks.
#      Hetzner Cloud API and Ubuntu 24.04 fully support ED25519 (OpenSSH 9.x).
#      RSA-4096 was the previous choice for broader rescue-system compatibility,
#      but all current Hetzner rescue images ship OpenSSH >= 8.0 with ED25519 support.
# See: https://docs.hetzner.cloud/#ssh-keys
resource "tls_private_key" "ssh_identity" {
  algorithm = "ED25519"
}

# Upload the public half to Hetzner Cloud so cloud-init injects it into
# ~/.ssh/authorized_keys on every provisioned server automatically.
resource "hcloud_ssh_key" "cluster" {
  name       = "${var.rke2_cluster_name}-deploy-key"
  public_key = tls_private_key.ssh_identity.public_key_openssh

  labels = {
    "managed-by"   = "opentofu"
    "cluster-name" = var.rke2_cluster_name
  }
}

# SECURITY: local_sensitive_file prevents the private key from appearing
# in plan/apply output or CI logs. Only written when explicitly requested
# (save_ssh_key_locally = true) for manual debugging via `ssh -i`.
resource "local_sensitive_file" "ssh_private_key" {
  count = var.save_ssh_key_locally ? 1 : 0

  content         = tls_private_key.ssh_identity.private_key_openssh
  filename        = "${var.rke2_cluster_name}-deploy-key"
  file_permission = "0600"
}
