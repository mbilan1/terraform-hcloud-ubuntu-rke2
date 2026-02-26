#!/bin/bash
# RKE2 server (master) bootstrap script.
#
# DECISION: Minimal bootstrap — only runtime logic that cannot be in cloud-config.
# Why: HashiCorp best practice — config.yaml is pre-written by cloud-init write_files
#      (via cloudinit_config data source). This script only handles runtime data:
#      detect private IP (metadata first, kernel fallback), patch config.yaml
#      placeholder,
#      install RKE2, and start the service.
# See: https://developer.hashicorp.com/terraform/language/post-apply-operations
set -euo pipefail

# WORKAROUND: Ensure root SSH login is allowed for Terraform provisioners.
# Why: CIS-hardened images (e.g. UBUNTU24-CIS Level 1) set PermitRootLogin=no,
#      but Terraform provisioners (wait_for_api, kubeconfig fetch) must SSH as
#      root. Hetzner Cloud also provisions servers with root-only SSH access.
#      Setting 'prohibit-password' allows key-based root login only (no password).
# TODO: Remove when a dedicated non-root provisioner user is implemented.
if grep -q '^PermitRootLogin no' /etc/ssh/sshd_config 2>/dev/null; then
  sed -i 's/^PermitRootLogin no$/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
  # WORKAROUND: Ubuntu 24.04 uses ssh.service, not sshd.service.
  # Why: The service was renamed in newer Ubuntu versions. Try both names
  #      to support CIS-hardened and standard images alike.
  # TODO: Remove sshd fallback when Ubuntu 22.04 support is dropped.
  systemctl restart ssh || systemctl restart sshd || true
fi

# DECISION: Resolve node private IP from Hetzner metadata first.
# Why: For Hetzner-specific clusters, metadata is the authoritative source for
#      instance network identity and avoids ambiguity if multiple RFC1918
#      addresses are present on the host.
detect_private_ipv4_metadata() {
  local metadata_ip
  metadata_ip="$(
    curl -sf --connect-timeout 2 --max-time 3 \
      http://169.254.169.254/hetzner/v1/metadata/private-networks 2>/dev/null \
      | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' \
      | awk '/^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)/{print; exit}' \
      || true
  )"
  printf '%s' "$metadata_ip"
}

# WORKAROUND: Fall back to kernel network state if metadata is temporarily
# unavailable early in boot.
# Why: Cloud-init can start before metadata/network services fully settle.
detect_private_ipv4_kernel() {
  ip -o -4 addr show scope global \
    | awk '{print $4}' \
    | cut -d/ -f1 \
    | awk '/^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)/{print; exit}'
}

# WORKAROUND: Retry for a bounded time because private NIC attachment can lag
# significantly behind cloud-init startup on fresh Hetzner boots.
# Why: Hetzner attaches the private NIC asynchronously — observed delays of
#      3+ minutes between cloud-init modules:final and NIC appearance.
#      120s was insufficient; 300s provides safe margin.
NODE_IP=""
NODE_IP_SOURCE=""
ELAPSED=0
TIMEOUT=300
until [[ -n "$NODE_IP" ]]; do
  NODE_IP="$(detect_private_ipv4_metadata || true)"
  NODE_IP_SOURCE="metadata"
  if [[ -z "$NODE_IP" ]]; then
    NODE_IP="$(detect_private_ipv4_kernel || true)"
    NODE_IP_SOURCE="kernel"
  fi
  if [[ -n "$NODE_IP" ]]; then
    break
  fi
  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    echo "ERROR: Could not detect private RFC1918 IPv4 within $${TIMEOUT}s (metadata + kernel fallback)." >&2
    ip -o -4 addr show scope global || true
    exit 1
  fi
  sleep 2
  ELAPSED=$((ELAPSED + 2))
done

# DECISION: Validate detected IP shape before mutating RKE2 config.
# Why: A strict guard prevents propagating malformed/non-private addresses into
#      node-ip, which would later cause harder-to-debug cluster networking issues.
# NOTE: 10.x prefix needs two extra octet slots (10.X.Y.Z = 4 octets total),
#       unlike 192.168.X.Y and 172.[16-31].X.Y which already consume two octets
#       in the prefix group.
if ! [[ "$NODE_IP" =~ ^(10\.[0-9]{1,3}\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  echo "ERROR: Detected node IP is not a valid RFC1918 IPv4 address: '$NODE_IP'" >&2
  ip -o -4 addr show scope global || true
  exit 1
fi
echo "Detected private node IP via $NODE_IP_SOURCE: $NODE_IP"

# DECISION: Validate config target before in-place mutation.
# Why: Failing fast with explicit diagnostics is safer than silently running sed
#      against a missing/unexpected file layout when cloud-init write_files failed.
RKE2_CONFIG_PATH="/etc/rancher/rke2/config.yaml"
if [[ ! -f "$RKE2_CONFIG_PATH" ]]; then
  echo "ERROR: Expected RKE2 config file not found: $RKE2_CONFIG_PATH" >&2
  exit 1
fi

if ! grep -q "__RKE2_NODE_PRIVATE_IPV4__" "$RKE2_CONFIG_PATH"; then
  echo "ERROR: Placeholder __RKE2_NODE_PRIVATE_IPV4__ not found in $RKE2_CONFIG_PATH" >&2
  exit 1
fi

# Patch config.yaml with the runtime-detected private IP
# NOTE: __RKE2_NODE_PRIVATE_IPV4__ placeholder is written by cloud-init write_files part
sed -i "s|__RKE2_NODE_PRIVATE_IPV4__|$NODE_IP|g" "$RKE2_CONFIG_PATH"

# Install RKE2 server binaries — skip if already present from Packer base image.
# DECISION: Check /etc/rke2-image-version stamp written by the Ansible role.
# Why: Packer pre-installs RKE2 at image build time to eliminate the ~2-3 min
#      GitHub download from the cloud-init critical path. If the stamp matches
#      the requested version, the download is skipped entirely. Falls back to
#      normal install on stock ubuntu-24.04 images (no stamp file).
REQUESTED_VERSION="${INSTALL_RKE2_VERSION}"
IMAGE_VERSION=""
if [ -f /etc/rke2-image-version ]; then
  IMAGE_VERSION=$(cat /etc/rke2-image-version | tr -d '[:space:]')
fi

if [ -n "$IMAGE_VERSION" ] && { [ -z "$REQUESTED_VERSION" ] || [ "$IMAGE_VERSION" = "$REQUESTED_VERSION" ]; }; then
  echo "RKE2 $IMAGE_VERSION already installed via Packer image — skipping download."
else
  if [ -n "$IMAGE_VERSION" ] && [ -n "$REQUESTED_VERSION" ] && [ "$IMAGE_VERSION" != "$REQUESTED_VERSION" ]; then
    echo "Version mismatch: image has $IMAGE_VERSION, requested $REQUESTED_VERSION — re-installing."
  else
    echo "No pre-installed RKE2 found — installing $${REQUESTED_VERSION:-latest}."
  fi
  curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION="$REQUESTED_VERSION" sh -
fi

systemctl enable rke2-server.service
systemctl start rke2-server.service
