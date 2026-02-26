variable "agent_node_count" {
  description = "Count of dedicated agent nodes that run workloads. Set to 0 to co-locate pods on control-plane servers."
  type        = number
  nullable    = false
  default     = 3
}

variable "aws_access_key" {
  description = "AWS access key for Route53 DNS management. If empty, uses default AWS credentials chain."
  type        = string
  nullable    = false
  sensitive   = true
  default     = ""
}

variable "aws_region" {
  description = "AWS region used by the Route53 provider."
  type        = string
  nullable    = false
  default     = "eu-central-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-\\d+$", var.aws_region))
    error_message = "aws_region must look like an AWS region id (e.g. eu-central-1)."
  }
}

variable "aws_secret_key" {
  description = "AWS secret key for Route53 DNS management. If empty, uses default AWS credentials chain."
  type        = string
  nullable    = false
  sensitive   = true
  default     = ""
}

# DECISION: cluster_configuration reduced to infrastructure-only concerns.
# Why: L4 addons (cert-manager, CSI, Longhorn, self-maintenance) are now
#      managed outside Terraform via Helmfile/ArgoCD/Flux. Only etcd_backup
#      remains because it is configured in cloud-init at RKE2 startup — a
#      pure infrastructure concern, independent of cluster health.
# See: charts/ directory for L4 addon values and Helmfile configuration.
variable "cluster_configuration" {
  description = <<-EOT
    Infrastructure-level configuration for the RKE2 cluster.
    Currently contains etcd backup settings (configured via cloud-init).
  EOT
  type = object({
    # ── etcd snapshot + S3 offsite backup ─────────────────────────────────
    # DECISION: etcd backup via RKE2 native config.yaml params (zero dependencies)
    # Why: etcd snapshot is built into RKE2, configured in cloud-init before K8s starts.
    #      This makes it independent of cluster health — works even if K8s is down.
    # See: https://docs.rke2.io/datastore/backup_restore
    etcd_backup = optional(object({
      enabled               = optional(bool, false)
      compress              = optional(bool, true)
      schedule_cron         = optional(string, "0 */6 * * *")
      retention             = optional(number, 10)
      s3_retention          = optional(number, 10)
      s3_endpoint           = optional(string, "")
      s3_bucket             = optional(string, "")
      s3_folder             = optional(string, "")
      s3_access_key         = optional(string, "")
      s3_secret_key         = optional(string, "")
      s3_region             = optional(string, "eu-central")
      s3_bucket_lookup_type = optional(string, "path")

      # NOTE: Optional metadata for operators.
      # Why: Cron/schedule semantics sometimes depend on human conventions.
      description = optional(string, "")
    }), {})
  })
  default = {}
}

variable "cluster_domain" {
  description = "Base DNS domain associated with this Kubernetes cluster (e.g. 'k8s.example.com')"
  type        = string
  nullable    = false

  validation {
    condition     = length(var.cluster_domain) > 0
    error_message = "Domain must not be empty."
  }

  validation {
    # NOTE: Keep this permissive (not a full RFC check) but avoid accidental whitespace.
    condition     = var.cluster_domain == trimspace(var.cluster_domain)
    error_message = "cluster_domain must not contain leading or trailing whitespace."
  }
}

variable "cni_plugin" {
  description = "Container networking plugin for inter-pod communication. RKE2 bundles Canal (Flannel VXLAN + Calico network policy) by default."
  type        = string
  nullable    = false
  default     = "canal"

  validation {
    condition     = contains(["canal", "calico", "cilium", "none"], var.cni_plugin)
    error_message = "cni_plugin must be one of: canal, calico, cilium, none."
  }
}

variable "control_plane_count" {
  description = "Count of server nodes in the control plane. Set to 1 for single-master or 3+ for high-availability (etcd quorum requires an odd count)."
  type        = number
  nullable    = false
  default     = 3

  validation {
    condition     = var.control_plane_count == 1 || var.control_plane_count >= 3
    error_message = "control_plane_count must be 1 (non-HA) or >= 3 (HA with etcd quorum). A value of 2 results in split-brain."
  }
}

