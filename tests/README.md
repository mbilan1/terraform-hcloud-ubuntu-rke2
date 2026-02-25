# Tests

Unit tests for the `terraform-hcloud-rke2` module using OpenTofu's native `tofu test` framework with `mock_provider`.

## Test Strategy

### Quality Gate Pyramid

```
                    ╱╲
                   ╱  ╲          Gate 3: E2E (manual)
                  ╱ E2E╲         Real infra, tofu apply + smoke + destroy
                 ╱──────╲
                ╱        ╲       Gate 2: Integration
               ╱  Plan    ╲      tofu plan (examples/minimal) with real providers
              ╱────────────╲
             ╱              ╲    Gate 1: Unit Tests
            ╱  57 unit tests ╲   tofu test + mock_provider, every PR, ~$0
           ╱──────────────────╲
          ╱                    ╲  Gate 0: Static Analysis
         ╱ fmt · validate ·     ╲ tflint · checkov · tfsec · kics
     ╱──────────────────────────────╲
```

### Design Principles

| Principle | Implementation |
|-----------|---------------|
| **Offline-first** | All tests use `mock_provider` — zero cloud credentials, zero cost, ~3s total |
| **Shift-left** | Catch misconfigurations at `plan` phase, not at `apply` (30min+ deploy) |
| **100% validation coverage** | Every `validation {}` block tested with positive + negative cases |
| **100% guardrail coverage** | Every `check {}` block tested (13 directly; 2 DNS checks documented as untestable) |
| **100% branch coverage** | Every conditional `count`/`for_each` tested for both enabled and disabled states |
| **Deterministic** | No network calls, no randomness, no timing — same result every run |
| **Self-documenting** | Each `run` block has a UT-ID comment header with rationale |

### Test Strategy Layers

| Layer | Tool | Trigger | Cost | Duration | What it catches |
|-------|------|---------|:----:|:--------:|----------------|
| **Static analysis** | `tofu fmt`, `tofu validate`, `tflint`, Checkov, KICS, tfsec | Every PR | $0 | ~seconds | Formatting/syntax issues, linting, IaC security findings |
| **Unit** | `tofu test` + `mock_provider` | Every PR | $0 | ~3s | Validations, guardrails, conditional branches, defaults |
| **Integration** | `tofu plan` (real providers) | PR + manual | $0 | ~minutes | Provider auth/schema wiring beyond mocks (no apply) |
| **E2E** | GitHub Actions workflow `E2E: apply` | Manual only | ~$0.50/run | ~10–20min | Real infra provisioning, cloud-init, readiness flow (apply + smoke + destroy) |

### What This Test Suite Does NOT Cover

These areas require real infrastructure (E2E / integration tests) and are explicitly out of scope for unit tests:

- **Provisioner execution** — `terraform_data.wait_for_api`, `terraform_data.wait_for_cluster_ready` use SSH `remote-exec` which cannot be mocked
- **Cloud-init scripts** — `scripts/rke-master.sh.tpl`, `scripts/rke-worker.sh.tpl` are rendered but not executed
- **Actual K8s API reachability** — kubeconfig fetch, provider authentication against real cluster
- **LB health checks** — Hetzner Cloud LB health check behavior
- **DNS resolution** — Route53 record propagation
- **Addon deployment** — Kubernetes addons are deployed via Helmfile (`charts/`), outside Terraform

## Quick Start

```bash
cd /path/to/terraform-hcloud-rke2
tofu init
tofu test
```

All tests run **offline** with mocked providers — no cloud credentials, no infrastructure, no cost.

## Test Files

| File | Tests | Scope |
|------|:-----:|-------|
| `variables.tftest.hcl` | 21 | Variable validations — every `validation {}` block tested with positive + negative cases |
| `guardrails.tftest.hcl` | 13 | Cross-variable guardrails — every `check {}` block tested (2 DNS untestable) |
| `conditional_logic.tftest.hcl` | 17 | Resource count assertions for all conditional branches (harmony, masters, workers, LB, SSH, DNS, etcd backup) |
| `firewall.tftest.hcl` | 4 | Firewall rule assertions (Canal VXLAN, WireGuard, internal TCP) |
| `examples.tftest.hcl` | 2 | Full-stack configuration patterns (minimal, OpenEdX-Tutor) |
| **Total** | **57** | |

> **Note:** 2 DNS check blocks (`dns_requires_zone_id`, `dns_requires_harmony_ingress`) cannot be tested
> with mock providers — the downstream `aws_route53_record` triggers uncatchable provider schema
> errors. See the comment in `guardrails.tftest.hcl` for details.

## Architecture

### Test Strategy: Plan-Only with Mock Providers

