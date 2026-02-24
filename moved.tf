# ──────────────────────────────────────────────────────────────────────────────
# State migration — moved blocks for module split
#
# DECISION: Use moved blocks instead of `tofu state mv` for safer migration.
# Why: HashiCorp best practice — moved blocks are declarative, reviewable,
#      and automatically applied during `tofu apply`. Manual state surgery
#      (state mv) is error-prone and not auditable in code review.
# See: https://developer.hashicorp.com/terraform/language/modules/develop/refactoring
#
# NOTE: Data sources (data.*) do NOT need moved blocks — they are re-computed
# on every plan and have no persistent state to migrate.
#
# NOTE: check {} blocks do NOT need moved blocks — they have no state.
#
# After successful migration: keep these blocks for at least one release cycle
# to handle consumers who haven't applied yet. Remove in the NEXT major version.
# ──────────────────────────────────────────────────────────────────────────────

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  Infrastructure module (modules/infrastructure/) — 28 blocks               ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

# --- Random resources ---

# Step 1: root → module (old name)
moved {
  from = random_string.master_node_suffix
  to   = module.infrastructure.random_string.control_plane_id
}

# Step 2: module (old name) → module (new resource type)
# DECISION: Transition from random_string to random_id for node suffixes.
# Why: random_id produces URL-safe identifiers with higher entropy per character.
moved {
  from = module.infrastructure.random_string.control_plane_id
  to   = module.infrastructure.random_id.control_plane_suffix
}

moved {
  from = random_password.rke2_token
  to   = module.infrastructure.random_password.cluster_join_secret
}

# Step 1: root → module (old name)
moved {
  from = random_string.worker_node_suffix
  to   = module.infrastructure.random_string.agent_id
}

# Step 2: module (old name) → module (new resource type)
moved {
  from = module.infrastructure.random_string.agent_id
  to   = module.infrastructure.random_id.agent_suffix
}

# --- SSH ---

moved {
  from = tls_private_key.machines
  to   = module.infrastructure.tls_private_key.ssh_identity
}

moved {
  from = hcloud_ssh_key.main
  to   = module.infrastructure.hcloud_ssh_key.cluster
}

moved {
  from = local_sensitive_file.ssh_private_key
  to   = module.infrastructure.local_sensitive_file.ssh_private_key
}

# --- Network ---

moved {
  from = hcloud_network.main
  to   = module.infrastructure.hcloud_network.cluster
}

moved {
  from = hcloud_network_subnet.main
  to   = module.infrastructure.hcloud_network_subnet.nodes
}

# --- Firewall ---

moved {
  from = hcloud_firewall.cluster
  to   = module.infrastructure.hcloud_firewall.cluster
}

# --- Servers ---

moved {
  from = hcloud_server.master
  to   = module.infrastructure.hcloud_server.initial_control_plane
}

moved {
  from = hcloud_server.additional_masters
  to   = module.infrastructure.hcloud_server.control_plane
}

moved {
  from = hcloud_server.worker
  to   = module.infrastructure.hcloud_server.agent
}

# --- Load Balancer: Control Plane ---

moved {
  from = hcloud_load_balancer.control_plane
  to   = module.infrastructure.hcloud_load_balancer.control_plane
}

moved {
  from = hcloud_load_balancer_network.control_plane_network
  to   = module.infrastructure.hcloud_load_balancer_network.control_plane_network
}

moved {
  from = hcloud_load_balancer_target.cp_initial_master
  to   = module.infrastructure.hcloud_load_balancer_target.cp_initial_master
}

moved {
  from = hcloud_load_balancer_target.cp_additional_masters
  to   = module.infrastructure.hcloud_load_balancer_target.cp_additional_masters
}

moved {
  from = hcloud_load_balancer_service.cp_k8s_api
  to   = module.infrastructure.hcloud_load_balancer_service.cp_k8s_api
}

moved {
  from = hcloud_load_balancer_service.cp_register
  to   = module.infrastructure.hcloud_load_balancer_service.cp_register
}

