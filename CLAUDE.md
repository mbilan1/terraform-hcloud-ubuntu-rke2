# CLAUDE.md

> Quick-reference guide for Claude Code working on `terraform-hcloud-rke2`.
> For full AI agent rules and verification workflows, read [AGENTS.md](AGENTS.md).
> For architecture and design rationale, read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## What This Is

An **OpenTofu/Terraform module** (NOT a root deployment) that provisions a production-oriented **RKE2 Kubernetes cluster on Hetzner Cloud** with optional Open edX (openedx-k8s-harmony) integration.

- **IaC tool**: OpenTofu >= 1.5 — always use `tofu`, **never** `terraform`
- **Cloud**: Hetzner Cloud (EU — Helsinki, Nuremberg, Falkenstein)
- **K8s**: RKE2 v1.34.4 (pinned by default)
- **OS**: Ubuntu 24.04 LTS
- **DNS**: AWS Route53 (temporary)
- **Status**: Experimental, not production-ready

## Critical Constraints

1. **Root directory is a reusable module** — it has no backend, no tfvars, no state file
2. **NEVER run `tofu plan/apply/destroy` in root** — only inside `examples/` with credentials
3. **NEVER run `tofu init -upgrade`** — silently changes provider versions in lockfile
4. **NEVER edit inside `<!-- BEGIN_TF_DOCS -->` / `<!-- END_TF_DOCS -->` markers in README.md**
5. **NEVER commit secrets, tokens, or private keys**
6. **A question is NOT a request to change code** — answer first, wait for explicit approval
7. **Verify external claims via network** before recommending version/provider changes (see AGENTS.md Verification Rules)

## Safe Commands (run without asking)

```bash
tofu init                 # Initialize providers (safe, idempotent)
tofu validate             # Syntax check, no side effects
tofu fmt -check           # Check formatting (tofu fmt to auto-fix)
tofu test                 # All 63 unit tests (~3s, $0, mock_provider)
tofu test -filter=tests/variables.tftest.hcl       # 23 variable validation tests
tofu test -filter=tests/guardrails.tftest.hcl      # 16 cross-variable checks
tofu test -filter=tests/conditional_logic.tftest.hcl  # 22 feature toggle tests
tofu test -filter=tests/examples.tftest.hcl        # 2 example pattern tests
```

## Dangerous Commands (require explicit user approval)

```bash
tofu plan        # Only in examples/, requires cloud credentials
tofu apply       # Provisions real infrastructure, costs money
tofu destroy     # Destroys infrastructure
tofu init -upgrade  # Changes provider versions in lockfile
```

## Repository Structure

```
/                           Root module (reusable, NOT a deployment)
├── main.tf                 Server resources (masters, workers), cloud-init, provisioners
├── providers.tf            12+ provider configurations with version constraints
├── variables.tf            Input variables with validations (30+)
├── output.tf               Module outputs (kubeconfig, IPs, network details)
├── locals.tf               Computed values (kubeconfig parsing, HA detection)
├── data.tf                 Data sources (remote kubeconfig, HTTP CRD downloads)
├── guardrails.tf           Cross-variable consistency checks
├── network.tf              Hetzner private network + subnet
├── firewall.tf             Hetzner Cloud Firewall rules
├── ssh.tf                  Auto-generated RSA 4096 SSH key pair
├── load_balancer.tf        Dual LB architecture (control-plane + ingress)
├── dns.tf                  AWS Route53 wildcard DNS records
├── cluster-hccm.tf         Hetzner Cloud Controller Manager (always deployed)
├── cluster-csi.tf          Hetzner CSI driver (always deployed)
├── cluster-certmanager.tf  cert-manager + Let's Encrypt ClusterIssuer (always deployed)
├── cluster-harmony.tf      openedx-k8s-harmony chart (opt-in: harmony.enabled)
├── cluster-ingresscontroller.tf  RKE2 built-in ingress (when Harmony disabled)
├── cluster-selfmaintenance.tf    Kured + System Upgrade Controller (HA only, >=3 masters)
├── scripts/                Cloud-init templates (rke-master.sh.tpl, rke-worker.sh.tpl)
├── templates/              Kubernetes manifests and Helm values
├── docs/ARCHITECTURE.md    Design philosophy, topology, security model, compromise log
├── examples/               Deployment patterns (minimal/, openedx-tutor/, simple-setup/, rancher-setup/)
├── tests/                  Unit tests (63 total, all offline with mock_provider)
└── .github/workflows/      12 CI workflows (lint, SAST, unit, integration, e2e)
```

