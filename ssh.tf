# SECURITY: Using local_sensitive_file instead of local_file to prevent
# the SSH private key content from appearing in plan/apply output.
resource "local_sensitive_file" "ssh_private_key" {
  count           = var.generate_ssh_key_file ? 1 : 0
  content         = tls_private_key.machines.private_key_openssh
  filename        = "rancher-host-key"
  file_permission = "0600"
}

resource "hcloud_ssh_key" "main" {
  name       = "${var.cluster_name}-ssh-key"
  public_key = tls_private_key.machines.public_key_openssh
}

resource "tls_private_key" "machines" {
  algorithm = "RSA"
  rsa_bits  = 4096
}