moved {
  from = hcloud_load_balancer_service.cp_ssh
  to   = module.infrastructure.hcloud_load_balancer_service.cp_ssh
}

# --- Load Balancer: Ingress ---

moved {
  from = hcloud_load_balancer.ingress
  to   = module.infrastructure.hcloud_load_balancer.ingress
}

moved {
  from = hcloud_load_balancer_network.ingress_network
  to   = module.infrastructure.hcloud_load_balancer_network.ingress_network
}

moved {
  from = hcloud_load_balancer_target.ingress_workers
  to   = module.infrastructure.hcloud_load_balancer_target.ingress_workers
}

moved {
  from = hcloud_load_balancer_service.ingress_http
  to   = module.infrastructure.hcloud_load_balancer_service.ingress_http
}

moved {
  from = hcloud_load_balancer_service.ingress_https
  to   = module.infrastructure.hcloud_load_balancer_service.ingress_https
}

moved {
  from = hcloud_load_balancer_service.ingress_custom
  to   = module.infrastructure.hcloud_load_balancer_service.ingress_custom
}

# --- DNS ---

moved {
  from = aws_route53_record.wildcard
  to   = module.infrastructure.aws_route53_record.wildcard
}

# --- Readiness / lifecycle ---

moved {
  from = terraform_data.wait_for_api
  to   = module.infrastructure.terraform_data.wait_for_api
}

moved {
  from = terraform_data.wait_for_cluster_ready
  to   = module.infrastructure.terraform_data.wait_for_cluster_ready
}

moved {
  from = terraform_data.pre_upgrade_snapshot
  to   = module.infrastructure.terraform_data.pre_upgrade_snapshot
}