variable "create_dns_record" {
  description = "Provision a Route53 wildcard DNS record (*.cluster_domain) pointing to the ingress load balancer. Requires harmony_enabled=true for the ingress LB to exist."
  type        = bool
  nullable    = false
  default     = false
}

variable "enable_secrets_encryption" {
  description = "Enable Kubernetes Secrets encryption at rest in etcd via RKE2 secrets-encryption config. Strongly recommended for production."
  type        = bool
  nullable    = false
  default     = true
}

variable "enable_ssh_on_lb" {
  description = "Expose SSH (port 22) via the management load balancer. Disabled by default for security. Enable only for debugging or when bastion access is unavailable."
  type        = bool
  nullable    = false
  default     = false
}

variable "enforce_single_country_workers" {
  description = "When true, forbid mixing worker locations across countries (e.g., hel1 + nbg1). Why: sync-heavy storage (Longhorn/MySQL) becomes unusably slow with cross-country RTT; enforce a single-country worker pool (Germany-only or Finland-only)."
  type        = bool
  nullable    = false
  default     = false
}

variable "extra_lb_ports" {
  description = "Additional TCP ports to expose on the ingress load balancer (requires harmony_enabled=true). These ports are forwarded to worker nodes, not the control-plane management LB (e.g. [8080, 8443])."
  type        = list(number)
  nullable    = false
  default     = []

  validation {
    condition     = alltrue([for port in var.extra_lb_ports : port > 0 && port <= 65535])
    error_message = "Each port in extra_lb_ports must be in the range 1..65535."
  }
}

# DECISION: harmony simplified to a boolean toggle for infrastructure.
# Why: Harmony controls two infrastructure-level decisions:
#   1. Whether the ingress LB is created (workers as targets for HTTP/HTTPS)
#   2. Whether RKE2 built-in ingress is disabled via cloud-init
# Everything else (chart version, values, TLS config) is now L4 configuration
# managed via Helmfile/ArgoCD. See charts/harmony/ for values.
variable "harmony_enabled" {
  description = "Enable Harmony integration: creates the ingress load balancer and disables RKE2 built-in ingress. Harmony chart deployment is managed externally (Helmfile/ArgoCD)."
  type        = bool
  nullable    = false
  default     = false
}

# DECISION: OpenBao as an optional secrets management layer (experimental).
# Why: The default kubeconfig retrieval uses data \"external\" + SSH (simple, no
#      extra dependencies). This is secure — SSH key is ephemeral, output is
#      marked sensitive — but the kubeconfig ends up in Terraform state.
#      Operators who need enterprise-grade secrets management (audit log,
#      RBAC, auto-rotation, team access) can enable OpenBao in the cluster.
#
# SECURITY DISCLAIMER:
#   With openbao_enabled = false (default), kubeconfig security is the
#   OPERATOR'S responsibility:
#     - Terraform state contains the kubeconfig (protect with encrypted backend + ACL)
#     - `tofu output -raw kube_config` prints it to stdout (do not pipe to logs)
#     - The SSH private key exists only in state (never written to disk unless
#       save_ssh_key_locally = true)
#   The module does NOT guarantee that credentials never leak — it marks outputs
#   as sensitive and uses ephemeral channels, but the operator must secure the
#   state file and output handling.
#
# See: charts/openbao/ for Helmfile deployment
# See: docs/ARCHITECTURE.md — OpenBao Integration
variable "openbao_enabled" {
  description = "[EXPERIMENTAL] Enable OpenBao (open-source Vault) deployment in the cluster for secrets management. Generates a bootstrap token for initial operator access. Requires agent_node_count >= 1 and enable_secrets_encryption = true."
  type        = bool
  nullable    = false
  default     = false
}

variable "hcloud_api_token" {
  description = "Authentication token for the Hetzner Cloud provider (read/write access required)"
  type        = string
  nullable    = false
  sensitive   = true
}

