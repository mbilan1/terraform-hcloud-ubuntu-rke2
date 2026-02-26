# ──────────────────────────────────────────────────────────────────────────────
# VERSION REGISTRY — single reference for every versioned component
#
# DECISION: All version-related variables grouped in one file.
# Why: Scattered version defaults across variables.tf, providers.tf, and
#      charts/ are hard to audit, upgrade, and review. This file serves as
#      the cross-cutting index so operators can find and update ANY version
#      from a single starting point.
#
# ┌──────────────────────────────┬──────────────────────┬──────────────────────────────┐
# │ Component                    │ Version              │ Defined in                   │
# ├──────────────────────────────┼──────────────────────┼──────────────────────────────┤
# │ OpenTofu (runtime)           │ >= 1.7.0             │ providers.tf [L]             │
# │ RKE2 / Kubernetes            │ v1.34.4+rke2r1       │ var.kubernetes_version        │
# │ OS image (master)            │ ubuntu-24.04         │ var.master_node_image         │
# │ OS image (worker)            │ ubuntu-24.04         │ var.worker_node_image         │
# ├──────────────────────────────┼──────────────────────┼──────────────────────────────┤
# │ Provider: hcloud             │ 1.60.1               │ providers.tf [L]             │
# │ Provider: aws                │ 6.33.0               │ providers.tf [L]             │
# │ Provider: cloudinit          │ 2.3.7                │ providers.tf [L]             │
# │ Provider: remote (tenstad)   │ REMOVED              │ replaced by external         │
# │ Provider: external            │ 2.3.5                │ providers.tf [L]             │
# │ Provider: tls                │ 4.2.1                │ providers.tf [L]             │
# │ Provider: random             │ 3.8.1                │ providers.tf [L]             │
# │ Provider: local              │ 2.7.0                │ providers.tf [L]             │
# ├──────────────────────────────┼──────────────────────┼──────────────────────────────┤
# │ Helm: HCCM                   │ 1.30.1               │ charts/versions.yaml         │
# │ Helm: cert-manager           │ v1.19.4              │ charts/versions.yaml         │
# │ Helm: Longhorn               │ 1.11.0               │ charts/versions.yaml         │
# │ Helm: Kured                  │ 5.11.0               │ charts/versions.yaml         │
# │ Helm: Harmony                │ 0.10.0               │ charts/versions.yaml         │
# │ Helm: OpenBao (experimental) │ 0.25.6               │ charts/versions.yaml         │
# │ Component: SUC               │ 0.14.2               │ charts/versions.yaml         │
# │ Image: Alpine (iSCSI init)   │ 3.17                 │ charts/versions.yaml         │
# │ Image: Alpine (iSCSI sleep)  │ 3.19                 │ charts/versions.yaml         │
# ├──────────────────────────────┼──────────────────────┼──────────────────────────────┤
# │ Packer plugin: hcloud        │ >= 1.6.0             │ packer/*.pkr.hcl [L]         │
# │ Packer plugin: ansible       │ >= 1.1.0             │ packer/*.pkr.hcl [L]         │
# │ Ansible: UBUNTU24-CIS role   │ 1.0.4                │ packer/ansible/requirements  │
# │ Ansible: community.general   │ >= 9.0.0             │ packer/ansible/requirements  │
# │ Ansible: ansible.posix       │ >= 1.5.0             │ packer/ansible/requirements  │
# └──────────────────────────────┴──────────────────────┴──────────────────────────────┘
#
# [L] = string Literal — OpenTofu/Packer require these as literals in
#       required_providers / required_plugins blocks. Cannot be variables.
#       Update them directly in those files and keep this table in sync.
#
# NOTE: Packer variables (base_image, kubernetes_version) have their own
#       defaults in packer/rke2-base.pkr.hcl. Keep them aligned with the
#       Terraform defaults below to avoid version drift between golden
#       images and cloud-init bootstrap.
# ──────────────────────────────────────────────────────────────────────────────

# ── Kubernetes / RKE2 ────────────────────────────────────────────────────────

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

# ── OS Image ─────────────────────────────────────────────────────────────────

# DECISION: Separate master/worker image variables with shared default.
# Why: Operators may use different images (e.g. CIS-hardened Packer snapshot
#      for masters, stock Ubuntu for workers) while keeping a single default.

variable "master_node_image" {
  description = "OS image identifier for control-plane servers (e.g. 'ubuntu-24.04', or a Packer snapshot ID)"
  type        = string
  nullable    = false
  default     = "ubuntu-24.04"
}

variable "worker_node_image" {
  description = "OS image identifier for agent (worker) servers"
  type        = string
  nullable    = false
  default     = "ubuntu-24.04"
}