## Architecture Quick Reference

### Addon Deployment Order (do NOT reorder)

```
Infrastructure -> master-0 -> additional masters -> workers
  -> wait_for_api -> wait_for_cluster_ready
  -> fetch kubeconfig -> HCCM -> CSI -> cert-manager -> Harmony
```

### Key Design Decisions

- **Dual LBs**: Control-plane LB (masters, ports 6443/9345) + Ingress LB (workers, ports 80/443, only when Harmony enabled). Do NOT merge them.
- **DNS requires Harmony**: `create_dns_record=true` needs `harmony.enabled=true` (enforced in guardrails.tf)
- **master-0 is special**: Bootstraps cluster, has `prevent_destroy`, SSH provisioners connect to it
- **etcd quorum**: `master_node_count=2` is blocked (split-brain). Use 1 (dev) or 3+ (HA)
- **HA features** (Kured, System Upgrade Controller): Only deployed with 3+ masters
- **Providers inside module**: Known anti-pattern, extraction planned as breaking change

### Harmony vs Non-Harmony Modes

| Feature | `harmony.enabled = true` | `harmony.enabled = false` |
|---------|:---:|:---:|
| Harmony chart deployed | Yes | No |
| Ingress LB created | Yes | No |
| ingress-nginx source | Harmony (DaemonSet+hostPort) | RKE2 built-in |
| DNS record possible | Yes | No |

## Code Conventions

- **Formatting**: `tofu fmt` canonical style
- **Naming**: `snake_case` for variables; resources prefixed with `var.cluster_name`
- **Outputs**: `sensitive = true` for credentials
- **Comments**: Preserve existing comments; use structured prefixes:
  - `# COMPROMISE:` — deliberate trade-offs
  - `# WORKAROUND:` — upstream bugs/limitations (include `TODO: Remove when ...`)
  - `# DECISION:` — rationale over alternatives
  - `# NOTE:` — important non-obvious context
  - `# TODO:` — planned improvements

## Git Commit Convention

Conventional Commits format:

```
<type>(<scope>): <short summary>
```

- **Types**: `feat`, `fix`, `docs`, `refactor`, `chore`, `style`, `test`, `ci`
- **Scopes**: `harmony`, `dns`, `lb`, `firewall`, `csi`, `hccm`, `certmanager`, `examples`, `providers`
- Subject: imperative mood, lowercase, no period, max 72 chars
- Body: explain WHY, not WHAT

## CI Pipeline (12 workflows)

| Gate | Workflows | Trigger | Cost |
|:----:|-----------|---------|:----:|
| 0a | lint-fmt, lint-validate, lint-tflint | push + PR | $0 |
| 0b | sast-checkov, sast-kics, sast-tfsec | push + PR | $0 |
| 1 | unit-variables, unit-guardrails, unit-conditionals, unit-examples | push + PR | $0 |
| 2 | integration-plan (examples/minimal/) | PR + manual | $0 |
| 3 | e2e-apply (apply + smoke + destroy) | Manual only | ~$0.50 |

## After Making Changes

1. Run `tofu fmt` to fix formatting
2. Run `tofu validate` to check syntax
3. Run `tofu test` to verify all 63 unit tests pass
4. If you modified variables/guardrails/conditionals, confirm relevant test coverage exists
5. Commit using Conventional Commits format

## Required Providers (12)

hcloud (~>1.44), aws (>=5.0), kubectl (~>1.19, gavinbunney), kubernetes (>=2.23), helm (>=2.11), null (~>3.2), random (~>3.5), tls (~>4.0), local (~>2.4), http (~>3.4), remote (~>0.2, tenstad)

## Key Documentation

| Document | Purpose |
|----------|---------|
| [AGENTS.md](AGENTS.md) | Full AI agent rules, verification workflows, anti-bias guidelines, common mistakes |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Design philosophy, topology, security model, compromise log, roadmap |
| [tests/README.md](tests/README.md) | Test strategy, coverage traceability, mock provider workarounds |
| [README.md](README.md) | User-facing module documentation (auto-generated sections — do not edit markers) |
