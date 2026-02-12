variable "hetzner_token" {
  type        = string
  sensitive   = true
  description = "Hetzner Cloud API Token"
}

variable "domain" {
  type        = string
  description = "Domain for the cluster"

  validation {
    condition     = length(var.domain) > 0
    error_message = "Domain must not be empty."
  }
}

variable "master_node_count" {
  type        = number
  default     = 1
  description = "Number of master (control-plane) nodes. Use 1 for non-HA or >= 3 for HA (etcd quorum)."

  validation {
    condition     = var.master_node_count == 1 || var.master_node_count >= 3
    error_message = "master_node_count must be 1 (non-HA) or >= 3 (HA with etcd quorum). A value of 2 results in split-brain."
  }
}

variable "worker_node_count" {
  type        = number
  default     = 0
  description = "Number of dedicated worker nodes. Set to 0 to schedule workloads on control-plane nodes."
}

variable "cluster_name" {
  type        = string
  default     = "rke2"
  description = "Short name for the cluster, used as prefix for all resources (servers, LB, network, firewall)."

  validation {
    condition     = can(regex("^[a-z0-9]{1,20}$", var.cluster_name))
    error_message = "The cluster name must be lowercase and alphanumeric and must not be longer than 20 characters."
  }
}

variable "rke2_version" {
  type        = string
  default     = ""
  description = "RKE2 version to install (e.g. 'v1.30.2+rke2r1'). Empty string installs the latest stable release."
}

variable "rke2_cni" {
  type        = string
  default     = "canal"
  description = "CNI type to use for the cluster"

  validation {
    condition     = contains(["canal", "calico", "cilium", "none"], var.rke2_cni)
    error_message = "The value for CNI must be either 'canal', 'cilium', 'calico' or 'none'."
  }
}

variable "generate_ssh_key_file" {
  type        = bool
  default     = false
  description = "Defines whether the generated ssh key should be stored as local file."
}

variable "lb_location" {
  type        = string
  default     = "hel1"
  description = "Define the location for the management cluster loadbalancer."
}

variable "additional_lb_service_ports" {
  type        = list(number)
  default     = []
  description = "Additional TCP ports to expose on the management load balancer (e.g. [8080, 8443])."

  validation {
    condition     = alltrue([for p in var.additional_lb_service_ports : p > 0 && p <= 65535])
    error_message = "All ports must be between 1 and 65535."
  }
}

variable "network_zone" {
  type        = string
  default     = "eu-central"
  description = "Define the network location for the cluster."
}

variable "network_address" {
  type        = string
  default     = "10.0.0.0/16"
  description = "Define the network for the cluster in CIDR format (e.g., '10.0.0.0/16')."
}

variable "subnet_address" {
  type        = string
  default     = "10.0.1.0/24"
  description = "Define the subnet for cluster nodes in CIDR format. Must be within network_address range."
}

variable "node_locations" {
  type        = list(string)
  default     = ["hel1", "nbg1", "fsn1"]
  description = "Define the location in which nodes will be deployed. (Must be in the same network zone.)"
}

variable "master_node_image" {
  type        = string
  default     = "ubuntu-24.04"
  description = "Define the image for the master nodes."
}

variable "master_node_server_type" {
  type        = string
  default     = "cx23"
  description = "Hetzner Cloud server type for control-plane nodes (e.g. 'cx22', 'cx32', 'cx42')."
}

variable "worker_node_image" {
  type        = string
  default     = "ubuntu-24.04"
  description = "Define the image for the worker nodes."
}

variable "worker_node_server_type" {
  type        = string
  default     = "cx23"
  description = "Hetzner Cloud server type for worker nodes (e.g. 'cx22', 'cx32', 'cx42')."
}

variable "cluster_configuration" {
  type = object({
    hcloud_controller = optional(object({
      version    = optional(string, "1.19.0")
      preinstall = optional(bool, true)
    }), {})
    monitoring_stack = optional(object({
      kube_prom_stack_version = optional(string, "81.0.1")
      loki_stack_version      = optional(string, "2.9.10")
      preinstall              = optional(bool, false)
    }), {})
    istio_service_mesh = optional(object({
      version    = optional(string, "1.18.0")
      preinstall = optional(bool, false)
    }), {})
    tracing_stack = optional(object({
      tempo_version = optional(string, "1.3.1")
      preinstall    = optional(bool, false)
    }), {})
    hcloud_csi = optional(object({
      version               = optional(string, "2.12.0")
      preinstall            = optional(bool, true)
      default_storage_class = optional(bool, true)
      reclaim_policy        = optional(string, "Delete")
    }), {})
    cert_manager = optional(object({
      version                         = optional(string, "v1.19.3")
      preinstall                      = optional(bool, true)
      use_for_preinstalled_components = optional(bool, true)
    }), {})
    self_maintenance = optional(object({
      system_upgrade_controller_version = optional(string, "0.13.4")
      kured_version                     = optional(string, "3.0.1")
    }), {})
  })
  default     = {}
  description = "Define the cluster configuration. (See README.md for more information.)"

  validation {
    condition     = contains(["Delete", "Retain"], var.cluster_configuration.hcloud_csi.reclaim_policy)
    error_message = "hcloud_csi.reclaim_policy must be either 'Delete' or 'Retain'."
  }

  validation {
    condition     = (var.cluster_configuration.monitoring_stack.preinstall == true && var.cluster_configuration.istio_service_mesh.preinstall == true) || var.cluster_configuration.tracing_stack.preinstall == false
    error_message = "The tracing stack can only be installed if the monitoring stack and the istio service mesh are installed."
  }
}

