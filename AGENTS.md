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

- **IaC tool**: OpenTofu >= 1.5 — always use `tofu`, **never** `terraform`
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
4. **Preserve existing code comments** — they document deliberate compromises
5. **Read the relevant file before editing** — understand the dependency chain
6. **Verify external claims via network** before suggesting or making changes (see [Verification Rules](#verification-rules-mandatory))

### Where to run what

| Command | Root module (`/`) | `examples/*` directories |
|---------|:-:|:-:|
| `tofu validate` | ✅ Safe | ✅ Safe |
| `tofu fmt` | ✅ Safe | ✅ Safe |
| `tofu plan` | ❌ **Forbidden** | ✅ With credentials |
| `tofu apply` | ❌ **Forbidden** | ⚠️ Only with explicit user approval |
| `tofu destroy` | ❌ **Forbidden** | ⚠️ Only with explicit user approval |

### Safe commands (can run without asking):
- `tofu validate` — syntax check, no side effects
- `tofu fmt` / `tofu fmt -check` — formatting, no side effects
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

### Root Terraform Files

| File | Purpose |
|------|---------|
| `main.tf` | Server resources (masters, workers), cloud-init, provisioners |
| `providers.tf` | All required providers with version constraints (12+ providers) |
| `variables.tf` | All input variables with descriptions, types, defaults, validations |
| `output.tf` | Module outputs (kubeconfig, IPs, etc.) |
| `locals.tf` | Computed values and internal configuration |
| `data.tf` | Data sources (remote kubeconfig, HTTP downloads for CRDs) |
| `network.tf` | Hetzner private network and subnet |
| `firewall.tf` | Hetzner Cloud Firewall rules |
| `load_balancer.tf` | Dual LB architecture (control-plane LB + ingress LB) |
| `dns.tf` | AWS Route53 DNS records (wildcard → ingress LB) |
| `ssh.tf` | Auto-generated RSA 4096 SSH key pair |
| `guardrails.tf` | Preflight validation checks (e.g. DNS requires Harmony) |

### Cluster Addon Files (cluster-*.tf)

| File | Purpose | Always deployed? |
|------|---------|:---:|
| `cluster-hccm.tf` | Hetzner Cloud Controller Manager | Yes |
| `cluster-csi.tf` | Hetzner CSI driver (persistent volumes) | Yes |
| `cluster-certmanager.tf` | cert-manager + ClusterIssuer (Let's Encrypt) | Yes |
| `cluster-harmony.tf` | openedx-k8s-harmony chart + ingress-nginx | Opt-in (`harmony.enabled`) |
| `cluster-ingresscontroller.tf` | RKE2 built-in ingress (when Harmony disabled) | Conditional |
| `cluster-selfmaintenance.tf` | Kured + System Upgrade Controller | HA only (≥3 masters) |

### Other Directories

| Path | Purpose |
|------|---------|
| `scripts/` | cloud-init shell templates (`rke-master.sh.tpl`, `rke-worker.sh.tpl`) |
| `templates/manifests/` | Raw Kubernetes YAML manifests (System Upgrade Controller) |
| `templates/values/` | Helm chart values files |
| `docs/` | Architecture docs — **READ `ARCHITECTURE.md` BEFORE ANY WORK** |
| `examples/` | Example deployments (`simple-setup/`, `openedx-tutor/`, `rancher-setup/`) |

---

## Architecture Constraints (from ARCHITECTURE.md — read the full document)

### Dependency Chain
Addons deploy **sequentially** after cluster readiness:
```
Infrastructure → master-0 → additional masters → workers
    → wait_for_api → wait_for_cluster_ready
    → fetch kubeconfig → HCCM → CSI → cert-manager → Harmony
```

**Do NOT reorder** addon deployments — they have provider/resource dependencies.

### Dual Load Balancer Design
- **Control-plane LB**: targets masters only (ports 6443, 9345, optionally 22)
- **Ingress LB**: targets workers only (ports 80, 443) — **exists only when Harmony enabled**
- This is a deliberate design choice, not a mistake. Do NOT merge them.

### DNS ↔ Harmony Coupling
`create_dns_record = true` creates a Route53 wildcard pointing to the ingress LB.
The ingress LB exists **only when** `harmony.enabled = true`.
This is enforced by a preflight `check` in `guardrails.tf`.

### Harmony ↔ Ingress Exclusivity
When `harmony.enabled = true`:
- Harmony deploys its own ingress-nginx (DaemonSet + hostPort)
- RKE2 built-in ingress is disabled via HelmChartConfig
- `enable_nginx_modsecurity_waf` has no effect (known gap)

When `harmony.enabled = false`:
- RKE2 built-in ingress is used
- ModSecurity WAF can be enabled

### master-0 Is Special
- `master-0` bootstraps the entire cluster
- It has `prevent_destroy = true` lifecycle rule
- `INITIAL_MASTER` flag in user_data is set at creation and never re-evaluated (`ignore_changes = [user_data]`)
- SSH provisioners connect to master-0 for kubeconfig retrieval and readiness checks

### Provider Constraints
- `gavinbunney/kubectl` provider is used for raw manifest application — do NOT change without live verification and explicit user approval
- All providers are declared **inside** the module (known anti-pattern, extraction planned as breaking change)
- Provider versions use `~>` pessimistic constraint — changing major versions is a breaking change

---

## Code Style and Conventions

- **HCL formatting**: `tofu fmt` canonical style
- **Variable naming**: `snake_case` with descriptive names
- **Comments**: inline `#` comments document compromises and non-obvious decisions — preserve them
- **Helm values**: stored in `templates/values/*.yaml`, referenced via `templatefile()`
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
# COMPROMISE: Using gavinbunney/kubectl instead of hashicorp/kubernetes for raw manifests
# Why: kubernetes provider doesn't support applying arbitrary YAML manifests.
#      alekc/kubectl is a maintained fork with more features (v2.x), but migration
#      is a breaking change requiring provider source swap + state surgery.
# See: docs/ARCHITECTURE.md — Provider Constraints

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
5. **etcd quorum: 2 masters is worse than 1** — the module blocks `master_node_count = 2` with a validation rule
6. **RKE2 version is unpinned** — installed from `stable` channel without explicit version. Different deploys at different times may get different K8s versions.
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
- **Upstream fork**: [wenzel-felix/terraform-hcloud-rke2](https://github.com/wenzel-felix/terraform-hcloud-rke2)
- **Harmony chart**: [openedx/openedx-k8s-harmony](https://github.com/openedx/openedx-k8s-harmony)
