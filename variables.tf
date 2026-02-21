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
  default     = 3
  description = "Number of master (control-plane) nodes. Use 1 for non-HA or >= 3 for HA (etcd quorum)."

  validation {
    condition     = var.master_node_count == 1 || var.master_node_count >= 3
    error_message = "master_node_count must be 1 (non-HA) or >= 3 (HA with etcd quorum). A value of 2 results in split-brain."
  }
}

variable "worker_node_count" {
  type        = number
  default     = 3
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

# DECISION: Pin RKE2 to v1.34.x (latest Rancher-supported line, ~8 months support remaining)
# Why: Unpinned installs from 'stable' channel produce non-reproducible clusters.
#      v1.34 is the newest line in the SUSE Rancher support matrix (v1.32–v1.34).
#      v1.35 is not yet in the support matrix. v1.32 is at EOL (~Feb 2026).
# See: https://www.suse.com/suse-rancher/support-matrix/
# See: https://github.com/rancher/rke2/releases/tag/v1.34.4%2Brke2r1
variable "rke2_version" {
  type        = string
  default     = "v1.34.4+rke2r1"
  description = "RKE2 version to install (e.g. 'v1.34.4+rke2r1'). Empty string installs the latest stable release."
}

variable "rke2_cni" {
  type        = string
  default     = "canal"
  description = "Cluster CNI (networking) implementation. Allowed values are: canal, calico, cilium, none."

  validation {
    condition     = contains(["calico", "canal", "cilium", "none"], lower(trimspace(var.rke2_cni)))
    error_message = "rke2_cni must be one of: calico, canal, cilium, none."
  }
}

variable "generate_ssh_key_file" {
  type        = bool
  default     = false
  description = "When true, write the generated SSH private key to a local file for operator debugging."
}

variable "additional_lb_service_ports" {
  type        = list(number)
  default     = []
  description = "Extra TCP ports to expose on the control-plane load balancer (in addition to 6443/9345)."

  validation {
    condition     = alltrue([for p in var.additional_lb_service_ports : p > 0 && p <= 65535])
    error_message = "All ports must be between 1 and 65535."
  }
}

variable "lb_location" {
  type        = string
  default     = "hel1"
  description = "Hetzner location for the control-plane load balancer (e.g. hel1, nbg1, fsn1)."
}

variable "network_zone" {
  type        = string
  default     = "eu-central"
  description = "Hetzner network zone for private networking (e.g. eu-central)."
}

variable "network_address" {
  type        = string
  default     = "10.0.0.0/16"
  description = "Define the network for the cluster in CIDR format (e.g., '10.0.0.0/16')."

  # Why strict CIDR validation here:
  # - Prevents provider/runtime failures later in the graph with less obvious errors.
  # - Fails early at input-validation stage with a clear message.
  # Alternative considered: rely on Hetzner provider validation only.
  # Rejected because errors appear later and are harder to map to user input.
  validation {
    condition     = can(cidrnetmask(var.network_address))
    error_message = "network_address must be a valid CIDR block (e.g. 10.0.0.0/16)."
  }
}

variable "subnet_address" {
  type        = string
  default     = "10.0.1.0/24"
  description = "Define the subnet for cluster nodes in CIDR format. Must be within network_address range."

  # Same rationale as network_address: fail fast on malformed CIDR values.
  # This is intentionally syntax-level validation only; semantic relationship
  # (subnet inside network range) should be handled via a dedicated cross-variable
  # check to keep each validation focused and understandable.
  validation {
    condition     = can(cidrnetmask(var.subnet_address))
    error_message = "subnet_address must be a valid CIDR block (e.g. 10.0.1.0/24)."
  }
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
    # DECISION: etcd backup via RKE2 native config.yaml params (zero dependencies)
    # Why: etcd snapshot is built into RKE2, configured in cloud-init before K8s starts.
    #      This makes it independent of cluster health — works even if K8s is down.
    # See: https://docs.rke2.io/datastore/backup_restore
    etcd_backup = optional(object({
      enabled               = optional(bool, false)
      schedule_cron         = optional(string, "0 */6 * * *") # Every 6h (RKE2 default is 12h — too infrequent for production)
      retention             = optional(number, 10)
      s3_retention          = optional(number, 10) # S3-specific retention (separate from local). Available since RKE2 v1.34.0+.
      compress              = optional(bool, true)
      s3_endpoint           = optional(string, "") # Auto-filled from lb_location if empty
      s3_bucket             = optional(string, "")
      s3_folder             = optional(string, "") # Defaults to cluster_name
      s3_access_key         = optional(string, "")
      s3_secret_key         = optional(string, "")
      s3_region             = optional(string, "eu-central")
      s3_bucket_lookup_type = optional(string, "path") # "path" required for Hetzner Object Storage
    }), {})
    # DECISION: Longhorn as primary storage driver with native backup
    # Why: Replication across workers (HA). Local NVMe IOPS (~50K vs ~10K).
    #      Native VolumeSnapshot (Hetzner CSI has none — issue #849).
    #      Integrated storage + backup in single component. Instant pre-upgrade snapshots.
    #      Fewer components in restore path compared to external backup tools.
    # DECISION: Longhorn replaces Hetzner CSI as primary storage driver
    # Why: Replication across workers (HA). Local NVMe IOPS (~50K vs ~10K).
    #      VolumeSnapshot support. Native S3 backup.
    # NOTE: Longhorn is marked EXPERIMENTAL. Hetzner CSI retained as fallback.
    # TODO: Promote Longhorn to default after battle-tested in production.
    # See: docs/PLAN-operational-readiness.md — Step 2
    longhorn = optional(object({
      version               = optional(string, "1.7.3")
      preinstall            = optional(bool, false)           # Experimental, disabled by default
      replica_count         = optional(number, 2)             # 2 = balance between safety and disk usage
      default_storage_class = optional(bool, true)            # Make longhorn the default SC
      backup_target         = optional(string, "")            # S3 URL: s3://bucket@region/folder
      backup_schedule       = optional(string, "0 */6 * * *") # Every 6h, matches etcd schedule
      backup_retain         = optional(number, 10)            # Keep 10 backups
      s3_endpoint           = optional(string, "")            # Auto-filled from lb_location if empty
      s3_access_key         = optional(string, "")
      s3_secret_key         = optional(string, "")

      # Tuning (see PLAN-operational-readiness.md Appendix A)
      guaranteed_instance_manager_cpu = optional(number, 12)  # % of node CPU for instance managers
      storage_over_provisioning       = optional(number, 100) # % — 100 = no overprovisioning
      storage_minimal_available       = optional(number, 15)  # % — minimum free disk before Longhorn stops scheduling
      snapshot_max_count              = optional(number, 5)   # Max snapshots per volume before auto-cleanup
    }), {})
  })
  default     = {}
  description = "Define the cluster configuration. (See README.md for more information.)"

  validation {
    condition     = contains(["Delete", "Retain"], var.cluster_configuration.hcloud_csi.reclaim_policy)
    error_message = "hcloud_csi.reclaim_policy must be either 'Delete' or 'Retain'."
  }
}

