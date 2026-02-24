module "rke2" {
  source               = "../.."
  hcloud_api_token     = var.hcloud_api_token
  control_plane_count  = 3
  agent_node_count     = 1
  save_ssh_key_locally = true

  # NOTE: Keep RKE2 version default (pinned in the module) for a reproducible
  # baseline. Override only when you intentionally test an older/newer line.
  # kubernetes_version = "v1.34.4+rke2r1"

  cluster_configuration = {
    hcloud_controller = {
      preinstall = true
    }
    hcloud_csi = {
      preinstall            = true
      default_storage_class = true
    }
    cert_manager = {
      preinstall = true
    }
  }

  # DECISION: This example uses RKE2 built-in ingress-nginx (Harmony disabled)
  # so ModSecurity WAF can be enabled. DNS automation is intentionally omitted
  # because this module ties create_dns_record to Harmony's ingress LB.
  create_dns_record = false

  domain             = var.cluster_domain
  letsencrypt_issuer = var.letsencrypt_issuer

  enable_nginx_modsecurity_waf   = true
  enable_auto_kubernetes_updates = true

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