variable "hcloud_network_cidr" {
  description = "IPv4 address range for the Hetzner private network in CIDR notation"
  type        = string
  nullable    = false
  default     = "10.0.0.0/16"

  # Why strict CIDR validation here:
  # - Prevents provider/runtime failures later in the graph with less obvious errors.
  # - Fails early at input-validation stage with a clear message.
  # Alternative considered: rely on Hetzner provider validation only.
  # Rejected because errors appear later and are harder to map to user input.
  validation {
    condition     = can(cidrnetmask(var.hcloud_network_cidr))
    error_message = "hcloud_network_cidr must be a valid CIDR block (e.g. 10.0.0.0/16)."
  }
}

variable "hcloud_network_zone" {
  description = "Hetzner network zone encompassing all node locations (must cover every datacenter in node_locations)"
  type        = string
  nullable    = false
  default     = "eu-central"

  # DECISION: Validate against known Hetzner network zones.
  # Why: Invalid zone causes cryptic API errors at apply time.
  #      Early validation gives immediate, actionable feedback.
  # See: https://docs.hetzner.cloud/#networks
  validation {
    condition     = contains(["eu-central", "us-east", "us-west", "ap-southeast"], var.hcloud_network_zone)
    error_message = "hcloud_network_zone must be one of: eu-central, us-east, us-west, ap-southeast."
  }
}

variable "health_check_urls" {
  description = <<-EOT
    HTTP(S) URLs to check after cluster operations (upgrade, restore).
    Each URL must return 2xx/3xx to pass. Empty list skips HTTP checks.
    For OpenEdx: ["https://yourdomain.com/heartbeat"]
    The /heartbeat endpoint validates MySQL, MongoDB, and app availability.
  EOT
  type        = list(string)
  nullable    = false
  default     = []

  validation {
    # NOTE: Very permissive URL-ish check; allows http/https only.
    condition     = alltrue([for u in var.health_check_urls : can(regex("^https?://", u))])
    error_message = "health_check_urls entries must start with http:// or https://."
  }
}

variable "k8s_api_allowed_cidrs" {
  description = "CIDR blocks allowed to access the Kubernetes API (port 6443). Defaults to open for module usability; restrict in production."
  type        = list(string)
  nullable    = false
  default     = ["0.0.0.0/0", "::/0"]

  # Why require at least one CIDR:
  # - Kubernetes/Helm providers need API reachability during apply.
  # - Empty list frequently leads to self-inflicted lockout and broken applies.
  # Alternative considered: allow empty list for strict lockdown scenarios.
  # Rejected at module level; strict lockdown should be done after bootstrap with
  # explicit operator controls (VPN/bastion) to avoid accidental dead-end states.
  validation {
    condition     = length(var.k8s_api_allowed_cidrs) > 0
    error_message = "k8s_api_allowed_cidrs must contain at least one CIDR block."
  }

  # Keep syntax validation even with permissive defaults, so user-provided values
  # fail early and predictably.
  validation {
    # Same parser-level validation as above: supports both IPv4 and IPv6 CIDRs.
    condition     = alltrue([for c in var.k8s_api_allowed_cidrs : can(cidrsubnet(c, 0, 0))])
    error_message = "All k8s_api_allowed_cidrs entries must be valid CIDR blocks."
  }
}

variable "load_balancer_location" {
  description = "Hetzner datacenter location where both load balancers will be provisioned (e.g. 'hel1', 'nbg1', 'fsn1')"
  type        = string
  nullable    = false
  default     = "hel1"

  validation {
    condition     = length(var.load_balancer_location) > 0
    error_message = "load_balancer_location must not be empty."
  }
}

variable "master_node_locations" {
  description = "Optional list of Hetzner locations to place control-plane nodes. If empty, node_locations is used. Why: allows masters spread across multiple cities while keeping workers in a subset (e.g., Germany-only)."
  type        = list(string)
  nullable    = false
  default     = []
}

