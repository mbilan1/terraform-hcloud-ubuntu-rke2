# Packer — RKE2 Base Image Builder

Builds a golden Hetzner Cloud snapshot with pre-installed packages and hardened kernel settings for RKE2 nodes. Optionally applies **CIS Level 1 hardening** (Ubuntu 24.04 CIS Benchmark v1.0.0) via the [ansible-lockdown/UBUNTU24-CIS](https://github.com/ansible-lockdown/UBUNTU24-CIS) role.

## What Gets Pre-installed (Always)

- **open-iscsi** — Longhorn prerequisite
- **nfs-common** — Longhorn NFS backup support
- **curl, jq** — RKE2 installer and health checks
- **Kernel modules** — `iscsi_tcp`, `br_netfilter`, `overlay`
- **sysctl tuning** — IP forwarding, bridge-nf-call, inotify limits
- **RKE2 binaries** — server + agent pre-downloaded (skips ~2-3 min curl at boot)

## CIS Hardening (Optional)

When `enable_cis_hardening=true`, the build additionally applies:

- **CIS Level 1** controls from the UBUNTU24-CIS benchmark v1.0.0
- **AppArmor** in enforce mode (required for Open edX codejail) — see [AppArmor Architecture](#apparmor-architecture) below
- **SSH hardening** — max auth tries, grace time, FIPS ciphers
- **Warning banner** on login
- **File permissions** hardening (excluding Kubernetes runtime paths)
- **Host firewall disabled** — CIS Section 4 (UFW/nftables) is disabled; Hetzner Cloud Firewall provides L3/L4 filtering at the hypervisor level as a compensating control

### What's Excluded and Why

| CIS Control | Reason for Exclusion |
|-------------|---------------------|
| Level 2 (auditd, AIDE) | May conflict with containerd/kubelet; planned for incremental addition |
| Section 4 (host firewall) | UFW/nftables disabled — Hetzner Cloud Firewall is the compensating control. Host-level iptables-nft backend conflicts with Kubernetes CNI rules. |
| GDM/desktop controls (1.7.x) | Headless servers — no GUI present |
| IPv6 disable (3.1.1) | Hetzner cloud-init requires IPv6 for eth0 route configuration (via: fe80::1). Disabling breaks networking entirely. |
| NetworkManager (3.1.2) | Hetzner uses netplan/systemd-networkd; NM conflicts with network autoconfiguration |
| Bootloader password | Hetzner Cloud VPS has no physical console |
| SUID bit removal (7.1.13) | Some K8s components require SUID |
| SSH PermitRootLogin (5.2.x) | CIS hardens SSH to deny root login, but RKE2 bootstrap **requires** `PermitRootLogin prohibit-password` for Terraform SSH provisioners (kubeconfig fetch, readiness checks). Cloud-init scripts override this at boot time. See `modules/infrastructure/scripts/rke-master.sh.tpl` and `rke-worker.sh.tpl`. |

### UFW + Kubernetes Port Matrix

> **Note:** CIS Section 4 (host-level firewall) is **disabled** in the current configuration. Hetzner Cloud Firewall handles all L3/L4 filtering at the hypervisor level. The port matrix below is kept as documentation for the Hetzner Cloud Firewall rules (see `modules/infrastructure/firewall.tf`).

| Port | Protocol | Purpose |
|------|----------|---------|
| 22 | TCP | SSH (Terraform provisioners, operator access) |
| 80 | TCP | HTTP ingress |
| 443 | TCP | HTTPS ingress |
| 6443 | TCP | Kubernetes API server |
| 9345 | TCP | RKE2 node registration |
| 2379-2380 | TCP | etcd peer communication |
| 10250 | TCP | kubelet API |
| 8472 | UDP | VXLAN overlay (Canal/Flannel) |
| 51820 | UDP | WireGuard (Calico option) |
| 30000-32767 | TCP+UDP | NodePort range |
| 10.0.0.0/16 | all | Private network (unrestricted inter-node) |

### AppArmor Architecture

AppArmor is enabled in **enforce mode globally** (CIS rule 1.3.1.4). To ensure Kubernetes compatibility, the CIS hardening wrapper applies a targeted exception for container-runtime profiles:

| Profile Category | Profiles | Mode | Rationale |
|-----------------|----------|------|-----------|
| **System** (~114) | sshd, cron, man_groff, snap-update-ns, lsb_release, etc. | **enforce** | CIS compliance, host protection |
| **Container-runtime** (6) | busybox, crun, runc, buildah, ch-run, ch-checkns | **complain** | These collide with K8s init-containers (e.g. Cilium uses busybox). Complain mode logs but does not block. |
| **CRI containerd** (1) | `cri-containerd.apparmor.d` | **enforce** | Applied by containerd to ALL K8s pods — this is the actual container confinement layer |

**Why complain mode for container-runtime profiles?**

CIS rule 1.3.1.4 runs `aa-enforce` on ALL loaded profiles, including `busybox`. Kubernetes init-containers that use a `busybox` base image trigger the host-level `busybox` AppArmor profile, which blocks library access (`libcrypt.so.1`). This causes Cilium CNI pods to crash (`Init:CrashLoopBackOff`). The `cri-containerd.apparmor.d` profile — which stays enforce — is the correct confinement boundary for K8s containers.

**Open edX codejail:** AppArmor enforce mode on the node is a prerequisite for the [codejail](https://github.com/openedx/codejail) plugin, which sandboxes student code execution. A custom `openedx-codejail` AppArmor profile (installed at node level, referenced from pod spec annotations) is planned but not yet implemented.

## Usage

```bash
# Set your Hetzner Cloud API token
export PKR_VAR_hcloud_token="your-token-here"

# Initialize Packer plugins
packer init rke2-base.pkr.hcl

# ──────────────────────────────────────────────────────────────────────
# Standard image (no CIS hardening) — ~5 min build time
# ──────────────────────────────────────────────────────────────────────
packer build rke2-base.pkr.hcl

# ──────────────────────────────────────────────────────────────────────
# CIS-hardened image — ~10 min build time
# ──────────────────────────────────────────────────────────────────────
packer build -var enable_cis_hardening=true rke2-base.pkr.hcl

# Custom base image or location
packer build -var base_image=ubuntu-24.04 -var location=nbg1 rke2-base.pkr.hcl
```

## After Building

Reference the snapshot in your Terraform deployment:

```hcl
module "rke2" {
  source = "../../"  # or git reference

  master_node_image = "rke2-base-1234567890"  # snapshot name
  worker_node_image = "rke2-base-1234567890"  # same image for both roles
  # ...
}
```

### Verifying CIS Hardening

After deploying with a hardened image:

```bash
# Check that CIS hardening was applied at build time
ssh root@<node> cat /etc/cis-hardening-applied

# Check UFW status
ssh root@<node> ufw status verbose

# Check AppArmor status
ssh root@<node> apparmor_status

# Verify container-runtime profiles are in complain mode
ssh root@<node> aa-status | grep -A5 'complain'

# Check snapshot labels (from your workstation)
hcloud image list -l cis-hardened=true
```

## Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `hcloud_token` | — (required) | Hetzner Cloud API token |
| `base_image` | `ubuntu-24.04` | Source OS image |
| `server_type` | `cx22` | Temporary build server type |
| `location` | `hel1` | Build server datacenter |
| `image_name` | `rke2-base` | Snapshot name prefix |
| `kubernetes_version` | `v1.34.4+rke2r1` | RKE2 version to pre-install |
| `enable_cis_hardening` | `false` | Apply CIS Level 1 hardening |

## Snapshot Labels

Each snapshot includes metadata labels for filtering:

| Label | Example Value | Description |
|-------|---------------|-------------|
| `managed-by` | `packer` | Build tool identifier |
| `role` | `rke2-base` | Image role |
| `base-image` | `ubuntu-24.04` | Source OS |
| `rke2-version` | `v1.34.4+rke2r1` | Pre-installed RKE2 version |
| `cis-hardened` | `true` / `false` | Whether CIS hardening was applied |
| `cis-benchmark` | `UBUNTU24-CIS-v1.0.0-L1` | CIS benchmark reference (or `none`) |

## Directory Structure

```
packer/
├── rke2-base.pkr.hcl              # Packer template (HCL2)
├── scripts/
│   └── install-ansible.sh          # Bootstrap Ansible + Galaxy deps
├── ansible/
│   ├── playbook.yml                # Main playbook (rke2-base + optional CIS)
│   ├── requirements.yml            # Galaxy dependencies (CIS role, collections)
│   └── roles/
│       ├── rke2-base/              # Always: packages, kernel, RKE2 binaries
│       │   ├── defaults/main.yml
│       │   └── tasks/main.yml
│       └── cis-hardening/          # Optional: CIS Level 1 wrapper
│           ├── defaults/main.yml   # RKE2-safe CIS variable overrides
│           ├── vars/main.yml       # Critical overrides (Ansible precedence 16)
│           └── tasks/main.yml      # CIS role + post-CIS safety tasks
└── README.md                       # This file
```
