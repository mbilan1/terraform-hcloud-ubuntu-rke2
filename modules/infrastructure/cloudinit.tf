# ──────────────────────────────────────────────────────────────────────────────
# Cloud-init configuration — structured multipart MIME for node bootstrap
#
# DECISION: Use cloudinit_config data source instead of raw shell in user_data.
# Why: HashiCorp best practice — separate static configuration (write_files)
#      from runtime logic (shell script). write_files creates config.yaml with
#      all RKE2 parameters at Terraform plan time; the shell script only handles
#      runtime IP detection + sed replacement + install + start.
# See: https://developer.hashicorp.com/terraform/language/post-apply-operations
#
# DECISION: Cloud-init is inlined in infrastructure module (not separate bootstrap).
# Why: Cloud-init needs random_password.cluster_join_secret and hcloud_load_balancer.control_plane.ipv4
#      which are both created in this module. A separate bootstrap module would
#      create a circular dependency (bootstrap needs LB IP, infrastructure needs user_data).
# ──────────────────────────────────────────────────────────────────────────────

# --- Master (initial bootstrap node) ---

data "cloudinit_config" "initial_control_plane" {
  # NOTE: Hetzner Cloud accepts plaintext user_data (no base64/gzip needed).
  gzip          = false
  base64_encode = false

  # Part 1: Write RKE2 config.yaml via cloud-init write_files directive.
  # DECISION: Static config is written declaratively, not via shell heredoc.
  # Why: Cleaner separation of concerns. Config.yaml content is determined at
  #      plan time; only NODE_IP requires runtime detection.
  part {
    content_type = "text/cloud-config"
    filename     = "rke2-config.yaml"
    content = yamlencode({
      write_files = [
        {
          path        = "/etc/rancher/rke2/config.yaml"
          permissions = "0600"
          content = templatefile("${path.module}/templates/cloudinit/rke2-server-config.yaml.tpl", {
            RKE_TOKEN = random_password.cluster_join_secret.result
            # WORKAROUND: master-0 must always bootstrap on create.
            # Why: We create the control-plane LB in the same apply (needed for tls-san).
            #      OpenTofu may refresh data sources during apply after the LB exists,
            #      which can flip a "LB exists" heuristic to true and wrongly render
            #      master-0 as a join node (config.yaml contains `server:`), causing
            #      a self-referential join via the LB and failures like `Get .../cacerts: EOF`.
            #      Since master-0 has `ignore_changes = [user_data]`, this value is baked
            #      at creation time and does not change on subsequent applies.
            INITIAL_MASTER             = true
            SERVER_ADDRESS             = hcloud_load_balancer.control_plane.ipv4
            RKE2_CNI                   = var.cni_plugin
            ENABLE_SECRETS_ENCRYPTION  = var.enable_secrets_encryption
            DISABLE_INGRESS            = var.harmony_enabled
            ETCD_BACKUP_ENABLED        = var.etcd_backup.enabled
            ETCD_SNAPSHOT_SCHEDULE     = var.etcd_backup.schedule_cron
            ETCD_SNAPSHOT_RETENTION    = var.etcd_backup.retention
            ETCD_SNAPSHOT_COMPRESS     = var.etcd_backup.compress
            ETCD_S3_ENDPOINT           = local.etcd_s3_endpoint
            ETCD_S3_BUCKET             = var.etcd_backup.s3_bucket
            ETCD_S3_FOLDER             = local.etcd_s3_folder
            ETCD_S3_ACCESS_KEY         = var.etcd_backup.s3_access_key
            ETCD_S3_SECRET_KEY         = var.etcd_backup.s3_secret_key
            ETCD_S3_REGION             = var.etcd_backup.s3_region
            ETCD_S3_BUCKET_LOOKUP_TYPE = var.etcd_backup.s3_bucket_lookup_type
            ETCD_S3_RETENTION          = var.etcd_backup.s3_retention
          })
        },
      ]
    })
  }

  # Part 2: Bootstrap shell script — minimal runtime logic only.
  # DECISION: Shell script only handles what requires runtime data.
  # Why: IP detection uses Hetzner metadata API (available only at boot time).
  #      Everything else (config content, install version) is already resolved.
  part {
    content_type = "text/x-shellscript"
    filename     = "rke2-bootstrap.sh"
    content = templatefile("${path.module}/scripts/rke-master.sh.tpl", {
      INSTALL_RKE2_VERSION = var.kubernetes_version
    })
  }
}

# --- Additional masters (join existing cluster) ---

data "cloudinit_config" "additional_master" {
  count = var.control_plane_count > 1 ? var.control_plane_count - 1 : 0

  gzip          = false
  base64_encode = false

  part {
    content_type = "text/cloud-config"
    filename     = "rke2-config.yaml"
    content = yamlencode({
      write_files = [
        {
          path        = "/etc/rancher/rke2/config.yaml"
          permissions = "0600"
          content = templatefile("${path.module}/templates/cloudinit/rke2-server-config.yaml.tpl", {
            RKE_TOKEN                  = random_password.cluster_join_secret.result
            INITIAL_MASTER             = false
            SERVER_ADDRESS             = hcloud_load_balancer.control_plane.ipv4
            RKE2_CNI                   = var.cni_plugin
            ENABLE_SECRETS_ENCRYPTION  = var.enable_secrets_encryption
            DISABLE_INGRESS            = var.harmony_enabled
            ETCD_BACKUP_ENABLED        = var.etcd_backup.enabled
            ETCD_SNAPSHOT_SCHEDULE     = var.etcd_backup.schedule_cron
            ETCD_SNAPSHOT_RETENTION    = var.etcd_backup.retention
            ETCD_SNAPSHOT_COMPRESS     = var.etcd_backup.compress
            ETCD_S3_ENDPOINT           = local.etcd_s3_endpoint
            ETCD_S3_BUCKET             = var.etcd_backup.s3_bucket
            ETCD_S3_FOLDER             = local.etcd_s3_folder
            ETCD_S3_ACCESS_KEY         = var.etcd_backup.s3_access_key
            ETCD_S3_SECRET_KEY         = var.etcd_backup.s3_secret_key
            ETCD_S3_REGION             = var.etcd_backup.s3_region
            ETCD_S3_BUCKET_LOOKUP_TYPE = var.etcd_backup.s3_bucket_lookup_type
            ETCD_S3_RETENTION          = var.etcd_backup.s3_retention
          })
        },
      ]
    })
  }

  part {
    content_type = "text/x-shellscript"
    filename     = "rke2-bootstrap.sh"
    content = templatefile("${path.module}/scripts/rke-master.sh.tpl", {
      INSTALL_RKE2_VERSION = var.kubernetes_version
    })
  }
}

# --- Workers ---

data "cloudinit_config" "agent" {
  count = var.agent_node_count

  gzip          = false
  base64_encode = false

  part {
    content_type = "text/cloud-config"
    filename     = "rke2-config.yaml"
    content = yamlencode({
      write_files = [
        {
          path        = "/etc/rancher/rke2/config.yaml"
          permissions = "0600"
          content = templatefile("${path.module}/templates/cloudinit/rke2-agent-config.yaml.tpl", {
            RKE_TOKEN      = random_password.cluster_join_secret.result
            SERVER_ADDRESS = hcloud_load_balancer.control_plane.ipv4
          })
        },
      ]
    })
  }

  part {
    content_type = "text/x-shellscript"
    filename     = "rke2-bootstrap.sh"
    content = templatefile("${path.module}/scripts/rke-worker.sh.tpl", {
      INSTALL_RKE2_VERSION = var.kubernetes_version
    })
  }
}
