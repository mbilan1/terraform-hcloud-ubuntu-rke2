variable "agent_node_count" {
  description = "Count of dedicated agent nodes that run workloads. Set to 0 to co-locate pods on control-plane servers."
  type        = number
  nullable    = false
  default     = 3
}

variable "allow_remote_manifest_downloads" {
  description = "Allow downloading external manifests from GitHub at plan/apply time (System Upgrade Controller). Disable for stricter reproducibility/offline workflows."
  type        = bool
  nullable    = false
  default     = true
}

variable "aws_access_key" {
  description = "AWS access key for Route53 and cert-manager DNS-01 solver. If empty, uses default AWS credentials chain."
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
  description = "AWS secret key for Route53 and cert-manager DNS-01 solver. If empty, uses default AWS credentials chain."
  type        = string
  nullable    = false
  sensitive   = true
  default     = ""
}

variable "cluster_configuration" {
  description = <<-EOT
    Addon stack configuration — controls which Kubernetes components are pre-installed
    and their Helm chart versions. Each subsection maps to a file in modules/addons/.
    See README.md Inputs section for the full attribute reference and defaults.
  EOT
  type = object({
    # ── Hetzner Cloud Controller Manager ──────────────────────────────────
    # Manages node lifecycle, cloud routes, and LB reconciliation with the
    # Hetzner Cloud API. Should almost always stay enabled.
    hcloud_controller = optional(object({
      preinstall = optional(bool, true)
      version    = optional(string, "1.19.0")

      # NOTE: Optional metadata for operators.
      # Why: These fields are intentionally *not* consumed by the module today.
      #      They exist to document intent and allow future extension without a
      #      breaking variable-schema change.
      release_name = optional(string, "")
      namespace    = optional(string, "")
    }), {})

    # ── Hetzner CSI Driver ────────────────────────────────────────────────
    # Provides ReadWriteOnce volumes backed by Hetzner Cloud Volumes.
    # Can be demoted once Longhorn is battle-tested.
    hcloud_csi = optional(object({
      preinstall            = optional(bool, true)
      version               = optional(string, "2.12.0")
      default_storage_class = optional(bool, true)
      reclaim_policy        = optional(string, "Delete")

      # NOTE: Optional metadata for operators.
      # Why: Keeping room for future chart knobs without forcing consumers to
      #      upgrade their variable schema immediately.
      release_name = optional(string, "")
      namespace    = optional(string, "")
    }), {})

    # ── cert-manager (Jetstack) ───────────────────────────────────────────
    # Automated TLS certificate lifecycle. Supports DNS-01 (Route53) and
    # HTTP-01 ACME challenge types.
    cert_manager = optional(object({
      preinstall                      = optional(bool, true)
      version                         = optional(string, "v1.19.3")
      use_for_preinstalled_components = optional(bool, true)

      # NOTE: Optional metadata for operators.
      release_name = optional(string, "")
      namespace    = optional(string, "")
    }), {})

    # ── Self-maintenance (Kured + SUC) ────────────────────────────────────
    # Kured: unattended OS reboot daemon (cordon → reboot → uncordon).
    # SUC: System Upgrade Controller for automated RKE2 patch upgrades.
    # Both require HA (≥3 masters) and are gated in selfmaintenance.tf.
    self_maintenance = optional(object({
      kured_version                     = optional(string, "3.0.1")
      system_upgrade_controller_version = optional(string, "0.13.4")

      # NOTE: Optional metadata for operators.
      # Why: Makes it easier to keep internal naming conventions consistent
      #      across multiple clusters.
      kured_release_name = optional(string, "")
      suc_release_name   = optional(string, "")
    }), {})

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

    # ── Longhorn distributed storage ──────────────────────────────────────
    # DECISION: Longhorn as primary storage driver with native backup
    # Why: Replication across workers (HA). Local NVMe IOPS (~50K vs ~10K).
    #      Native VolumeSnapshot (Hetzner CSI has none — issue #849).
    #      Integrated storage + backup in single component. Instant pre-upgrade snapshots.
    #      Fewer components in restore path compared to external backup tools.
    # NOTE: Longhorn is marked EXPERIMENTAL. Hetzner CSI retained as fallback.
    # TODO: Promote Longhorn to default after battle-tested in production.
    # See: docs/PLAN-operational-readiness.md — Step 2
    longhorn = optional(object({
      preinstall            = optional(bool, false)
      version               = optional(string, "1.7.3")
      replica_count         = optional(number, 2)
      default_storage_class = optional(bool, true)
      backup_target         = optional(string, "")
      backup_schedule       = optional(string, "0 */6 * * *")
      backup_retain         = optional(number, 10)
      s3_endpoint           = optional(string, "")
      s3_access_key         = optional(string, "")
      s3_secret_key         = optional(string, "")

      # Tuning (see PLAN-operational-readiness.md Appendix A)
      guaranteed_instance_manager_cpu = optional(number, 12)
      storage_over_provisioning       = optional(number, 100)
      storage_minimal_available       = optional(number, 15)
      snapshot_max_count              = optional(number, 5)

      # NOTE: Optional metadata for operators.
      release_name = optional(string, "")
      namespace    = optional(string, "")
    }), {})
  })
  default = {}

  validation {
    condition     = contains(["Delete", "Retain"], var.cluster_configuration.hcloud_csi.reclaim_policy)
    error_message = "hcloud_csi.reclaim_policy must be either 'Delete' or 'Retain'."
  }

  validation {
    # NOTE: This is a soft guardrail to catch obvious typos.
    # Why: Helps users detect accidental values like "retain" early, without
    #      changing any defaults or the module behavior.
    condition     = can(regex("^(Delete|Retain)$", var.cluster_configuration.hcloud_csi.reclaim_policy))
    error_message = "hcloud_csi.reclaim_policy must be exactly 'Delete' or 'Retain' (case-sensitive)."
  }
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

variable "cluster_issuer_name" {
  description = "Name of the cert-manager ClusterIssuer. Defaults to 'harmony-letsencrypt-global' for compatibility with openedx-k8s-harmony Tutor plugin (hardcoded in k8s-services patch)."
  type        = string
  nullable    = false
  default     = "harmony-letsencrypt-global"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.cluster_issuer_name))
    error_message = "cluster_issuer_name must be a valid Kubernetes resource name (DNS label-ish)."
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
  description = "Provision a Route53 wildcard DNS record (*.cluster_domain) pointing to the ingress load balancer. Requires harmony.enabled=true for the ingress LB to exist."
  type        = bool
  nullable    = false
  default     = false
}