variable "master_node_server_type" {
  description = "Hetzner Cloud server type for control-plane nodes (e.g. 'cx23', 'cx33', 'cx43')."
  type        = string
  nullable    = false
  default     = "cx23"
}

variable "node_locations" {
  description = "(Deprecated) Fallback placement locations when master_node_locations/worker_node_locations are unset. All entries must share the same network zone."
  type        = list(string)
  nullable    = false
  default     = ["hel1", "nbg1", "fsn1"]

  validation {
    condition     = length(var.node_locations) >= 1
    error_message = "At least one node location must be specified."
  }
}

variable "rke2_cluster_name" {
  description = "Identifier prefix for all provisioned resources (servers, load balancers, network, firewall rules). Must be lowercase alphanumeric, max 20 characters."
  type        = string
  nullable    = false
  default     = "rke2"

  validation {
    condition     = can(regex("^[a-z0-9]{1,20}$", var.rke2_cluster_name))
    error_message = "The cluster name must be lowercase and alphanumeric and must not be longer than 20 characters."
  }
}

variable "route53_zone_id" {
  description = "Hosted zone identifier in Route53. Required when create_dns_record is true."
  type        = string
  nullable    = false
  default     = ""
}

variable "save_ssh_key_locally" {
  description = "Persist the auto-generated SSH private key to the local filesystem for manual node access"
  type        = bool
  nullable    = false
  default     = false
}

# ──────────────────────────────────────────────────────────────────────────────
# SSH / K8s API access control
#
# Why default to open (0.0.0.0/0) instead of closed ([]):
#
# 1. The module uses terraform_data provisioners (wait_for_api, wait_for_cluster_ready)
#    and data.external (kubeconfig fetch script) that SSH into master[0] over its PUBLIC IP.
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
  description = "CIDR blocks allowed to access SSH (port 22) on cluster nodes. Defaults to open because the module's provisioners require SSH to master[0]. Restrict to your runner/bastion CIDR in production (e.g. ['1.2.3.4/32'])."
  type        = list(string)
  nullable    = false
  default     = ["0.0.0.0/0", "::/0"]

  # Compromise rationale:
  # - We keep open defaults for bootstrap usability (documented module trade-off),
  #   but still validate syntax to avoid silent misconfiguration.
  # Alternative considered: force non-empty private CIDRs by default.
  # Rejected for now because it breaks "first apply" flow for many users and CI runners.
  validation {
    # Use cidrsubnet(..., 0, 0) as a parse-only check that works for both
    # IPv4 and IPv6 CIDRs (including broad ranges like 0.0.0.0/0 and ::/0).
    condition     = alltrue([for c in var.ssh_allowed_cidrs : can(cidrsubnet(c, 0, 0))])
    error_message = "All ssh_allowed_cidrs entries must be valid CIDR blocks."
  }
}

variable "subnet_address" {
  description = "Subnet allocation for cluster nodes in CIDR notation. Must fall within the hcloud_network_cidr range."
  type        = string
  nullable    = false
  default     = "10.0.1.0/24"

  # Same rationale as hcloud_network_cidr: fail fast on malformed CIDR values.
  # This is intentionally syntax-level validation only; semantic relationship
  # (subnet inside network range) should be handled via a dedicated cross-variable
  # check to keep each validation focused and understandable.
  validation {
    condition     = can(cidrnetmask(var.subnet_address))
    error_message = "subnet_address must be a valid CIDR block (e.g. 10.0.1.0/24)."
  }
}

variable "worker_node_locations" {
  description = "Optional list of Hetzner locations to place worker nodes. If empty, node_locations is used. Why: lets you keep workload I/O local (e.g., Germany-only) while masters can span more regions."
  type        = list(string)
  nullable    = false
  default     = []
}

variable "worker_node_server_type" {
  description = "Hetzner Cloud server type for worker nodes (e.g. 'cx23', 'cx33', 'cx43')."
  type        = string
  nullable    = false
  default     = "cx23"
}
