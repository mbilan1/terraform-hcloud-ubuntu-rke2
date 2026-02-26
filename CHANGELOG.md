# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project is experimental and does not yet follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- `SECURITY.md` — responsible disclosure policy
- `CODEOWNERS` — code ownership for PR notifications
- PR template with checklist for CI gates
- gitleaks secrets scanning in CI pipeline
- Provider caching in CI workflows (`actions/cache`)
- `CHANGELOG.md` (this file)
- **Packer CIS hardening flow** — opt-in CIS Level 1 hardening via `enable_cis_hardening` feature flag
  - `ansible-lockdown/UBUNTU24-CIS` role (v1.0.4, CIS Ubuntu 24.04 Benchmark v1.0.0)
  - UFW firewall with Kubernetes-specific allow rules (defense-in-depth alongside Hetzner Cloud Firewall)
  - AppArmor enforce mode, SSH hardening, file permission controls
  - `cis-hardening` wrapper role with RKE2-safe variable overrides
  - Ansible Galaxy `requirements.yml` for dependency management
  - Snapshot labels: `cis-hardened`, `cis-benchmark` for image identification
  - `/etc/cis-hardening-applied` marker file for runtime verification

### Changed
- tfsec workflow: changed from soft-fail (decorative) to hard-fail (blocking gate)

## [0.1.0] — 2026-02-24

### Added
- Initial release of the `terraform-hcloud-rke2` module
- RKE2 Kubernetes cluster on Hetzner Cloud (Ubuntu 24.04 LTS)
- Dual load balancer architecture (control-plane + ingress)
- Cloud-init based server bootstrap (zero shell provisioners for setup)
- ED25519 SSH key auto-generation
- Hetzner private network + subnet
- Hetzner Cloud Firewall with configurable CIDR restrictions
- Optional AWS Route53 wildcard DNS record
- Optional openedx-k8s-harmony integration (ingress LB + RKE2 ingress disable)
- etcd S3 backup configuration via cloud-init
- Configurable CNI plugin (canal, calico, cilium, none)
- Per-node location control (`master_node_locations`, `worker_node_locations`)
- `enforce_single_country_workers` guardrail for storage latency
- 57 unit tests via `tofu test` with `mock_provider` ($0, ~3s)
- 12 CI workflows (lint, SAST, unit, integration, E2E)
- Helmfile-based addon deployment (`charts/` directory)
- Pre-commit hooks (terraform-docs, detect-private-key)
- Dependabot for provider and action updates
- REUSE 3.3 license compliance
- Comprehensive ARCHITECTURE.md with 5 Mermaid diagrams
- AGENTS.md for AI coding assistant guidance

### Architecture
- **L3/L4 separation**: Infrastructure (Terraform) decoupled from addons (Helmfile)
- **Root module = shim**: Zero resources, only `module.infrastructure` call
- **67 `moved` blocks** for zero-downtime migration from flat to modular structure
- **Providers configured in root only** — child module declares but doesn't configure

[Unreleased]: https://github.com/mbilan1/terraform-hcloud-ubuntu-rke2/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/mbilan1/terraform-hcloud-ubuntu-rke2/releases/tag/v0.1.0
