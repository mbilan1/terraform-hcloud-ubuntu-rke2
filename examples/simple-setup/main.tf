module "rke2" {
  source                = "../.."
  hetzner_token         = var.hetzner_token
  master_node_count     = 3
  worker_node_count     = 1
  generate_ssh_key_file = true
  rke2_version          = "v1.27.1+rke2r1"
  cluster_configuration = {
    hcloud_controller = {
      preinstall = true
    }
    hcloud_csi = {
      preinstall            = true
      default_storage_class = true
    }
  }
  create_dns_record              = true
  route53_zone_id                = var.route53_zone_id
  aws_region                     = var.aws_region
  letsencrypt_issuer             = var.letsencrypt_issuer
  enable_nginx_modsecurity_waf   = true
  enable_auto_kubernetes_updates = true
  preinstall_gateway_api_crds    = true
  domain                         = "hetznerdoesnot.work"
  expose_oidc_issuer_url         = true

  # Security: restrict SSH and K8s API access in production
  # ssh_allowed_cidrs    = ["YOUR_IP/32"] # Restrict SSH to your IP
  # k8s_api_allowed_cidrs = ["YOUR_IP/32"] # Restrict API to your IP
  enable_ssh_on_lb     = false
}

resource "local_sensitive_file" "kubeconfig" {
  content         = module.rke2.kube_config
  filename        = "kubeconfig.yaml"
  file_permission = "0600"
}

