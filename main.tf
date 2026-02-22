# ──────────────────────────────────────────────────────────────────────────────
# Root module — orchestration shim
#
# DECISION: Root module is a thin shim that wires child modules together.
# Why: HashiCorp "split a module" pattern — root declares variables/providers,
#      child modules contain all resource logic. This gives clear layer boundaries:
#        modules/infrastructure/ (L3) — servers, LBs, network, cloud-init, readiness
#        modules/addons/         (L4) — Helm charts, K8s resources, lifecycle
# See: https://developer.hashicorp.com/terraform/language/modules/develop/refactoring
#      docs/ARCHITECTURE.md — Module Architecture
# ──────────────────────────────────────────────────────────────────────────────

locals {
  # DECISION: Allow separate master/worker location lists.
  # Why: Operators may want control-plane nodes spread across multiple EU DCs
  #      while keeping workers (and thus stateful workloads) confined to a
  #      subset (e.g., Germany-only) to reduce cross-DC storage latency.
  # NOTE: Empty lists fall back to node_locations for backward compatibility.
  effective_master_node_locations = length(var.master_node_locations) > 0 ? var.master_node_locations : var.node_locations
  effective_worker_node_locations = length(var.worker_node_locations) > 0 ? var.worker_node_locations : var.node_locations
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  L3: Infrastructure — servers, LBs, network, cloud-init, cluster readiness ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

module "infrastructure" {
  source = "./modules/infrastructure"

  # Cloud credentials
  hetzner_token = var.hetzner_token

  # Cluster basics
  cluster_name            = var.cluster_name
  master_node_count       = var.master_node_count
  worker_node_count       = var.worker_node_count
  master_node_server_type = var.master_node_server_type
  worker_node_server_type = var.worker_node_server_type
  master_node_image       = var.master_node_image
  worker_node_image       = var.worker_node_image
  node_locations          = var.node_locations
  master_node_locations   = local.effective_master_node_locations
  worker_node_locations   = local.effective_worker_node_locations

  # Network
  network_address = var.network_address
  subnet_address  = var.subnet_address
  network_zone    = var.network_zone

  # Load Balancer
  lb_location                 = var.lb_location
  additional_lb_service_ports = var.additional_lb_service_ports
  enable_ssh_on_lb            = var.enable_ssh_on_lb

  # Firewall
  ssh_allowed_cidrs     = var.ssh_allowed_cidrs
  k8s_api_allowed_cidrs = var.k8s_api_allowed_cidrs

  # SSH
  generate_ssh_key_file = var.generate_ssh_key_file

  # DNS
  create_dns_record = var.create_dns_record
  route53_zone_id   = var.route53_zone_id
  domain            = var.domain

  # Harmony toggle (controls ingress LB creation + cloud-init ingress disable)
  harmony_enabled = var.harmony.enabled

  # Cloud-init / RKE2 config
  rke2_version              = var.rke2_version
  rke2_cni                  = var.rke2_cni
  enable_secrets_encryption = var.enable_secrets_encryption
  etcd_backup               = var.cluster_configuration.etcd_backup

  # Health checks
  health_check_urls = var.health_check_urls
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  L4: Addons — Helm charts, K8s resources, operational lifecycle            ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

module "addons" {
  source = "./modules/addons"

  # From infrastructure module
  cluster_ready     = module.infrastructure.cluster_ready
  master_ipv4       = module.infrastructure.master_ipv4
  ssh_private_key   = module.infrastructure.ssh_private_key
  network_name      = module.infrastructure.network_name
  worker_node_names = module.infrastructure.worker_node_names

  # Root passthrough
  hetzner_token                   = var.hetzner_token
  cluster_configuration           = var.cluster_configuration
  harmony                         = var.harmony
  domain                          = var.domain
  letsencrypt_issuer              = var.letsencrypt_issuer
  cluster_issuer_name             = var.cluster_issuer_name
  aws_region                      = var.aws_region
  aws_access_key                  = var.aws_access_key
  aws_secret_key                  = var.aws_secret_key
  route53_zone_id                 = var.route53_zone_id
  enable_nginx_modsecurity_waf    = var.enable_nginx_modsecurity_waf
  nginx_ingress_proxy_body_size   = var.nginx_ingress_proxy_body_size
  enable_auto_os_updates          = var.enable_auto_os_updates
  enable_auto_kubernetes_updates  = var.enable_auto_kubernetes_updates
  allow_remote_manifest_downloads = var.allow_remote_manifest_downloads
  rke2_version                    = var.rke2_version
  worker_node_count               = var.worker_node_count
  master_node_count               = var.master_node_count
  lb_location                     = var.lb_location
}
