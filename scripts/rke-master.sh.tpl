#!/bin/bash
set -euo pipefail

NODE_IP=""

while [[ "$NODE_IP" = "" ]]
do
  NODE_IP=$(curl -s --connect-timeout 5 http://169.254.169.254/hetzner/v1/metadata/private-networks | grep "ip:" | cut -f 3 -d" " || true)
  sleep 1
done

mkdir -p /etc/rancher/rke2
cat <<EOF > /etc/rancher/rke2/config.yaml
%{ if INITIAL_MASTER }
token: ${RKE_TOKEN}
%{ else }
server: https://${SERVER_ADDRESS}:9345
token: ${RKE_TOKEN}
%{ endif }
tls-san:
  - ${SERVER_ADDRESS}
cloud-provider-name: external
cni: ${RKE2_CNI}
node-ip: $NODE_IP
%{ if ENABLE_SECRETS_ENCRYPTION }
secrets-encryption: true
%{ endif }
%{ if DISABLE_INGRESS }
disable:
  - rke2-ingress-nginx
%{ endif }
EOF

sudo curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION="${INSTALL_RKE2_VERSION}" sh -
sudo systemctl enable rke2-server.service
sudo systemctl start rke2-server.service