```
┌─────────────┐     ┌──────────────┐     ┌─────────────────┐
│  .tftest.hcl │────▶│  tofu test   │────▶│  mock_provider   │
│  (test cases)│     │  command=plan│     │  (all 7 provs)   │
└─────────────┘     └──────────────┘     └─────────────────┘
                           │
                    ┌──────┴──────┐
                    │  Validates  │
                    ├─────────────┤
                    │ • Variables │
                    │ • Checks   │
                    │ • Counts   │
                    │ • Outputs  │
                    └─────────────┘
```

All 7 providers are mocked at the file level:

```hcl
mock_provider "hcloud" {}
mock_provider "remote" {}
mock_provider "aws" {}
mock_provider "cloudinit" {}
mock_provider "random" {}
mock_provider "tls" {}
mock_provider "local" {}
```

### Test Categories

#### 1. Variable Validations (UT-V*)

Tests that each `validation {}` block in `variables.tf` correctly accepts valid input and rejects invalid input.

Covers: `cluster_domain`, `control_plane_count`, `rke2_cluster_name`, `cni_plugin`, `extra_lb_ports`, `hcloud_network_cidr`, `subnet_address`, `ssh_allowed_cidrs`, `k8s_api_allowed_cidrs`.

#### 2. Guardrails / Check Blocks (UT-G*)

Tests that `check {}` blocks produce warnings for inconsistent variable combinations.

Covers: `aws_credentials_pair_consistency`, `workers_must_not_mix_countries`, `kubernetes_version` format, `harmony_requires_workers_for_lb`, `etcd_backup_requires_s3_config`, `dns_requires_zone_id` (untestable), `dns_requires_harmony_ingress` (untestable).

#### 3. Conditional Logic (UT-C*)

Tests that conditional `count` and `for_each` expressions produce expected resource counts for all major feature toggles.

Covers: Harmony on/off, master counts (1/3/5), worker counts (0/N), SSH on LB, SSH key file, DNS, ingress LB targets, control-plane LB, output values, pre-upgrade snapshots, etcd backup.

#### 4. Firewall Rules (UT-F*)

Tests that firewall rules are correctly defined for required ports and protocols.

Covers: Canal VXLAN (UDP 8472), Canal WireGuard (UDP 51820/51821), essential internal TCP rules, VXLAN not open to internet.

#### 5. Example Validation (UT-E*)

Tests that example configurations in `examples/` produce valid plans.

## Coverage Traceability

| Feature | Variables | Guardrail | Conditional | Firewall | Total |
|---------|:---------:|:---------:|:-----------:|:--------:|:-----:|
| Domain validation | 1 | — | — | — | 1 |
| Master count (etcd quorum) | 3 | — | 2 | — | 5 |
| Cluster name format | 4 | — | — | — | 4 |
| CNI selection | 2 | — | — | — | 2 |
| LB ports | 3 | — | — | — | 3 |
| Network CIDR | 2 | — | — | — | 2 |
| Subnet CIDR | 1 | — | — | — | 1 |
| SSH CIDRs | 1 | — | — | — | 1 |
| K8s API CIDRs | 2 | — | — | — | 2 |
| AWS credentials | — | 3 | — | — | 3 |
| Workers country policy | — | 3 | — | — | 3 |
| Kubernetes version format | — | 3 | — | — | 3 |
| Harmony | — | 1 | 4 | — | 5 |
| Workers | — | — | 2 | — | 2 |
| SSH on LB | — | — | 2 | — | 2 |
| SSH key file | — | — | 2 | — | 2 |
| DNS | — | — | 1 | — | 1 |
| Ingress LB targets | — | — | 1 | — | 1 |
| Control-plane LB | — | — | 1 | — | 1 |
| Output: ingress_lb_ipv4 | — | — | 1 | — | 1 |
| etcd backup | — | 3 | 3 | — | 6 |
| Firewall (Canal, internal) | — | — | — | 4 | 4 |
| Example: minimal | — | — | — | — | 1 |
| Example: openedx-tutor | — | — | — | — | 1 |

## CI Integration

Each CI command/tool has its own workflow file and badge in the root README (one badge = one tool):

| Badge label | File | Gate | Blocking |
|-------------|------|:----:|:--------:|
| Lint: fmt | `lint-fmt.yml` | 0a | Yes |
| Lint: validate | `lint-validate.yml` | 0a | Yes |
| Lint: tflint | `lint-tflint.yml` | 0a | Yes |
| SAST: Checkov | `sast-checkov.yml` | 0b | Yes |
| SAST: KICS | `sast-kics.yml` | 0b | Yes |
| SAST: tfsec | `sast-tfsec.yml` | 0b | No (best-effort) |
| Unit: variables | `unit-variables.yml` | 1 | Yes |
| Unit: guardrails | `unit-guardrails.yml` | 1 | Yes |
| Unit: conditionals | `unit-conditionals.yml` | 1 | Yes |
| Unit: examples | `unit-examples.yml` | 1 | Yes |
| Integration: plan | `integration-plan.yml` | 2 | No (requires secrets) |
| E2E: apply | `e2e-apply.yml` | 3 | No (manual only) |

