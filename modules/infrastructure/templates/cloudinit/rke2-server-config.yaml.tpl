# RKE2 server (master) configuration template.
# Written to /etc/rancher/rke2/config.yaml via cloud-init write_files.
#
# DECISION: Separate config.yaml from bootstrap script via cloudinit_config.
# Why: HashiCorp best practice — use write_files for static config, shell script
#      only for runtime logic (IP detection, install, start). The
#      __RKE2_NODE_PRIVATE_IPV4__
#      placeholder is replaced at boot time by the bootstrap script after
#      detecting the private network IP using metadata first, then kernel
#      network state as a fallback.
# See: https://developer.hashicorp.com/terraform/language/post-apply-operations
%{ if INITIAL_MASTER ~}
token: ${RKE_TOKEN}
%{ else ~}
server: https://${SERVER_ADDRESS}:9345
token: ${RKE_TOKEN}
%{ endif ~}
tls-san:
  - ${SERVER_ADDRESS}
cloud-provider-name: external
cni: ${RKE2_CNI}
node-ip: __RKE2_NODE_PRIVATE_IPV4__
%{ if ENABLE_SECRETS_ENCRYPTION ~}
secrets-encryption: true
%{ endif ~}
%{ if DISABLE_INGRESS ~}
disable:
  - rke2-ingress-nginx
%{ endif ~}
%{ if ETCD_BACKUP_ENABLED ~}
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
%{ endif ~}