moved {
  from = terraform_data.cluster_health_check
  to   = module.infrastructure.terraform_data.cluster_health_check
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  Addons module (modules/addons/) — 24 blocks                              ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

# --- HCCM (count → for_each migration) ---

# Step 1: root → module (count address)
moved {
  from = kubernetes_secret_v1.hcloud_ccm
  to   = module.addons.kubernetes_secret_v1.cloud_controller_token[0]
}

# Step 2: count[0] → for_each["key"]
moved {
  from = module.addons.kubernetes_secret_v1.cloud_controller_token[0]
  to   = module.addons.kubernetes_secret_v1.cloud_controller_token["hcloud-ccm"]
}

moved {
  from = helm_release.hccm
  to   = module.addons.helm_release.cloud_controller[0]
}

moved {
  from = module.addons.helm_release.cloud_controller[0]
  to   = module.addons.helm_release.cloud_controller["hccm"]
}

# --- CSI (count → for_each migration) ---

moved {
  from = kubernetes_secret_v1.hcloud_csi
  to   = module.addons.kubernetes_secret_v1.hcloud_csi[0]
}

moved {
  from = module.addons.kubernetes_secret_v1.hcloud_csi[0]
  to   = module.addons.kubernetes_secret_v1.hcloud_csi["hcloud-csi"]
}

moved {
  from = helm_release.hcloud_csi
  to   = module.addons.helm_release.hcloud_csi[0]
}

moved {
  from = module.addons.helm_release.hcloud_csi[0]
  to   = module.addons.helm_release.hcloud_csi["hcloud-csi"]
}

# --- cert-manager (count → for_each migration) ---

moved {
  from = kubernetes_namespace_v1.cert_manager
  to   = module.addons.kubernetes_namespace_v1.certificate_manager[0]
}

moved {
  from = module.addons.kubernetes_namespace_v1.certificate_manager[0]
  to   = module.addons.kubernetes_namespace_v1.certificate_manager["cert-manager"]
}

# NOTE: dns_solver_credentials stays count-based (sensitive var.aws_access_key in condition)
moved {
  from = kubernetes_secret_v1.cert_manager
  to   = module.addons.kubernetes_secret_v1.dns_solver_credentials
}

moved {
  from = helm_release.cert_manager
  to   = module.addons.helm_release.certificate_manager[0]
}

moved {
  from = module.addons.helm_release.certificate_manager[0]
  to   = module.addons.helm_release.certificate_manager["cert-manager"]
}

moved {
  from = kubectl_manifest.cert_manager_issuer
  to   = module.addons.kubectl_manifest.letsencrypt_cluster_issuer[0]
}

moved {
  from = module.addons.kubectl_manifest.letsencrypt_cluster_issuer[0]
  to   = module.addons.kubectl_manifest.letsencrypt_cluster_issuer["issuer"]
}

# --- Longhorn ---

moved {
  from = kubernetes_namespace_v1.longhorn
  to   = module.addons.kubernetes_namespace_v1.longhorn
}

moved {
  from = kubernetes_secret_v1.longhorn_s3
  to   = module.addons.kubernetes_secret_v1.longhorn_s3
}

moved {
  from = kubectl_manifest.longhorn_iscsi_installer
  to   = module.addons.kubectl_manifest.longhorn_iscsi_installer
}

moved {
  from = kubernetes_labels.longhorn_worker
  to   = module.addons.kubernetes_labels.longhorn_worker
}

moved {
  from = helm_release.longhorn
  to   = module.addons.helm_release.longhorn
}

moved {
  from = terraform_data.longhorn_health_check
  to   = module.addons.terraform_data.longhorn_health_check
}

moved {
  from = terraform_data.longhorn_pre_upgrade_snapshot
  to   = module.addons.terraform_data.longhorn_pre_upgrade_snapshot
}

# --- Ingress controller ---

moved {
  from = kubectl_manifest.ingress_configuration
  to   = module.addons.kubectl_manifest.ingress_configuration
}

# --- Harmony (count → for_each migration) ---

moved {
  from = kubernetes_namespace_v1.harmony
  to   = module.addons.kubernetes_namespace_v1.harmony[0]
}

moved {
  from = module.addons.kubernetes_namespace_v1.harmony[0]
  to   = module.addons.kubernetes_namespace_v1.harmony["harmony"]
}

moved {
  from = helm_release.harmony
  to   = module.addons.helm_release.harmony[0]
}

moved {
  from = module.addons.helm_release.harmony[0]
  to   = module.addons.helm_release.harmony["harmony"]
}

# --- Self-maintenance (count → for_each migration) ---

moved {
  from = kubernetes_namespace_v1.kured
  to   = module.addons.kubernetes_namespace_v1.reboot_daemon[0]
}

moved {
  from = module.addons.kubernetes_namespace_v1.reboot_daemon[0]
  to   = module.addons.kubernetes_namespace_v1.reboot_daemon["kured"]
}

moved {
  from = helm_release.kured
  to   = module.addons.helm_release.reboot_daemon[0]
}

moved {
  from = module.addons.helm_release.reboot_daemon[0]
  to   = module.addons.helm_release.reboot_daemon["kured"]
}

# NOTE: SUC CRDs, namespace, and controller use sha1(content) as for_each keys.
# These are dynamic hashes computed at plan time — moved blocks cannot target them.
# The old count-based resources will be destroyed and recreated with hash keys.
# This is safe because CRDs and namespace manifests are declarative/idempotent.
# TODO: Remove these stale moved blocks in the next major version once all
#       deployments have applied at least once with the new for_each keys.

moved {
  from = kubectl_manifest.system_upgrade_controller_server_plan
  to   = module.addons.kubectl_manifest.suc_server_upgrade_plan[0]
}

moved {
  from = module.addons.kubectl_manifest.suc_server_upgrade_plan[0]
  to   = module.addons.kubectl_manifest.suc_server_upgrade_plan["server-plan"]
}

moved {
  from = kubectl_manifest.system_upgrade_controller_agent_plan
  to   = module.addons.kubectl_manifest.suc_agent_upgrade_plan[0]
}

moved {
  from = module.addons.kubectl_manifest.suc_agent_upgrade_plan[0]
  to   = module.addons.kubectl_manifest.suc_agent_upgrade_plan["agent-plan"]
}
