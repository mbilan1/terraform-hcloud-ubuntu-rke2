# ──────────────────────────────────────────────────────────────────────────────
# Packer template for RKE2 base image (L1/L2)
#
# DECISION: Packer builds a golden image with pre-installed packages.
# Why: Reproducibility — every node starts from the same image regardless of
#      when it's provisioned. Also reduces cloud-init time by ~2-3 minutes
#      (no apt-get during bootstrap).
#
# NOTE: This is a scaffold. Actual Packer builds are out of scope for
#       Terraform module CI — they run separately (manually or via GitHub Actions).
# See: docs/ARCHITECTURE.md — L1/L2 Layers
# ──────────────────────────────────────────────────────────────────────────────

packer {
  required_plugins {
    hcloud = {
      version = ">= 1.6.0"
      source  = "github.com/hetznercloud/hcloud"
    }
    ansible = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

variable "hcloud_token" {
  description = "Hetzner Cloud API token with read/write access for creating build servers and snapshots."
  type        = string
  sensitive   = true
}

variable "base_image" {
  description = "Source OS image for the golden snapshot. Must be an Ubuntu LTS release supported by RKE2."
  type        = string
  default     = "ubuntu-24.04"

  validation {
    condition     = can(regex("^ubuntu-", var.base_image))
    error_message = "Only Ubuntu images are supported (e.g. 'ubuntu-24.04')."
  }
}

variable "server_type" {
  # NOTE: cx22 was renamed to cx23 by Hetzner in 2025. Verified via API 2025-06.
  description = "Hetzner server type used as the temporary build instance. A small shared-CPU type is sufficient since the image is just installing packages."
  type        = string
  default     = "cx23"
}

variable "location" {
  description = "Hetzner datacenter for the temporary build server. The resulting snapshot is location-independent."
  type        = string
  default     = "hel1"
}

variable "image_name" {
  description = "Base name for the resulting snapshot. A timestamp suffix is appended automatically (e.g. 'rke2-base-1706000000')."
  type        = string
  default     = "rke2-base"
}

variable "kubernetes_version" {
  description = "RKE2 release tag to pre-install into the image. Must match the Terraform module's var.kubernetes_version to avoid version drift at bootstrap time."
  type        = string
  default     = "v1.34.4+rke2r1"
}

variable "enable_cis_hardening" {
  description = "Enable CIS Level 1 hardening (UBUNTU24-CIS benchmark). When true, the Packer build applies OS hardening via the ansible-lockdown/UBUNTU24-CIS role, configures UFW with Kubernetes-specific allow rules, and sets AppArmor to enforce mode. Increases build time by ~5-6 minutes."
  type        = bool
  default     = false
}

source "hcloud" "rke2_base" {
  token       = var.hcloud_token
  image       = var.base_image
  location    = var.location
  server_type = var.server_type
  server_name = "packer-rke2-base"

  snapshot_name = "${var.image_name}-{{timestamp}}"
  snapshot_labels = {
    "managed-by" = "packer"
    "role"       = "rke2-base"
    "base-image" = var.base_image
    # NOTE: rke2-version label allows Terraform data source lookups like:
    # data "hcloud_image" "rke2" { with_selector = "rke2-version=v1.34.4-rke2r1" }
    # WORKAROUND: Replace '+' with '-' because Hetzner labels only allow [a-z0-9._-].
    # Why: RKE2 versions use '+' (e.g. v1.34.4+rke2r1) which is invalid in Hetzner labels.
    "rke2-version" = replace(var.kubernetes_version, "+", "-")
    # NOTE: cis-hardened label allows operators to filter hardened vs unhardened snapshots.
    # data "hcloud_image" "rke2" { with_selector = "cis-hardened=true" }
    "cis-hardened"  = var.enable_cis_hardening ? "true" : "false"
    "cis-benchmark" = var.enable_cis_hardening ? "UBUNTU24-CIS-v1.0.0-L1" : "none"
  }

  ssh_username = "root"
}

build {
  sources = ["source.hcloud.rke2_base"]

  # Upload Ansible files to the build instance so install-ansible.sh can find requirements.yml.
  # DECISION: Use file provisioner instead of ansible-local's galaxy_file parameter.
  # Why: galaxy_file only installs roles, not collections. We need both (community.general,
  #      ansible.posix) and the CIS role. The file provisioner + install-ansible.sh handles
  #      both via `ansible-galaxy collection install` and `ansible-galaxy role install`.
  # WORKAROUND: Create destination directory before upload.
  # Why: Packer file provisioner uses SCP which requires the target directory to exist.
  provisioner "shell" {
    inline = ["mkdir -p /tmp/packer-files/ansible"]
  }

  provisioner "file" {
    source      = "ansible/"
    destination = "/tmp/packer-files/ansible/"
  }

  # Install Ansible + Galaxy dependencies on the build instance
  provisioner "shell" {
    script = "scripts/install-ansible.sh"
  }

  # Write Ansible extra-vars JSON file with boolean overrides for ansible-core 2.20+.
  # WORKAROUND: Packer's extra_arguments mangles JSON with escaped quotes.
  # Why: ansible-core 2.20 enforces strict boolean typing on `when:` conditionals.
  #      key=value extra-vars pass strings — "false" is truthy in Python.
  #      Writing a JSON file and referencing it with @file avoids escaping issues.
  provisioner "shell" {
    inline = [
      "echo '{\"ubtu24cis_rule_5_4_2_5\": false}' > /tmp/ansible-overrides.json"
    ]
  }

  # Run Ansible playbook for system preparation and optional CIS hardening.
  # DECISION: Pass both kubernetes_version and enable_cis_hardening as extra-vars.
  # Why: kubernetes_version controls which RKE2 release is pre-installed (must match
  #      the Terraform module variable). enable_cis_hardening gates the CIS role
  #      inclusion in playbook.yml (see the `when:` condition on the cis-hardening role).
  provisioner "ansible-local" {
    playbook_file = "ansible/playbook.yml"
    role_paths = [
      "ansible/roles/rke2-base",
      "ansible/roles/cis-hardening",
    ]
    # WORKAROUND: Each extra-var must be passed as a separate --extra-vars flag.
    # Why: Packer's extra_arguments array does not preserve spaces within a single
    #      element. "key1=val1 key2=val2" gets split into separate CLI arguments,
    #      causing ansible-playbook to error on the unrecognized second argument.
    extra_arguments = [
      "--extra-vars", "kubernetes_version=${var.kubernetes_version}",
      "--extra-vars", "enable_cis_hardening=${var.enable_cis_hardening}",
      # WORKAROUND: ansible-local provisioner does not set ansible_user automatically.
      # Why: In local connection mode, Ansible does not populate ansible_user like it
      #      does for SSH connections. The CIS role (UBUNTU24-CIS) references ansible_user
      #      in task 5.4.1.1 to check password expiration for the connecting user.
      #      Packer runs as root, so we explicitly set ansible_user=root.
      # TODO: Remove if upstream UBUNTU24-CIS makes ansible_user optional.
      "--extra-vars", "ansible_user=root",
      # WORKAROUND: Disable CIS rule 5.4.2.5 — upstream bug with ansible-core 2.20.
      # Why: The upstream task accesses item.stat.pw_name on stat results that may
      #      lack this attribute (symlinks / non-existent paths).
      #      JSON file with @-reference preserves boolean types and avoids Packer escaping.
      # TODO: Remove when upstream UBUNTU24-CIS fixes cis_5.4.2.x.yml:163.
      "--extra-vars", "@/tmp/ansible-overrides.json",
    ]
  }

  # Clean up for snapshot
  provisioner "shell" {
    inline = [
      "apt-get clean",
      "rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*",
      "cloud-init clean --logs --seed",
      "sync",
    ]
  }
}