variable "enable_nginx_modsecurity_waf" {
  type        = bool
  default     = false
  description = "Defines whether the nginx modsecurity waf should be enabled."
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
  default     = false
  description = "Whether the OS should be updated automatically."
}

variable "enable_auto_kubernetes_updates" {
  type        = bool
  default     = false
  description = "Whether the kubernetes version should be updated automatically."
}

variable "allow_remote_manifest_downloads" {
  type        = bool
  default     = true
  description = "Allow downloading external manifests from GitHub at plan/apply time (System Upgrade Controller). Disable for stricter reproducibility/offline workflows."
}

variable "harmony" {
  type = object({
    enabled      = optional(bool, false)
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

# ──────────────────────────────────────────────────────────────────────────────
# SSH / K8s API access control
#
# Why default to open (0.0.0.0/0) instead of closed ([]):
#
# 1. The module uses terraform_data provisioners (wait_for_api, wait_for_cluster_ready)
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

variable "k8s_api_allowed_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
  description = "CIDR blocks allowed to access the Kubernetes API (port 6443). Defaults to open for module usability; restrict in production."

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



variable "health_check_urls" {
  type        = list(string)
  default     = []
  description = <<-EOT
    HTTP(S) URLs to check after cluster operations (upgrade, restore).
    Each URL must return 2xx/3xx to pass. Empty list skips HTTP checks.
    For OpenEdx: ["https://yourdomain.com/heartbeat"]
    The /heartbeat endpoint validates MySQL, MongoDB, and app availability.
  EOT
}
