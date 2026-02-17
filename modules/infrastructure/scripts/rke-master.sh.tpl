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
# 1. Download install.sh separately (not piped to shell) for audit trail
# 2. RKE2 version is pinned via INSTALL_RKE2_VERSION (prevents unexpected upgrades)
# 3. The install.sh script verifies SHA256 checksums of all downloaded RKE2 binaries
#    (see https://github.com/rancher/rke2/blob/master/install.sh verify_tarball function)
# COMPROMISE: install.sh itself is not cryptographically verified
# Why: RKE2/Rancher does not publish checksums or GPG signatures for install.sh.
#      Downloading to a file (vs piping) follows industry best practice and matches
#      Rancher's official Terraform module approach. The script itself verifies all
#      binaries via SHA256 checksums from GitHub releases.
# See: https://github.com/rancher/terraform-null-rke2-install/blob/main/install.sh
# TODO: Consider pinning to a specific commit of install.sh for additional assurance
#       (e.g., https://raw.githubusercontent.com/rancher/rke2/<commit>/install.sh)
INSTALL_SCRIPT=$(mktemp)
curl -sfL https://get.rke2.io -o "$INSTALL_SCRIPT" || { echo "Failed to download RKE2 installer"; exit 1; }
chmod +x "$INSTALL_SCRIPT"
INSTALL_RKE2_VERSION="${INSTALL_RKE2_VERSION}" "$INSTALL_SCRIPT"
rm -f "$INSTALL_SCRIPT"

systemctl enable rke2-server.service
systemctl start rke2-server.service
