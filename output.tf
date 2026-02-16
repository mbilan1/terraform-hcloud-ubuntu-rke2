output "kube_config" {
  description = "The full kubeconfig file content for cluster access"
  value       = local.kube_config
  sensitive   = true
}

output "cluster_ca" {
  description = "The cluster CA certificate (PEM-encoded)"
  value       = local.cluster_ca
  sensitive   = true
}

output "client_cert" {
  description = "The client certificate for cluster authentication (PEM-encoded)"
  value       = local.client_cert
  sensitive   = true
}

output "client_key" {
  description = "The client private key for cluster authentication (PEM-encoded)"
  value       = local.client_key
  sensitive   = true
}

output "cluster_host" {
  description = "The Kubernetes API server endpoint URL"
  value       = local.cluster_host
}

output "control_plane_lb_ipv4" {
  description = "The IPv4 address of the control-plane load balancer (K8s API, registration)"
  value       = hcloud_load_balancer.control_plane.ipv4
}

output "ingress_lb_ipv4" {
  description = "The IPv4 address of the ingress load balancer (HTTP/HTTPS). Null when harmony is disabled."
  value       = var.harmony.enabled ? hcloud_load_balancer.ingress[0].ipv4 : null
}

output "management_network_id" {
  description = "The ID of the Hetzner Cloud private network"
  value       = hcloud_network.main.id
}

output "management_network_name" {
  description = "The name of the Hetzner Cloud private network"
  value       = hcloud_network.main.name
}

output "cluster_master_nodes_ipv4" {
  description = "The public IPv4 addresses of all master (control plane) nodes"
  value       = concat(hcloud_server.master[*].ipv4_address, hcloud_server.additional_masters[*].ipv4_address)
}

output "cluster_worker_nodes_ipv4" {
  description = "The public IPv4 addresses of all worker nodes"
  value       = hcloud_server.worker[*].ipv4_address
}

output "cluster_issuer_name" {
  description = "The name of the cert-manager ClusterIssuer created by this module"
  value       = var.cluster_issuer_name
}

output "harmony_infrastructure_values" {
  description = "Infrastructure-specific Harmony values applied by this module (for reference only — already merged into the Helm release)"
  value       = yamlencode(local.harmony_infrastructure_values)
}

output "etcd_backup_enabled" {
  description = "Whether automated etcd snapshots with S3 upload are enabled"
  value       = var.cluster_configuration.etcd_backup.enabled
}

output "velero_enabled" {
  description = "Whether Velero PVC backup is enabled"
  value       = var.velero.enabled
}
