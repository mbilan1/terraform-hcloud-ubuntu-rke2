# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| `main` branch | :white_check_mark: |
| `v0.x.x` tags | :white_check_mark: (best effort) |

This module is **experimental** and not yet production-ready.
Security issues are taken seriously regardless of maturity status.

## Reporting a Vulnerability

**Do NOT open a public GitHub issue for security vulnerabilities.**

Instead, please report vulnerabilities via one of these channels:

1. **GitHub Security Advisories** (preferred):
   [Report a vulnerability](https://github.com/mbilan1/terraform-hcloud-ubuntu-rke2/security/advisories/new)

2. **Email**: Contact the maintainer directly (see GitHub profile).

### What to include

- Description of the vulnerability
- Steps to reproduce (if applicable)
- Affected files or components
- Potential impact assessment

### Response timeline

- **Acknowledgment**: within 72 hours
- **Initial assessment**: within 1 week
- **Fix or mitigation**: best effort, depending on severity

### Scope

The following are in scope for security reports:

- Secrets or credentials exposed in code, outputs, or state
- Insecure default configurations (overly permissive firewall rules, etc.)
- Cloud-init scripts that could be exploited
- Supply chain risks (compromised dependencies, unsigned actions)

The following are **out of scope**:

- Hetzner Cloud platform vulnerabilities (report to Hetzner)
- RKE2 / Kubernetes vulnerabilities (report upstream)
- Helm chart vulnerabilities in `charts/` (reference configs, not production manifests)

## Security Measures in This Module

- **SAST scanning**: Checkov, KICS, tfsec run on every push
- **Secrets detection**: gitleaks in CI + `detect-private-key` in pre-commit
- **Action pinning**: All GitHub Actions pinned to full SHA
- **Sensitive outputs**: Marked with `sensitive = true`
- **State security**: E2E workflow shreds state files in `always()` cleanup
- **Least privilege**: CI workflows use `permissions: contents: read`