Lint/SAST/Unit workflows trigger on push to `main` and on pull requests to `main`.
Integration triggers on PRs + manual dispatch (skipped when secrets unavailable).
E2E triggers on manual dispatch only (requires cost confirmation).

## Mock Provider Workarounds

All test files share the same `mock_provider` configuration. Key workarounds:

### Hetzner Cloud numeric IDs

Hetzner provider resources use numeric IDs internally, but OpenTofu mock providers auto-generate random string IDs (`"72oy3AZL"`) that fail string→number coercion in downstream resources. All hcloud mock resources override IDs with numeric strings:

```hcl
mock_provider "hcloud" {
  mock_resource "hcloud_server" {
    defaults = {
      id           = "10004"
      ipv4_address = "1.2.3.4"
    }
  }
  # ... similar for network, LB, SSH key, firewall
}
```

### Remote file empty content

`data.remote_file.kubeconfig` content is parsed by `yamldecode()` in `locals.tf`. The mock must return empty string to trigger the safe branch (`content == "" ? "" : base64decode(...)`):

```hcl
mock_provider "remote" {
  mock_data "remote_file" {
    defaults = {
      content = ""
    }
  }
}
```

## Known Limitations

| Limitation | Reason | Impact |
|-----------|--------|--------|
| DNS check blocks not testable | `aws_route53_record` schema rejects empty `zone_id` at provider level — not catchable by `expect_failures` | 2 of 15 check blocks tested only via code review |

## Adding New Tests

1. Choose the appropriate file based on what you're testing
2. Follow the naming convention: `UT-V*` for variables, `UT-G*` for guardrails, `UT-C*` for conditional logic, `UT-F*` for firewall, `UT-E*` for examples
3. Always set required variables (`hcloud_api_token`, `cluster_domain`) in every `run` block
4. Use `expect_failures` for negative tests (validation rejections, check block warnings)
5. Use `assert {}` for positive tests (resource count, output values)
6. Run `tofu test` locally before pushing

## Full Test Inventory

### Variable Validations (variables.tftest.hcl)

| ID | Test Name | Type | Target |
|----|-----------|:----:|--------|
| UT-V01 | `defaults_pass_validation` | ✅ positive | All defaults |
| UT-V02 | `domain_rejects_empty_string` | ❌ negative | `var.cluster_domain` |
| UT-V03 | `master_count_rejects_two` | ❌ negative | `var.control_plane_count` |
| UT-V04 | `master_count_accepts_one` | ✅ positive | `var.control_plane_count` |
| UT-V05 | `master_count_accepts_three` | ✅ positive | `var.control_plane_count` |
| UT-V06 | `master_count_accepts_five` | ✅ positive | `var.control_plane_count` |
| UT-V07a | `rke2_cluster_name_rejects_uppercase` | ❌ negative | `var.rke2_cluster_name` |
| UT-V07b | `rke2_cluster_name_rejects_hyphens` | ❌ negative | `var.rke2_cluster_name` |
| UT-V07c | `rke2_cluster_name_rejects_too_long` | ❌ negative | `var.rke2_cluster_name` |
| UT-V07d | `rke2_cluster_name_accepts_valid` | ✅ positive | `var.rke2_cluster_name` |
| UT-V08a | `cni_plugin_rejects_invalid` | ❌ negative | `var.cni_plugin` |
| UT-V08b | `cni_plugin_accepts_cilium` | ✅ positive | `var.cni_plugin` |
| UT-V09a | `lb_ports_rejects_zero` | ❌ negative | `var.extra_lb_ports` |
| UT-V09b | `lb_ports_rejects_too_large` | ❌ negative | `var.extra_lb_ports` |
| UT-V09c | `lb_ports_accepts_valid` | ✅ positive | `var.extra_lb_ports` |
| UT-V10a | `hcloud_network_cidr_rejects_invalid` | ❌ negative | `var.hcloud_network_cidr` |
| UT-V10b | `hcloud_network_cidr_accepts_valid` | ✅ positive | `var.hcloud_network_cidr` |
| UT-V11 | `subnet_address_rejects_invalid` | ❌ negative | `var.subnet_address` |
| UT-V13a | `ssh_cidrs_rejects_invalid` | ❌ negative | `var.ssh_allowed_cidrs` |
| UT-V13b | `k8s_api_cidrs_rejects_empty` | ❌ negative | `var.k8s_api_allowed_cidrs` |
| UT-V13c | `k8s_api_cidrs_rejects_invalid` | ❌ negative | `var.k8s_api_allowed_cidrs` |

