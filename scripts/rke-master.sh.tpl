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
%{ if ETCD_BACKUP_ENABLED }
# DECISION: etcd backup via RKE2 native config.yaml params (zero dependencies)
# See: https://docs.rke2.io/datastore/backup_restore
etcd-snapshot-schedule-cron: "${ETCD_SNAPSHOT_SCHEDULE}"
etcd-snapshot-retention: ${ETCD_SNAPSHOT_RETENTION}
etcd-snapshot-compress: ${ETCD_SNAPSHOT_COMPRESS}
etcd-s3: true
etcd-s3-endpoint: ${ETCD_S3_ENDPOINT}
etcd-s3-bucket: ${ETCD_S3_BUCKET}
etcd-s3-folder: ${ETCD_S3_FOLDER}
etcd-s3-access-key: ${ETCD_S3_ACCESS_KEY}
etcd-s3-secret-key: ${ETCD_S3_SECRET_KEY}
etcd-s3-region: ${ETCD_S3_REGION}
# DECISION: Force path-style S3 access for Hetzner Object Storage
# Why: Hetzner endpoints use path-style URLs (virtual-hosted style not supported).
#      Default "auto" may attempt virtual-hosted style and fail.
# See: https://docs.hetzner.com/storage/object-storage/overview
etcd-s3-bucket-lookup-type: ${ETCD_S3_BUCKET_LOOKUP_TYPE}
# NOTE: etcd-s3-retention is separate from local etcd-snapshot-retention.
# Available since RKE2 v1.34.0+rke2r1.
# See: https://docs.rke2.io/datastore/backup_restore#s3-retention
etcd-s3-retention: ${ETCD_S3_RETENTION}
%{ endif }
EOF

sudo curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION="${INSTALL_RKE2_VERSION}" sh -
sudo systemctl enable rke2-server.service
sudo systemctl start rke2-server.service
