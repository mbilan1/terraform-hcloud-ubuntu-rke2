# ──────────────────────────────────────────────────────────────────────────────
# Infrastructure module variables (L3)
#
# DECISION: Variables mirror root module's interface for the L3 layer.
# Why: Child modules receive values from root shim via explicit variable passing.
#      This gives clear contracts between layers.
# ──────────────────────────────────────────────────────────────────────────────

# --- Cloud credentials ---

variable "hcloud_api_token" {
  description = "Hetzner Cloud API token"
  type        = string
  sensitive   = true
}

# --- Cluster basics ---

variable "rke2_cluster_name" {
  description = "Name prefix for all resources"
  type        = string
}

variable "control_plane_count" {
  description = "Number of master (control plane) nodes"
  type        = number
}

variable "agent_node_count" {
  description = "Number of worker nodes"
  type        = number
}

variable "master_node_server_type" {
  description = "Hetzner server type for master nodes"
  type        = string
}

variable "worker_node_server_type" {
  description = "Hetzner server type for worker nodes"
  type        = string
}

variable "master_node_image" {
  description = "OS image for master nodes"
  type        = string
}

variable "worker_node_image" {
  description = "OS image for worker nodes"
  type        = string
}

variable "node_locations" {
  description = "List of Hetzner locations for node placement"
  type        = list(string)
}

variable "master_node_locations" {
  description = "Optional list of Hetzner locations for master node placement. If empty, node_locations is used."
  type        = list(string)
  default     = []
}

variable "worker_node_locations" {
  description = "Optional list of Hetzner locations for worker node placement. If empty, node_locations is used."
  type        = list(string)
  default     = []
}

# --- Network ---

variable "hcloud_network_cidr" {
  description = "CIDR for the private network"
  type        = string
}

variable "subnet_address" {
  description = "CIDR for the subnet"
  type        = string
}

variable "hcloud_network_zone" {
  description = "Network zone for the subnet"
  type        = string
}

# --- Load Balancer ---

variable "load_balancer_location" {
  description = "Location for load balancers"
  type        = string
}

variable "extra_lb_ports" {
  description = "Additional ports for the ingress load balancer"
  type        = list(number)
}

variable "enable_ssh_on_lb" {
  description = "Whether to expose SSH via the control-plane load balancer"
  type        = bool
}

# --- Firewall ---

variable "ssh_allowed_cidrs" {
  description = "CIDRs allowed for SSH access"
  type        = list(string)
}

variable "k8s_api_allowed_cidrs" {
  description = "CIDRs allowed for Kubernetes API access"
  type        = list(string)
}

# --- SSH key ---

variable "save_ssh_key_locally" {
  description = "Whether to write the SSH private key to a local file"
  type        = bool
}

# --- DNS ---

variable "create_dns_record" {
  description = "Whether to create a Route53 wildcard DNS record"
  type        = bool
}

variable "route53_zone_id" {
  description = "AWS Route53 hosted zone ID"
  type        = string
}

variable "cluster_domain" {
  description = "Domain name for DNS records"
  type        = string
}

# --- Harmony toggle (needed for ingress LB + DNS conditional) ---

variable "harmony_enabled" {
  description = "Whether Harmony is enabled (controls ingress LB creation)"
  type        = bool
}

# --- Cloud-init / RKE2 config ---
# DECISION: Cloud-init is inlined into infrastructure module (not a separate bootstrap module).
# Why: Cloud-init needs LB IPv4 + RKE2 token (both created in L3). Separating it
#      into modules/bootstrap/ would create a circular dependency: bootstrap needs
#      LB IP from infrastructure, but infrastructure needs user_data from bootstrap.
#      Inlining eliminates the cycle and keeps the module self-contained.
# See: docs/ARCHITECTURE.md — Cloud-Init Architecture

variable "kubernetes_version" {
  description = "RKE2 version to install (e.g. 'v1.34.4+rke2r1'). Empty string installs latest stable."
  type        = string
}

variable "cni_plugin" {
  description = "CNI plugin for RKE2 (canal, calico, cilium, none)"
  type        = string
}

variable "enable_secrets_encryption" {
  description = "Enable Kubernetes Secrets encryption at rest in etcd"
  type        = bool
}

variable "etcd_backup" {
  description = "etcd backup configuration — passed to cloud-init and pre-upgrade snapshot"
  type = object({
    enabled               = bool
    schedule_cron         = string
    retention             = number
    s3_retention          = number
    compress              = bool
    s3_endpoint           = string
    s3_bucket             = string
    s3_folder             = string
    s3_access_key         = string
    s3_secret_key         = string
    s3_region             = string
    s3_bucket_lookup_type = string
  })
  sensitive = true
}

variable "health_check_urls" {
  description = "HTTP(S) URLs to check after cluster operations (upgrade, restore)"
  type        = list(string)
}
