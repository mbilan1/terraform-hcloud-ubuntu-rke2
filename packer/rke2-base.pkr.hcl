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
  description = "Hetzner server type used as the temporary build instance. A small shared-CPU type is sufficient since the image is just installing packages."
  type        = string
  default     = "cx22"
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

source "hcloud" "rke2_base" {
  token       = var.hcloud_token
  image       = var.base_image
  location    = var.location
  server_type = var.server_type
  server_name = "packer-rke2-base"

  snapshot_name   = "${var.image_name}-{{timestamp}}"
  snapshot_labels = {
    "managed-by"   = "packer"
    "role"         = "rke2-base"
    "base-image"   = var.base_image
    # NOTE: rke2-version label allows Terraform data source lookups like:
    # data "hcloud_image" "rke2" { with_selector = "rke2-version=v1.34.4+rke2r1" }
    "rke2-version" = var.kubernetes_version
  }

  ssh_username = "root"
}

build {
  sources = ["source.hcloud.rke2_base"]

  # Install Ansible on the build instance
  provisioner "shell" {
    script = "scripts/install-ansible.sh"
  }

  # Run Ansible playbook for system hardening, package pre-installation, and RKE2 binary pre-install.
  # DECISION: Pass kubernetes_version as extra-var so the image version matches the Terraform module variable.
  # Why: Both must agree — if the image has v1.34 pre-installed but Terraform tries to install v1.35,
  #      the bootstrap script's idempotency check will skip the re-install, locking the version to
  #      what Packer baked in. Build a new image when upgrading.
  provisioner "ansible-local" {
    playbook_file = "ansible/playbook.yml"
    role_paths    = ["ansible/roles/rke2-base"]
    extra_vars    = "kubernetes_version=${var.kubernetes_version}"
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
