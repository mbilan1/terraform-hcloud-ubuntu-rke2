# ──────────────────────────────────────────────────────────────────────────────
# Simple HA setup — 3 masters + 1 worker with RKE2 built-in ingress
#
# DECISION: This example demonstrates a basic HA cluster without Harmony.
# Why: Shows the simplest production-capable configuration with SSH key
#      export for manual node access and RKE2's built-in ingress controller.
# ──────────────────────────────────────────────────────────────────────────────

module "rke2" {
  source               = "../.."
  hcloud_api_token     = var.hcloud_api_token
  cluster_domain       = var.cluster_domain
  control_plane_count  = 3
  agent_node_count     = 1
  save_ssh_key_locally = true

  # NOTE: Keep RKE2 version default (pinned in the module) for a reproducible
  # baseline. Override only when you intentionally test an older/newer line.
  # kubernetes_version = "v1.34.4+rke2r1"

  # DECISION: This example uses RKE2 built-in ingress-nginx (Harmony disabled).
  # DNS automation is intentionally omitted because this module ties
  # create_dns_record to Harmony's ingress LB.
  create_dns_record = false

  # Security: restrict SSH and K8s API access in production
  # ssh_allowed_cidrs    = ["YOUR_IP/32"] # Restrict SSH to your IP
  # k8s_api_allowed_cidrs = ["YOUR_IP/32"] # Restrict API to your IP
  enable_ssh_on_lb = false
}

resource "local_sensitive_file" "kubeconfig" {
  content         = module.rke2.kube_config
  filename        = "kubeconfig.yaml"
  file_permission = "0600"
}

