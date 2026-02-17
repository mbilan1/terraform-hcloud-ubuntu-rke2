#!/bin/bash
# RKE2 server (master) bootstrap script.
#
# DECISION: Minimal bootstrap — only runtime logic that cannot be in cloud-config.
# Why: HashiCorp best practice — config.yaml is pre-written by cloud-init write_files
#      (via cloudinit_config data source). This script only handles runtime data:
#      detect private IP from Hetzner metadata API, patch config.yaml placeholder,
#      install RKE2, and start the service.
# See: https://developer.hashicorp.com/terraform/language/post-apply-operations
set -euo pipefail

# Wait for Hetzner private network IP to become available via metadata API
NODE_IP=""
while [[ "$NODE_IP" = "" ]]; do
  NODE_IP=$(curl -s --connect-timeout 5 http://169.254.169.254/hetzner/v1/metadata/private-networks | grep "ip:" | cut -f 3 -d" " || true)
  sleep 1
done

# Patch config.yaml with the runtime-detected private IP
# NOTE: __NODE_IP__ placeholder is written by cloud-init write_files part
sed -i "s/__NODE_IP__/$NODE_IP/g" /etc/rancher/rke2/config.yaml

# Install and start RKE2 server
# SECURITY: Download install script to disk before execution
# Why: Piping remote scripts directly to sh (curl | sh) creates supply-chain risk.
#      If get.rke2.io is compromised or a MITM attack occurs, malicious code
#      would execute as root with no opportunity for inspection or verification.
#      Downloading to disk first allows the script to be audited (in future
#      iterations or air-gapped deployments) and reduces the attack surface.
# See: https://docs.rke2.io/install/methods
# NOTE: The install script itself performs SHA256 checksum verification
#       of RKE2 tarballs against checksums from GitHub releases, protecting
#       against tampered binaries (but not against a compromised install script).
# COMPROMISE: Full supply-chain security requires either:
#             - Manual artifact download + GPG signature verification, OR
#             - Using distribution packages with GPG verification, OR
#             - Air-gapped installation with pre-verified artifacts
#             These approaches require more complex cloud-init logic or custom
#             images. Current approach balances security improvement with
#             deployment simplicity for this initial implementation.
# TODO: Consider implementing full GPG verification in future versions.

# Download install script
curl -sfL https://get.rke2.io -o /tmp/rke2-install.sh
chmod +x /tmp/rke2-install.sh

# Run install script (it will download RKE2 and verify checksums internally)
INSTALL_RKE2_VERSION="${INSTALL_RKE2_VERSION}" /tmp/rke2-install.sh

systemctl enable rke2-server.service
systemctl start rke2-server.service

# Clean up install script
# NOTE: With set -euo pipefail, this line only executes if all previous
#       commands succeeded (including systemctl). If any command fails, the
#       script exits immediately and /tmp/rke2-install.sh is preserved.
rm -f /tmp/rke2-install.sh