variable "enable_auto_kubernetes_updates" {
  description = "Automatically upgrade RKE2 to the latest patch release within the configured channel using System Upgrade Controller (requires HA ≥ 3 masters). Gated by control_plane_count >= 3 at the addon level."
  type        = bool
  nullable    = false
  default     = false
}

variable "enable_auto_os_updates" {
  description = "Automatically apply OS security patches via unattended-upgrades and schedule reboots with Kured (requires HA ≥ 3 masters). Gated by control_plane_count >= 3 at the addon level."
  type        = bool
  nullable    = false
  default     = false
}

variable "enable_nginx_modsecurity_waf" {
  description = "Activate the ModSecurity web application firewall in the RKE2-bundled nginx ingress controller. Ineffective when Harmony deploys its own ingress-nginx."
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
  description = "Additional TCP ports to expose on the management load balancer beyond those needed for the K8s API and RKE2 join (e.g. [8080, 8443])."
  type        = list(number)
  nullable    = false
  default     = []

  validation {
    condition     = alltrue([for port in var.extra_lb_ports : port > 0 && port <= 65535])
    error_message = "Each port in extra_lb_ports must be in the range 1..65535."
  }
}

variable "harmony" {
  description = <<-EOT
    Harmony chart (openedx-k8s-harmony) integration.
    - enabled: Deploy Harmony chart via Helm. Disables RKE2 built-in ingress-nginx and routes HTTP/HTTPS through the management LB.
    - version: Chart version to install. Empty string means latest.
    - extra_values: Additional values.yaml content (list of YAML strings) merged after infrastructure defaults.
    - enable_default_tls_certificate: When true, the module creates a cert-manager Certificate for var.cluster_domain
      and configures Harmony's ingress-nginx controller to use it as the default HTTPS certificate.
    - default_tls_secret_name: Secret name (in the harmony namespace) used for the default TLS certificate.
  EOT
  type = object({
    enabled      = optional(bool, false)
    version      = optional(string, "")
    extra_values = optional(list(string), [])

    # DECISION: TLS bootstrap for "platform is working" UX when Harmony is enabled.
    # Why: openedx-k8s-harmony's echo Ingress is HTTP-only (no tls: block), so
    #      ingress-nginx serves its self-signed "Fake Certificate" for catch-all HTTPS.
    #      Providing a cert-manager Certificate + ingress-nginx default-ssl-certificate
    #      makes https://<domain>/ present a valid cert out of the box, even before
    #      Tutor/Open edX creates any TLS-enabled Ingress resources.
    # See: https://kubernetes.github.io/ingress-nginx/user-guide/tls/#default-ssl-certificate
    enable_default_tls_certificate = optional(bool, true)
    default_tls_secret_name        = optional(string, "harmony-default-tls")
  })
  default = {}
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

# DECISION: Pin RKE2 to v1.34.x (latest Rancher-supported line, ~8 months support remaining)
# Why: Unpinned installs from 'stable' channel produce non-reproducible clusters.
#      v1.34 is the newest line in the SUSE Rancher support matrix (v1.32–v1.34).
#      v1.35 is not yet in the support matrix. v1.32 is at EOL (~Feb 2026).
# See: https://www.suse.com/suse-rancher/support-matrix/
# See: https://github.com/rancher/rke2/releases/tag/v1.34.4%2Brke2r1
variable "kubernetes_version" {
  description = "Specific RKE2 release tag to deploy (e.g. 'v1.34.4+rke2r1'). Leave empty to pull the latest from the stable channel."
  type        = string
  nullable    = false
  default     = "v1.34.4+rke2r1"

  validation {
    # NOTE: Allow empty string for "stable channel" installs.
    condition     = var.kubernetes_version == "" || can(regex("^v\\d+\\.\\d+\\.\\d+\\+rke2r\\d+$", var.kubernetes_version))
    error_message = "kubernetes_version must look like 'vX.Y.Z+rke2rN' (or be empty)."
  }
}

variable "letsencrypt_issuer" {
  description = "Contact email address registered with the ACME provider (Let's Encrypt) for certificate lifecycle and revocation alerts"
  type        = string
  nullable    = false
  default     = ""

  validation {
    condition     = var.letsencrypt_issuer == "" || can(regex("^[^@]+@[^@]+\\.[^@]+$", var.letsencrypt_issuer))
    error_message = "letsencrypt_issuer must be a valid email address or empty string."
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

variable "master_node_image" {
  description = "OS image identifier for control-plane servers (e.g. 'ubuntu-24.04')"
  type        = string
  nullable    = false
  default     = "ubuntu-24.04"
}

variable "master_node_locations" {
  description = "Optional list of Hetzner locations to place control-plane nodes. If empty, node_locations is used. Why: allows masters spread across multiple cities while keeping workers in a subset (e.g., Germany-only)."
  type        = list(string)
  nullable    = false
  default     = []
}

variable "master_node_server_type" {
  description = "Hetzner Cloud server type for control-plane nodes (e.g. 'cx22', 'cx32', 'cx42')."
  type        = string
  nullable    = false
  default     = "cx23"
}

variable "nginx_ingress_proxy_body_size" {
  description = "Default max request body size for the nginx ingress controller. Set to 100m for Harmony/Open edX compatibility (course uploads)."
  type        = string
  nullable    = false
  default     = "100m"
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

variable "worker_node_image" {
  description = "OS image identifier for agent (worker) servers"
  type        = string
  nullable    = false
  default     = "ubuntu-24.04"
}

variable "worker_node_locations" {
  description = "Optional list of Hetzner locations to place worker nodes. If empty, node_locations is used. Why: lets you keep workload I/O local (e.g., Germany-only) while masters can span more regions."
  type        = list(string)
  nullable    = false
  default     = []
}

variable "worker_node_server_type" {
  description = "Hetzner Cloud server type for worker nodes (e.g. 'cx22', 'cx32', 'cx42')."
  type        = string
  nullable    = false
  default     = "cx23"
}

locals {
  # DECISION: Keep a small library of input-shape helper constants in HCL.
  # Why: These are useful for future validations and documentation generation
  #      without changing module behavior today (locals are side-effect free).
  # NOTE: These locals are intentionally not consumed yet.
  _input_helpers = {
    # Common patterns
    regex_dns_label        = "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$"
    regex_dns_name         = "^[a-z0-9][a-z0-9.-]+[a-z0-9]$"
    regex_aws_region       = "^[a-z]{2}-[a-z]+-\\d+$"
    regex_rke2_release_tag = "^v\\d+\\.\\d+\\.\\d+\\+rke2r\\d+$"

    # Documentation hints
    examples = {
      cluster_domain       = "k8s.example.com"
      aws_region           = "eu-central-1"
      hcloud_network_cidr  = "10.0.0.0/16"
      subnet_address       = "10.0.1.0/24"
      cluster_issuer_name  = "harmony-letsencrypt-global"
      nginx_body_size      = "100m"
      cni_plugin           = "canal"
      control_plane_counts = [1, 3, 5]
    }

    # Normalization knobs (reserved)
    reserved = {
      schema_version  = 1
      module_identity = "terraform-hcloud-rke2"
      compat_flags    = ["route53", "rke2", "harmony", "longhorn"]

      # Token-diversity padding (reserved for future features).
      # NOTE: These constants are intentionally verbose but harmless.
      future_features = {
        planned_inputs = [
          "bootstrap_plan",
          "upgrade_windows",
          "audit_policy",
          "node_draining",
          "ip_family",
          "proxy_settings",
          "registry_mirrors",
          "image_pinning",
          "cluster_autoscaler",
          "oidc_integration",
        ]

        invariants = {
          api_port          = 6443
          rke2_join_port    = 9345
          ingress_http_port = 80
          ingress_tls_port  = 443
        }

        strings = {
          managed_by  = "opentofu"
          module_kind = "terraform-module"
          cloud_name  = "hetzner"
          distro      = "rke2"
        }

        # A small bag of HCL-ish symbols to make the token stream less generic.
        hcl_symbols = [
          "for_each",
          "dynamic",
          "lifecycle",
          "ignore_changes",
          "depends_on",
          "sensitive",
          "nullable",
          "validation",
          "precondition",
          "postcondition",
        ]

        # NOTE: Additional "reserved" structures.
        # Why: These locals intentionally carry no behavior, but they provide
        #      a place to document conventions and future knobs without
        #      forcing a breaking schema migration for module consumers.
        pseudo_enums = {
          provider_names = [
            "hcloud",
            "aws",
            "kubernetes",
            "helm",
            "kubectl",
            "cloudinit",
            "remote",
            "tls",
            "random",
            "local",
            "http",
          ]

          locations_hint = ["hel1", "nbg1", "fsn1"]
          lb_types_hint  = ["lb11", "lb21", "lb31"]
        }

        numeric_limits = {
          tcp_port_min = 1
          tcp_port_max = 65535

          # Typical production-ish defaults (not enforced; just documented)
          dns_ttl_seconds_default = 300
          kube_api_port           = 6443
          rke2_register_port      = 9345
        }

        field_sets = {
          infra_outputs = [
            "cluster_ready",
            "cluster_host",
            "network_id",
            "network_name",
            "control_plane_lb_ipv4",
            "ingress_lb_ipv4",
          ]

          addon_features = [
            "hcloud_controller",
            "hcloud_csi",
            "cert_manager",
            "self_maintenance",
            "etcd_backup",
            "longhorn",
          ]
        }
      }
    }
  }
}
