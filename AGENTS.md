# AI Agent Instructions

> **READ THIS ENTIRE FILE before touching any code.**
> This file provides mandatory context for AI coding assistants (GitHub Copilot, Claude, Cursor, etc.)
> working with the `terraform-hcloud-rke2` module.

---

## ⚠️ MANDATORY: Read ARCHITECTURE.md First

**Before making ANY change**, read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) in full.

It contains:
- The complete dependency chain (addon deployment order)
- Dual load balancer design rationale
- DNS ↔ Harmony coupling rules
- Compromise Log with deliberate trade-offs
- Security model and known gaps
- Roadmap and out-of-scope boundaries

**If you skip ARCHITECTURE.md, you WILL break something.** Every design decision in this module has a documented rationale there. Do not assume you understand the architecture from file names alone.

---

## What This Repository Is

An **OpenTofu/Terraform module** (NOT a root deployment) that deploys a production-oriented **RKE2 Kubernetes cluster on Hetzner Cloud** with optional Open edX (openedx-k8s-harmony) integration.

- **IaC tool**: OpenTofu >= 1.7.0 — always use `tofu`, **never** `terraform`
- **Cloud provider**: Hetzner Cloud (EU data centers: Helsinki, Nuremberg, Falkenstein)
- **Kubernetes distribution**: RKE2 (Rancher Kubernetes Engine v2)
- **OS**: Ubuntu 24.04 LTS
- **DNS**: AWS Route53 (temporary solution)
- **Status**: Experimental — under active development, not production-ready

---

## Critical Rules

