# RKE2 agent (worker) configuration template.
# Written to /etc/rancher/rke2/config.yaml via cloud-init write_files.
#
# DECISION: Separate config.yaml from bootstrap script via cloudinit_config.
# Why: HashiCorp best practice — use write_files for static config, shell script
#      only for runtime logic (IP detection, install, start). The
#      __RKE2_NODE_PRIVATE_IPV4__
#      placeholder is replaced at boot time by the bootstrap script after
#      detecting the private network IP from kernel network state.
# See: https://developer.hashicorp.com/terraform/language/post-apply-operations
server: https://${SERVER_ADDRESS}:9345
token: ${RKE_TOKEN}
cloud-provider-name: external
node-ip: __RKE2_NODE_PRIVATE_IPV4__