variable "enable_nginx_modsecurity_waf" {
  type        = bool
  default     = false
  description = "Defines whether the nginx modsecurity waf should be enabled."
}

variable "expose_kubernetes_metrics" {
  type        = bool
  default     = false
  description = "Defines whether the kubernetes metrics (scheduler, etcd, ...) should be exposed on the nodes."
}

variable "create_dns_record" {
  type        = bool
  default     = false
  description = "Defines whether a Route53 DNS record should be created for the cluster load balancer."
}

variable "aws_region" {
  type        = string
  default     = "eu-central-1"
  description = "AWS region for the Route53 provider."
}

variable "route53_zone_id" {
  type        = string
  default     = ""
  description = "The Route53 hosted zone ID. (Required if create_dns_record is true.)"
}

variable "aws_access_key" {
  type        = string
  default     = ""
  sensitive   = true
  description = "AWS access key for Route53 and cert-manager DNS-01 solver. If empty, uses default AWS credentials chain."
}

variable "aws_secret_key" {
  type        = string
  default     = ""
  sensitive   = true
  description = "AWS secret key for Route53 and cert-manager DNS-01 solver. If empty, uses default AWS credentials chain."
}

variable "letsencrypt_issuer" {
  type        = string
  default     = ""
  description = "The email to send notifications regarding let's encrypt."
}

variable "cluster_issuer_name" {
  type        = string
  default     = "harmony-letsencrypt-global"
  description = "Name of the cert-manager ClusterIssuer. Defaults to 'harmony-letsencrypt-global' for compatibility with openedx-k8s-harmony Tutor plugin (hardcoded in k8s-services patch)."
}

variable "nginx_ingress_proxy_body_size" {
  type        = string
  default     = "100m"
  description = "Default max request body size for the nginx ingress controller. Set to 100m for Harmony/Open edX compatibility (course uploads)."
}

variable "enable_auto_os_updates" {
  type        = bool
  default     = true
  description = "Whether the OS should be updated automatically."
}

variable "enable_auto_kubernetes_updates" {
  type        = bool
  default     = true
  description = "Whether the kubernetes version should be updated automatically."
}

variable "preinstall_gateway_api_crds" {
  type        = bool
  default     = false
  description = "Whether the gateway api crds should be preinstalled."
}

variable "gateway_api_version" {
  type        = string
  default     = "v0.7.1"
  description = "The version of the gateway api to install."
}

variable "harmony" {
  type = object({
    enabled      = optional(bool, true)
    version      = optional(string, "")
    extra_values = optional(list(string), [])
  })
  default     = {}
  description = <<-EOT
    Harmony chart (openedx-k8s-harmony) integration.
    - enabled: Deploy Harmony chart via Helm. Disables RKE2 built-in ingress-nginx and routes HTTP/HTTPS through the management LB.
    - version: Chart version to install. Empty string means latest.
    - extra_values: Additional values.yaml content (list of YAML strings) merged after infrastructure defaults.
  EOT
}

variable "expose_oidc_issuer_url" {
  type        = bool
  default     = false
  description = "Expose the OIDC discovery endpoint via Ingress at oidc.<domain>. Enables anonymous-auth and custom service-account-issuer on the API server."
}

# ──────────────────────────────────────────────────────────────────────────────
# SSH / K8s API access control
#
# Why default to open (0.0.0.0/0) instead of closed ([]):
#
# 1. The module uses null_resource provisioners (wait_for_api, wait_for_cluster_ready)
#    and data.remote_file (kubeconfig) that SSH into master[0] over its PUBLIC IP.
#    If SSH is blocked by the firewall, `tofu apply` hangs indefinitely.
#
# 2. Auto-detecting the runner's IP via `data "http"` is fragile:
#    - Breaks behind NAT, VPN, corporate proxies, IPv6-only networks
#    - Adds an external dependency (ifconfig.me / checkip) to every `plan`
#    - Fails in air-gapped / CI environments without internet egress
#
# 3. Requiring the user to pass their own IP makes the module unusable out of
#    the box and causes a confusing hang rather than a clear error message.
#
# 4. This follows the pattern of major cloud modules (terraform-aws-eks,
#    terraform-google-gke) that default network access to open and document
#    "restrict in production". SSH key auth (generated by the module) is the
#    primary security boundary; the firewall is defense-in-depth.
#
# In production, restrict these to your CI runner / bastion / VPN CIDR.
# ──────────────────────────────────────────────────────────────────────────────
variable "ssh_allowed_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
  description = "CIDR blocks allowed to access SSH (port 22) on cluster nodes. Defaults to open because the module's provisioners require SSH to master[0]. Restrict to your runner/bastion CIDR in production (e.g. ['1.2.3.4/32'])."
}

variable "k8s_api_allowed_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
  description = "CIDR blocks allowed to access the Kubernetes API (port 6443). Defaults to open for module usability; restrict in production."
}

variable "enable_ssh_on_lb" {
  type        = bool
  default     = false
  description = "Expose SSH (port 22) via the management load balancer. Disabled by default for security. Enable only for debugging or when bastion access is unavailable."
}

variable "enable_secrets_encryption" {
  type        = bool
  default     = true
  description = "Enable Kubernetes Secrets encryption at rest in etcd. Strongly recommended for production."
}
