# ──────────────────────────────────────────────────────────────────────────────
# Root module outputs — rewired to child module outputs
#
# DECISION: Root outputs preserve backward compatibility with existing consumers.
# Why: Existing deployments (abstract-k8s-common-template, examples/) reference
#      these output names. Changing names would be a breaking change.
# ──────────────────────────────────────────────────────────────────────────────

output "kube_config" {
  description = "The full kubeconfig file content for cluster access"
  value       = module.infrastructure.kube_config
  sensitive   = true
}

output "cluster_ca" {
  description = "The cluster CA certificate (PEM-encoded)"
  value       = module.infrastructure.cluster_ca
  sensitive   = true
}

output "client_cert" {
  description = "The client certificate for cluster authentication (PEM-encoded)"
  value       = module.infrastructure.client_cert
  sensitive   = true
}

output "client_key" {
  description = "The client private key for cluster authentication (PEM-encoded)"
  value       = module.infrastructure.client_key
  sensitive   = true
}

output "cluster_host" {
  description = "The Kubernetes API server endpoint URL"
  value       = module.infrastructure.cluster_host
}

output "control_plane_lb_ipv4" {
  description = "The IPv4 address of the control-plane load balancer (K8s API, registration)"
  value       = module.infrastructure.control_plane_lb_ipv4
}

output "ingress_lb_ipv4" {
  description = "The IPv4 address of the ingress load balancer (HTTP/HTTPS). Null when harmony is disabled."
  value       = module.infrastructure.ingress_lb_ipv4
}

output "management_network_id" {
  description = "The ID of the Hetzner Cloud private network"
  value       = module.infrastructure.network_id
}

output "management_network_name" {
  description = "The name of the Hetzner Cloud private network"
  value       = module.infrastructure.network_name
}

output "cluster_master_nodes_ipv4" {
  description = "The public IPv4 addresses of all master (control plane) nodes"
  value       = module.infrastructure.master_nodes_ipv4
}

output "cluster_worker_nodes_ipv4" {
  description = "The public IPv4 addresses of all worker nodes"
  value       = module.infrastructure.worker_nodes_ipv4
}

output "cluster_ready" {
  description = "Dependency anchor — signals that the cluster is bootstrapped: API is reachable, all nodes are Ready, and health checks passed"
  value       = module.infrastructure.cluster_ready
}

output "etcd_backup_enabled" {
  description = "Whether automated etcd snapshots with S3 upload are enabled"
  value       = var.cluster_configuration.etcd_backup.enabled
}

# --- OpenBao (experimental) ---

output "openbao_bootstrap_token" {
  description = "[EXPERIMENTAL] One-time bootstrap token for initial OpenBao access. Used as devRootToken in charts/openbao/values.yaml. REVOKE immediately after configuring permanent auth (OIDC/LDAP/UserPass). Null when openbao_enabled = false."
  value       = module.infrastructure.openbao_bootstrap_token
  sensitive   = true
}

output "openbao_url" {
  description = "[EXPERIMENTAL] OpenBao API/UI endpoint. Operator accesses this URL with the bootstrap token to retrieve kubeconfig and manage secrets. Null when openbao_enabled = false."
  value       = var.openbao_enabled ? "https://vault.${var.cluster_domain}" : null
}
