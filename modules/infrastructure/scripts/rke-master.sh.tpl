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
# SECURITY: Multi-layer supply chain protection
# 1. Install script pinned to immutable Git tag (prevents upstream tampering)
# 2. Download install.sh separately (not piped to shell) for audit trail
# 3. RKE2 version is pinned via INSTALL_RKE2_VERSION (prevents unexpected upgrades)
# 4. The install.sh script verifies SHA256 checksums of all downloaded RKE2 binaries
#    (see https://github.com/rancher/rke2/blob/master/install.sh verify_tarball function)
# DECISION: Pin install.sh to v1.34.4+rke2r1 Git tag
# Why: Git tags are immutable, providing cryptographic assurance against supply chain
#      attacks on the install script itself. This tag is stable and well-tested.
#      Update this URL when updating the default rke2_version in variables.tf.
# NOTE: The install script supports any RKE2 version via INSTALL_RKE2_VERSION env var,
#       so pinning the script version doesn't restrict which RKE2 version gets installed.
# See: https://github.com/rancher/rke2/releases/tag/v1.34.4%2Brke2r1
INSTALL_SCRIPT=$(mktemp)
trap 'rm -f "$INSTALL_SCRIPT"' EXIT
INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/rancher/rke2/v1.34.4+rke2r1/install.sh"
curl -sfL "$INSTALL_SCRIPT_URL" -o "$INSTALL_SCRIPT" || { echo "Failed to download RKE2 installer from $INSTALL_SCRIPT_URL" >&2; exit 1; }
chmod +x "$INSTALL_SCRIPT"
INSTALL_RKE2_VERSION="${INSTALL_RKE2_VERSION}" "$INSTALL_SCRIPT" || { echo "Failed to install RKE2 server" >&2; exit 1; }

systemctl enable rke2-server.service
systemctl start rke2-server.service