### NEVER do these — even if you think it helps:
1. **Do NOT run `tofu plan` in the root module** — the root is a reusable module, not a deployment. It has no backend, no variable values, and `plan` requires real cloud credentials. Run `plan` only inside `examples/` directories.
2. **Do NOT run `tofu apply`** — it provisions real cloud infrastructure and costs money
3. **Do NOT run `tofu destroy`** — it will destroy production resources
4. **Do NOT run `tofu init -upgrade`** — it modifies `.terraform.lock.hcl` and can change provider versions silently
5. **Do NOT change providers** (source or version constraints) in `providers.tf` without explicit user request AND live verification (see [Verification Rules](#verification-rules-mandatory))
6. **Do NOT modify `terraform.tfstate`** or `.terraform.lock.hcl` directly
7. **Do NOT commit secrets**, API keys, tokens, or private SSH keys
8. **Do NOT rewrite README.md** — it contains CI badges and auto-generated `terraform-docs` sections between markers. Editing outside the markers will break CI.
9. **Do NOT remove or modify the Compromise Log** in ARCHITECTURE.md without discussion
10. **A question is NOT a request to change code.** When the user asks "is X deprecated?", "should we change Y?", or "how does Z work?" — **answer the question**. Do not start editing files.

### ALWAYS do these:
1. **Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** before any structural change
2. **Run `tofu validate`** after any `.tf` file change to verify syntax
3. **Run `tofu fmt -check`** to verify formatting (or `tofu fmt` to auto-fix)
4. **Run `tofu test`** after any change to variables, guardrails, or conditional logic (57 tests, ~3s, $0)
5. **Preserve existing code comments** — they document deliberate compromises
6. **Read the relevant file before editing** — understand the dependency chain
7. **Verify external claims via network** before suggesting or making changes (see [Verification Rules](#verification-rules-mandatory))

### Where to run what

| Command | Root module (`/`) | `examples/*` directories |
|---------|:-:|:-:|
| `tofu validate` | ✅ Safe | ✅ Safe |
| `tofu fmt` | ✅ Safe | ✅ Safe |
| `tofu test` | ✅ Safe (uses mock_provider) | N/A |
| `tofu plan` | ❌ **Forbidden** | ✅ With credentials |
| `tofu apply` | ❌ **Forbidden** | ⚠️ Only with explicit user approval |
| `tofu destroy` | ❌ **Forbidden** | ⚠️ Only with explicit user approval |

### Safe commands (can run without asking):
- `tofu validate` — syntax check, no side effects
- `tofu fmt` / `tofu fmt -check` — formatting, no side effects
- `tofu test` — unit tests with mock_provider, no cloud credentials, ~3s
- `tofu test -filter=tests/<file>` — run a single test file
- `grep`, `cat`, `head`, `tail`, `wc` — read-only
- `git diff`, `git log`, `git status`, `git show` — read-only

### Dangerous commands (require explicit user approval):
- `tofu apply` — provisions infrastructure (even in examples/)
- `tofu destroy` — destroys infrastructure
- `tofu import` — modifies state
- `tofu state rm` — modifies state
- `tofu init -upgrade` — can change provider versions in lock file

---

## Verification Rules (MANDATORY)

> **Your training data is outdated. Never trust it for version numbers, deprecation status, or API compatibility.**

### Before recommending or making ANY change involving external dependencies:

1. **Providers** — check the **live** Terraform Registry or the provider's GitHub releases page:
   - Registry: `https://registry.terraform.io/providers/NAMESPACE/NAME/latest`
   - GitHub: `https://github.com/NAMESPACE/terraform-provider-NAME/releases`
   - Verify: latest version, changelog, breaking changes, deprecation notices

2. **Helm charts** — check the **live** chart repository or GitHub:
   - ArtifactHub: `https://artifacthub.io/packages/helm/REPO/CHART`
   - GitHub releases of the upstream project
   - Verify: latest version, `values.yaml` schema, breaking changes

3. **Kubernetes CRDs / APIs** — check the **live** upstream project:
   - GitHub releases page of the project (cert-manager, Istio, Gateway API, etc.)
   - Official documentation site
   - Verify: API version stability (v1alpha1 vs v1beta1 vs v1), deprecation timeline

4. **Hetzner Cloud API / resources** — check **live** Hetzner docs:
   - `https://docs.hetzner.cloud/`
   - Verify: server types, locations, LB types, API fields, pricing

5. **Variable defaults that reference cloud resources** (server types like `cx22`, locations like `hel1`, LB types like `lb11`) — verify they still exist on Hetzner's current offering via docs or API.

### Verification workflow:

```
1. User asks about or you notice a potential change
2. STOP — do NOT edit any file yet
3. Fetch the live source (Registry, GitHub releases, official docs)
4. Read the actual data (latest version, changelog, deprecation status)
5. PRESENT RAW FACTS FIRST in a structured comparison (see below)
6. ONLY THEN draw conclusions — and verify they match the facts
7. Report findings to the user WITH the source URL
8. Wait for user's explicit decision
9. Only then make the change if approved
```

### Structured comparison format (MANDATORY for any comparison):

When comparing two or more options (providers, charts, tools, approaches), you MUST present a **facts-first structured comparison** before drawing ANY conclusion:

```
| Criterion            | Option A              | Option B              |
|----------------------|-----------------------|-----------------------|
| Latest version       | v1.19.0               | v2.1.3                |
| Latest release date  | 2025-01-11            | 2024-11-06            |
| Downloads/week       | 1.1M                  | 478K                  |
| Open issues          | 77                    | 16                    |
| Source URL           | <actual link>         | <actual link>         |
```

**Then and only then** state your conclusion. Before writing the conclusion, re-read the table and ask yourself: **"Does my conclusion match every row of data?"** If your narrative contradicts even one fact, the narrative is wrong — rewrite it.

### Anti-bias rules (CRITICAL — read carefully):

> **The most dangerous error is not wrong data — it is correct data with a wrong conclusion driven by preconception.**

1. **Your training data creates biases.** You may "know" that project X is abandoned or tool Y is better. This "knowledge" is often outdated or wrong. Treat every prior belief as a hypothesis to be tested against live data, never as a fact.

2. **Facts first, narrative second.** Always present raw data (dates, versions, numbers) BEFORE any interpretation. Never construct a story and then cherry-pick data to support it.

3. **Compare dates as numbers.** When comparing recency: `2025-01-11 > 2024-11-06`. Period. No narrative about "development history" or "momentum" can override this arithmetic. The thing with the later date is newer.

4. **Do not confuse different qualities.** "More features" ≠ "more recent". "More commits" ≠ "better maintained". "Higher version number" ≠ "newer release". Compare apples to apples — each quality gets its own row in the comparison table.

5. **Re-read your own data before concluding.** After fetching live sources, re-read the actual dates and numbers you retrieved. Check: does your conclusion logically follow from this data? If you wrote "X is newer" but the dates show Y was released later — you are wrong. Fix it before reporting.

6. **If your conclusion feels "obvious" from training data, be extra suspicious.** The stronger your prior belief, the higher the risk of confirmation bias. When you catch yourself thinking "obviously X is better" — stop and triple-check the live data.

7. **Never reverse-engineer conclusions.** Do not decide the answer first and then look for supporting evidence. Instead: gather all evidence → organize it → let the conclusion emerge from the facts.

### If you cannot verify:
- **Say so explicitly**: "I cannot verify this claim — my training data suggests X, but I recommend checking [URL] before making changes."
- **Do NOT make the change** based on unverified assumptions
- **Do NOT say "based on my knowledge"** as if it were current fact

---

## Repository Structure

### This Is a Module, Not a Deployment

The root directory is a **reusable Terraform module**. It does NOT have:
- A backend configuration
- Variable values (no `terraform.tfvars`)
- A state file (any `terraform.tfstate` in root is accidental — it should be in `.gitignore`)

Actual deployments that **use** this module live in `examples/` or in separate repositories (like `abstract-k8s-common-template`).

### Root Terraform Files (Shim Layer)

The root module is a **thin shim** containing zero resources. It calls `module.infrastructure` and wires outputs:

| File | Purpose |
|------|---------||
| `main.tf` | `module "infrastructure"` call + locals for location fallback |
| `providers.tf` | Provider configurations (hcloud, aws, cloudinit, remote, tls, random, local) |
| `variables.tf` | All user-facing input variables with descriptions, types, defaults, validations |
| `output.tf` | Module outputs rewired to `module.infrastructure.*` |
| `guardrails.tf` | All preflight `check {}` blocks (DNS, Harmony, Longhorn, self-maintenance, etc.) |
| `moved.tf` | 67 `moved` + `removed` blocks for state migration from previous architecture |

### Child Modules

#### `modules/infrastructure/` — Cloud Resources + Cluster Bootstrap

| File | Purpose |
|------|---------|
| `main.tf` | Server resources (masters, workers), random strings/passwords |
| `cloudinit.tf` | `cloudinit_config` data sources for structured multipart cloud-init |
| `ssh.tf` | Auto-generated ED25519 SSH key pair |
| `network.tf` | Hetzner private network and subnet |
| `firewall.tf` | Hetzner Cloud Firewall rules |
| `load_balancer.tf` | Dual LB architecture (control-plane LB + ingress LB) |
| `dns.tf` | AWS Route53 DNS records (wildcard → ingress LB) |
| `readiness.tf` | `wait_for_api`, `wait_for_cluster_ready`, kubeconfig fetch, health checks |
| `locals.tf` | Kubeconfig parsing, etcd S3 endpoint |
| `variables.tf` | Infrastructure-specific inputs (subset of root variables) |
| `outputs.tf` | Kubeconfig credentials, IPs, network IDs, `cluster_ready` |
| `versions.tf` | `required_providers`: hcloud, cloudinit, remote, aws, random, tls, local |

Templates and scripts live **inside** the module: `modules/infrastructure/templates/cloudinit/`, `modules/infrastructure/scripts/`.

#### `charts/` — Kubernetes Addon Stack (Helmfile)

All Kubernetes addons are deployed via **Helmfile**, not via Terraform. This eliminates the chicken-and-egg problem of configuring kubernetes/helm providers inside the same Terraform apply that creates the cluster.

| Directory | Purpose |
|-----------|---------||
| `helmfile.yaml` | Addon deployment order, environment values, release definitions |
| `hccm/` | Hetzner Cloud Controller Manager (values + API token secret) |
| `cert-manager/` | cert-manager + ClusterIssuer (values + manifest) |
| `longhorn/` | Longhorn distributed storage (values + iSCSI installer) |
| `kured/` | Kured auto-reboot (values only) |
| `system-upgrade-controller/` | K8s version upgrades (manifests + SUC plans) |
| `harmony/` | openedx-k8s-harmony chart (values only) |
| `ingress/` | RKE2 built-in ingress config (HelmChartConfig manifest) |
| `README.md` | Operator guide for the Helmfile workflow |

### Other Directories

| Path | Purpose |
|------|---------|
| `packer/` | Machine image build scaffold (Packer + Ansible) — OS hardening, package pre-install |
| `charts/` | Kubernetes addon stack (Helmfile + per-addon values/manifests) — deployed OUTSIDE Terraform |
| `docs/` | Architecture docs (`ARCHITECTURE.md`, `PLAN-operational-readiness.md`) — **READ `ARCHITECTURE.md` BEFORE ANY WORK** |
| `examples/` | Example deployments (`simple-setup/`, `minimal/`, `openedx-tutor/`) |
| `tests/` | Unit test files (`*.tftest.hcl`) — see [tests/README.md](tests/README.md) |
| `.github/workflows/` | CI workflow files (12 workflows) — see below |

### CI Workflow Files (.github/workflows/)

All workflow files follow the naming convention `{category}-{tool}.yml`:

| File | Gate | Tool | Trigger |
|------|:----:|------|---------|
| `lint-fmt.yml` | 0a | `tofu fmt -check` | push + PR |
| `lint-validate.yml` | 0a | `tofu validate` | push + PR |
| `lint-tflint.yml` | 0a | `tflint` | push + PR |
| `sast-checkov.yml` | 0b | Checkov | push + PR |
| `sast-kics.yml` | 0b | KICS | push + PR |
| `sast-tfsec.yml` | 0b | tfsec | push + PR |
| `unit-variables.yml` | 1 | `tofu test -filter=tests/variables.tftest.hcl` | push + PR |
| `unit-guardrails.yml` | 1 | `tofu test -filter=tests/guardrails.tftest.hcl` | push + PR |
| `unit-conditionals.yml` | 1 | `tofu test -filter=tests/conditional_logic.tftest.hcl` | push + PR |
| `unit-examples.yml` | 1 | `tofu test -filter=tests/examples.tftest.hcl` | push + PR |
| `integration-plan.yml` | 2 | `tofu plan` (examples/minimal/) | PR + manual |
| `e2e-apply.yml` | 3 | `tofu apply` + smoke + `tofu destroy` | Manual only |

> **Trigger details**: Gates 0a/0b/1 run on **every push** (all branches) and on PRs targeting `main`. Gate 2 requires cloud credentials and runs only on PRs + manual dispatch. Gate 3 provisions real infrastructure and is manual-only with cost confirmation.

### Test Files (tests/)

| File | Tests | Scope |
|------|:-----:|-------|
| `variables.tftest.hcl` | 21 | Variable `validation {}` blocks (positive + negative) |
| `guardrails.tftest.hcl` | 13 | Cross-variable `check {}` blocks (incl. Longhorn guardrails) |
| `conditional_logic.tftest.hcl` | 17 | Resource count assertions for feature toggles |
| `firewall.tftest.hcl` | 4 | Firewall rule assertions (protocol, port, direction) |
| `examples.tftest.hcl` | 2 | Full-stack example configurations |
| **Total** | **57** | All tests use `mock_provider`, ~3s, $0 |

---

## Architecture Constraints (from ARCHITECTURE.md — read the full document)

### Dependency Chain
The infrastructure module (`modules/infrastructure/`) bootstraps the cluster and produces a kubeconfig. Kubernetes addons are then deployed separately via Helmfile (`charts/`):
```
module.infrastructure (Terraform): Network → Firewall → SSH → LBs → master-0
    → additional masters → workers → wait_for_api → wait_for_cluster_ready
    → kubeconfig fetch

charts/ (Helmfile, outside Terraform): HCCM → CSI → cert-manager → Longhorn → Harmony
```

**Do NOT move addon deployment back into Terraform** — the L3/L4 separation is a deliberate design choice.

### Module Structure Rules
- **Root module = shim** — contains zero resources, only the `module.infrastructure` call, provider configs, variables, guardrails, and `moved` blocks
- **All `check {}` blocks live in root `guardrails.tf`** — not in child modules (required for `tofu test` `expect_failures` addressing)
- **Templates and scripts live INSIDE the infrastructure module** — use `${path.module}/templates/` and `${path.module}/scripts/` in `templatefile()` calls
- **Providers configured in root only** — the child module declares `required_providers` but NOT `provider {}` blocks
- **`moved.tf`** — 67 blocks mapping old root addresses to `module.infrastructure.*` (plus `removed` blocks for deleted addon resources). Do NOT remove these until all known deployments have migrated.
- **`charts/`** — all Kubernetes addons deployed via Helmfile, not Terraform. Do NOT add kubernetes/helm/kubectl providers back to the module.

### Cloud-Init Architecture
- Server config (`config.yaml`) is written to disk via `cloudinit_config` `write_files` directive
- Shell scripts are minimal: detect IP → `sed` placeholder → curl install → systemctl start
- All conditional logic (etcd backup, ingress, secrets encryption) lives in config templates, NOT in shell scripts
- `cloudinit_config` data sources are in `modules/infrastructure/cloudinit.tf` (one per node role)
- Cloud-init lives in infrastructure module (not separate) to avoid circular dependency with LB IP and RKE2 token

### Dual Load Balancer Design
- **Control-plane LB**: targets masters only (ports 6443, 9345, optionally 22)
- **Ingress LB**: targets workers only (ports 80, 443) — **exists only when Harmony enabled**
- This is a deliberate design choice, not a mistake. Do NOT merge them.

### DNS ↔ Harmony Coupling
`create_dns_record = true` creates a Route53 wildcard pointing to the ingress LB.
The ingress LB exists **only when** `harmony_enabled = true`.
This is enforced by a preflight `check` in `guardrails.tf`.

### Harmony ↔ Ingress Exclusivity
When `harmony_enabled = true`:
- Harmony deploys its own ingress-nginx (DaemonSet + hostPort) via `charts/harmony/`
- RKE2 built-in ingress is disabled via HelmChartConfig (`charts/ingress/`)

When `harmony_enabled = false`:
- RKE2 built-in ingress is used

### master-0 Is Special
- `master-0` bootstraps the entire cluster
- It does **NOT** have `prevent_destroy` — full lifecycle management (including `tofu destroy`) is kept unblocked for dev/test. Production protection relies on branch protection, reviews, and targeted plans (see Compromise Log in ARCHITECTURE.md).
- `INITIAL_MASTER` flag in user_data is set at creation and never re-evaluated (`ignore_changes = [user_data]`)
- SSH provisioners connect to master-0 for kubeconfig retrieval and readiness checks

### Provider Constraints
- `hashicorp/cloudinit` provider is used for structured multipart cloud-init — do NOT replace with raw `templatefile()`
- `terraform_data` (built-in) replaces all former `null_resource` usage — no `hashicorp/null` dependency
- All 7 providers are declared **inside** the module (known anti-pattern, extraction planned as breaking change)
- Provider versions use `~>` pessimistic constraint — changing major versions is a breaking change
- Kubernetes-level providers (kubernetes, helm, kubectl) are **not used** — addons are deployed via Helmfile in `charts/`

---

## Code Style and Conventions

- **HCL formatting**: `tofu fmt` canonical style
- **Variable naming**: `snake_case` with descriptive names
- **Comments**: inline `#` comments document compromises and non-obvious decisions — preserve them
- **Helm values**: stored in `charts/*/values.yaml`, managed via Helmfile (not Terraform)
- **Variable blocks**: include `description`, `type`, `default` where applicable, `validation` blocks for constraints
- **Outputs**: use `sensitive = true` for any credential-type outputs
- **Resource naming**: prefixed with `var.cluster_name` for namespacing

### Git Commit Convention

All commits MUST follow **[Conventional Commits](https://www.conventionalcommits.org/)** format. Commit messages MUST be written in **English**.

```
<type>(<scope>): <short summary>

<optional body — explain WHY, not WHAT>

<optional footer — breaking changes, issue refs>
```

**Types** (use the most specific one):

| Type | When to use |
|------|-------------|
| `feat` | New feature or capability |
| `fix` | Bug fix |
| `docs` | Documentation only (AGENTS.md, ARCHITECTURE.md, README.md, examples/) |
| `refactor` | Code restructuring without behavior change |
| `chore` | Maintenance (CI, dependencies, tooling) |
| `style` | Formatting, whitespace (`tofu fmt`) |
| `test` | Adding or updating tests |
| `ci` | CI/CD pipeline changes |

**Scope** (optional, common values): `harmony`, `dns`, `monitoring`, `csi`, `hccm`, `certmanager`, `firewall`, `lb`, `examples`, `providers`

**Rules:**
- Subject line: imperative mood, lowercase, no period, max 72 chars
- Body: wrap at 72 chars, explain motivation and context
- Breaking changes: add `BREAKING CHANGE:` footer or `!` after type (e.g. `feat(providers)!: ...`)
- Reference issues when applicable: `Refs: #123`

**Examples:**
```
docs: add AGENTS.md with AI agent instructions

Comprehensive guide for AI coding assistants covering verification
rules, anti-bias measures, code comment conventions, and common
pitfalls to prevent unauthorized changes and confirmation bias.

feat(examples): add openedx-tutor deployment example

refactor(lb): split ingress LB into separate resource

BREAKING CHANGE: ingress_lb_id output renamed to ingress_lb_ipv4

fix(harmony): disable RKE2 built-in ingress when Harmony enabled
```

### Mandatory Code Comments

**Every code change MUST include a comment explaining WHY** the change was made — not what it does (the code shows that), but *why this approach was chosen over alternatives*.

This is especially important for:
- **Compromises** — when the ideal solution isn't possible and a workaround is used
- **Workarounds** — for bugs, provider limitations, or upstream issues
- **Non-obvious decisions** — anything a future reader might question or "fix"
- **Deliberate omissions** — when something is intentionally NOT done

### Comment Format (unified style)

Use the following structured comment prefixes to maintain a consistent style across the codebase:

```hcl
# COMPROMISE: <description>
# Why: <reason why the ideal approach is not used>
# See: <link to issue, docs, or ARCHITECTURE.md section> (optional)

# WORKAROUND: <description>
# Why: <what bug or limitation this works around>
# See: <link to upstream issue> (optional)
# TODO: Remove when <condition> is resolved

# DECISION: <description>
# Why: <rationale — why this approach over alternatives>

# NOTE: <important context that isn't obvious from the code>

# TODO: <planned improvement>
# Blocked by: <what needs to happen first> (optional)
```

### Examples

```hcl
# DECISION: L3/L4 separation — addons managed via Helmfile, not Terraform
# Why: Eliminates the chicken-and-egg problem of configuring kubernetes/helm
#      providers inside the same apply that creates the cluster.
#      Enables GitOps workflows (ArgoCD, Flux) for addon lifecycle.
# See: docs/ARCHITECTURE.md — Module Architecture

# WORKAROUND: Disabling RKE2 built-in ingress via HelmChartConfig
# Why: When Harmony is enabled, it deploys its own ingress-nginx (DaemonSet + hostPort).
#      Two ingress controllers on the same ports cause port conflicts.
# See: https://github.com/openedx/openedx-k8s-harmony

# DECISION: Dual load balancer architecture (control-plane + ingress)
# Why: Mixing API server traffic (6443) with HTTP traffic (80/443) on one LB
#      creates a single point of failure and complicates health checks.
# See: docs/ARCHITECTURE.md — Dual Load Balancer Design

# WORKAROUND: ignore_changes = [user_data] on master nodes
# Why: INITIAL_MASTER flag is set at creation time. Re-evaluating user_data on
#      subsequent applies would trigger unnecessary node replacement.
# TODO: Remove if RKE2 adds a runtime bootstrap detection mechanism
```

### Rules for agents:

1. **Never delete existing comments** — they document past decisions. If a comment is outdated, update it (don't remove).
2. **Every new resource, data source, or non-trivial logic MUST have a comment** explaining its purpose if not obvious from the name.
3. **Preserve the prefix style** (`COMPROMISE:`, `WORKAROUND:`, `DECISION:`, `NOTE:`, `TODO:`) — do not invent new prefixes.
4. **Include `See:` links** when referencing ARCHITECTURE.md, GitHub issues, or external docs.
5. **Include `TODO: Remove when ...`** on workarounds so future maintainers know when the workaround can be cleaned up.

---

## Common Pitfalls

1. **Root module is not runnable** — `tofu plan` in root will fail or require credentials you don't have. Use `examples/` for plan/apply.
2. **`null_resource` provisioners are not idempotent** — re-running may trigger SSH operations
3. **README.md has auto-generated sections** — `terraform-docs` generates the Providers/Resources/Inputs/Outputs tables between markers (`<!-- BEGIN_TF_DOCS -->` / `<!-- END_TF_DOCS -->`). Do NOT manually edit inside those markers.
4. **`terraform.tfstate` should NEVER be committed** — it contains secrets. It is in `.gitignore`.
5. **etcd quorum: 2 masters is worse than 1** — the module blocks `control_plane_count = 2` with a validation rule
6. **RKE2 version is pinned by default** — defaults to `v1.34.4+rke2r1`. Set `rke2_version = ""` to use the upstream `stable` channel (less reproducible).
7. **Training data is stale** — provider versions, Helm chart versions, Hetzner server types, and Kubernetes API versions in your training data are likely outdated. Always verify via network before suggesting changes.
8. **Questions ≠ change requests** — when the user asks "is this provider maintained?", do NOT immediately swap it. Answer the question, provide evidence, wait for instructions.

---

## Common Agent Mistakes (learn from these)

These are real mistakes that AI agents have made on this repository. Do not repeat them:

| Mistake | Why it happened | Correct behavior |
|---------|----------------|-----------------|
| Swapped `gavinbunney/kubectl` to `alekc/kubectl` without being asked | Agent interpreted a question ("how did you verify?") as an implicit change request | Answer questions with evidence. Do not edit code unless explicitly asked. |
| Had correct live data but drew the opposite conclusion | Agent fetched release dates (gavinbunney: Jan 2025, alekc: Nov 2024) but concluded alekc was "fresher" due to training data bias that gavinbunney was "abandoned" | **Always present raw facts in a comparison table FIRST.** Re-read dates as numbers before concluding. Prior beliefs from training data do NOT override arithmetic. |
| Ran `tofu init -upgrade` to "fix" lock file | Agent treated lockfile update as routine | Never run `init -upgrade` without approval — it silently changes provider versions |
| Rewrote entire README.md | Agent "improved" formatting and lost CI badges + terraform-docs markers | README has auto-generated sections. Only edit specific lines outside markers. |
| Claimed a provider was "abandoned" without checking | Agent relied on training data (stale) | Fetch the GitHub releases page or Registry page. Cite the URL. |
| Ran `tofu plan` in root module | Agent assumed root = deployment | Root is a module. Run plan only in `examples/` |
| Changed variable defaults without checking Hetzner API | Agent assumed `cx21` exists (it was renamed to `cx22`) | Verify server types, locations, LB types against live Hetzner docs |

---

## Related Repositories

- **Test instance**: `abstract-k8s-common-template` — local-only test deployment using this module
- **Harmony chart**: [openedx/openedx-k8s-harmony](https://github.com/openedx/openedx-k8s-harmony)