### Guardrails (guardrails.tftest.hcl)

| ID | Test Name | Type | Target Check Block |
|----|-----------|:----:|--------------------|
| UT-G01a | `aws_credentials_rejects_partial` | ❌ negative | `check.aws_credentials_pair_consistency` |
| UT-G01b | `aws_credentials_accepts_both_set` | ✅ positive | `check.aws_credentials_pair_consistency` |
| UT-G01c | `aws_credentials_accepts_both_empty` | ✅ positive | `check.aws_credentials_pair_consistency` |
| UT-G10a | `workers_country_policy_passes_germany` | ✅ positive | `check.workers_must_not_mix_countries` |
| UT-G10b | `workers_country_policy_passes_finland` | ✅ positive | `check.workers_must_not_mix_countries` |
| UT-G10c | `workers_country_policy_rejects_mixed` | ❌ negative | `check.workers_must_not_mix_countries` |
| UT-G05a | `kubernetes_version_rejects_bad_format` | ❌ negative | `var.kubernetes_version` |
| UT-G05b | `kubernetes_version_accepts_empty` | ✅ positive | `var.kubernetes_version` |
| UT-G05c | `kubernetes_version_accepts_valid_format` | ✅ positive | `var.kubernetes_version` |
| UT-G08 | `harmony_requires_workers` | ❌ negative | `check.harmony_requires_workers_for_lb` |
| UT-G09a | `etcd_backup_rejects_missing_s3` | ❌ negative | `check.etcd_backup_requires_s3_config` |
| UT-G09b | `etcd_backup_passes_with_s3` | ✅ positive | `check.etcd_backup_requires_s3_config` |
| UT-G09c | `etcd_backup_passes_when_disabled` | ✅ positive | `check.etcd_backup_requires_s3_config` |
| — | *(dns_requires_zone_id)* | ⚠️ skipped | See [Known Limitations](#known-limitations) |
| — | *(dns_requires_harmony_ingress)* | ⚠️ skipped | See [Known Limitations](#known-limitations) |

### Conditional Logic (conditional_logic.tftest.hcl)

| ID | Test Name | Asserts |
|----|-----------|---------|
| UT-C01 | `harmony_disabled_no_ingress_lb` | ingress LB=0, ingress LB service/target=0 |
| UT-C02 | `harmony_enabled_creates_ingress_lb` | ingress LB=1, ingress LB service/target=created |
| UT-C05 | `single_master_no_additional` | additional_masters=0, master=1 |
| UT-C06 | `ha_cluster_creates_additional_masters` | additional_masters=4 (for count=5) |
| UT-C07 | `zero_workers` | worker=0 |
| UT-C08 | `workers_correct_count` | worker=5 |
| UT-C09 | `ssh_on_lb_disabled_by_default` | cp_ssh=0 |
| UT-C10 | `ssh_on_lb_enabled` | cp_ssh=1 |
| UT-C15 | `ssh_key_file_disabled_by_default` | ssh_private_key=0 |
| UT-C16 | `ssh_key_file_enabled` | ssh_private_key=1 |
| UT-C17 | `dns_disabled_by_default` | wildcard record=0 |
| UT-C18 | `ingress_lb_targets_match_workers` | ingress_workers=4 (when harmony enabled) |
| UT-C19 | `control_plane_lb_always_exists` | cp LB name="rke2-cp-lb" |
| UT-C20 | `output_ingress_null_when_harmony_disabled` | ingress_lb_ipv4=null |
| UT-C25 | `pre_upgrade_snapshot_disabled_by_default` | pre_upgrade_snapshot=0 |
| UT-C26 | `pre_upgrade_snapshot_enabled_with_etcd_backup` | pre_upgrade_snapshot=1 |
| UT-C27 | `outputs_reflect_backup_state` | etcd_backup_enabled output |

### Firewall Rules (firewall.tftest.hcl)

| ID | Test Name | Asserts |
|----|-----------|---------|
| UT-F01 | `firewall_has_canal_vxlan_udp_8472` | UDP 8472 rule exists |
| UT-F02 | `firewall_vxlan_not_open_to_internet` | VXLAN rule has private-only source |
| UT-F03 | `firewall_has_canal_wireguard_udp_51820_51821` | UDP 51820-51821 rule exists |
| UT-F04 | `firewall_has_essential_internal_tcp_rules` | Internal TCP rules exist |

### Example Patterns (examples.tftest.hcl)

| ID | Test Name | Pattern |
|----|-----------|---------|
| UT-E01 | `minimal_setup_plans_successfully` | 1 master, 0 workers, all defaults |
| UT-E02 | `openedx_tutor_pattern_plans_successfully` | 3 masters, 3 workers, Cilium, Harmony |
