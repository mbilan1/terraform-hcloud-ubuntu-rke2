# ──────────────────────────────────────────────────────────────────────────────
# Root module — orchestration shim
#
# DECISION: Root module is a thin shim that wires child modules together.
# Why: HashiCorp "split a module" pattern — root declares variables/providers,
#      child modules contain all resource logic. This gives clear layer boundaries:
#        modules/infrastructure/ (L3) — servers, LBs, network, cloud-init, readiness
#        charts/                 (L4) — Helmfile + per-addon values (GitOps, not Terraform)
# See: https://developer.hashicorp.com/terraform/language/modules/develop/refactoring
#      docs/ARCHITECTURE.md — Module Architecture
# ──────────────────────────────────────────────────────────────────────────────

locals {
  # DECISION: Allow separate master/worker location lists.
  # Why: Operators may want control-plane nodes spread across multiple EU DCs
  #      while keeping workers (and thus stateful workloads) confined to a
  #      subset (e.g., Germany-only) to reduce cross-DC storage latency.
  # NOTE: Empty lists fall back to node_locations for backward compatibility.
  effective_master_locations = length(var.master_node_locations) > 0 ? var.master_node_locations : var.node_locations
  effective_worker_locations = length(var.worker_node_locations) > 0 ? var.worker_node_locations : var.node_locations
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  L3: Infrastructure — servers, LBs, network, cloud-init, cluster readiness ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

module "infrastructure" {
  source = "./modules/infrastructure"

  # Cloud credentials
  hcloud_api_token = var.hcloud_api_token

  # Cluster basics
  rke2_cluster_name       = var.rke2_cluster_name
  control_plane_count     = var.control_plane_count
  agent_node_count        = var.agent_node_count
  master_node_server_type = var.master_node_server_type
  worker_node_server_type = var.worker_node_server_type
  master_node_image       = var.master_node_image
  worker_node_image       = var.worker_node_image
  node_locations          = var.node_locations
  master_node_locations   = local.effective_master_locations
  worker_node_locations   = local.effective_worker_locations

  # Network
  hcloud_network_cidr = var.hcloud_network_cidr
  subnet_address      = var.subnet_address
  hcloud_network_zone = var.hcloud_network_zone

  # Load Balancer
  load_balancer_location = var.load_balancer_location
  extra_lb_ports         = var.extra_lb_ports
  enable_ssh_on_lb       = var.enable_ssh_on_lb

  # Firewall
  ssh_allowed_cidrs     = var.ssh_allowed_cidrs
  k8s_api_allowed_cidrs = var.k8s_api_allowed_cidrs

  # SSH
  save_ssh_key_locally = var.save_ssh_key_locally

  # DNS
  create_dns_record = var.create_dns_record
  route53_zone_id   = var.route53_zone_id
  cluster_domain    = var.cluster_domain

  # Harmony toggle (controls ingress LB creation + cloud-init ingress disable)
  harmony_enabled = var.harmony_enabled

  # OpenBao toggle (generates bootstrap token when enabled)
  openbao_enabled = var.openbao_enabled

  # Cloud-init / RKE2 config
  kubernetes_version        = var.kubernetes_version
  cni_plugin                = var.cni_plugin
  enable_secrets_encryption = var.enable_secrets_encryption
  etcd_backup               = var.cluster_configuration.etcd_backup

  # Health checks
  health_check_urls = var.health_check_urls
}

# DECISION: L4 (Kubernetes addons) is managed outside Terraform via Helmfile/ArgoCD/Flux.
# Why: Terraform should own infrastructure (L3) only. Helm chart values change
#      frequently and independently of infrastructure. Running `tofu apply` to
#      change a Helm value risks touching servers, LBs, and DNS. GitOps tools
#      (ArgoCD, Flux) or Helmfile provide a purpose-built deployment path.
# See: charts/ directory for Helmfile configuration and per-addon values.
# See: docs/ARCHITECTURE.md — Layer Separation
