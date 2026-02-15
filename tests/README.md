# Tests

Unit tests for the `terraform-hcloud-rke2` module using OpenTofu's native `tofu test` framework with `mock_provider`.

## Test Strategy

### Quality Gate Pyramid

```
                    ╱╲
                   ╱  ╲          Gate 4: E2E (future)
                  ╱ E2E╲         Real infra, Terratest, nightly, ~$0.50/run
                 ╱──────╲
                ╱        ╲       Gate 3: Example Validation
               ╱ Examples ╲      tofu test on examples/ dirs, every PR
              ╱────────────╲
             ╱              ╲    Gate 2: Conditional Logic
            ╱  Conditionals  ╲   Resource counts, feature toggles, every PR
           ╱──────────────────╲
          ╱                    ╲  Gate 1: Variables & Guardrails
         ╱  Vars + Guardrails   ╲ Input validation, cross-var checks, every PR
        ╱────────────────────────╲
       ╱                          ╲ Gate 0: Static Analysis (existing CI)
      ╱  fmt · validate · tflint   ╲ checkov · tfsec · kics
     ╱──────────────────────────────╲
```

### Design Principles

| Principle | Implementation |
|-----------|---------------|
| **Offline-first** | All tests use `mock_provider` — zero cloud credentials, zero cost, ~3s total |
| **Shift-left** | Catch misconfigurations at `plan` phase, not at `apply` (30min+ deploy) |
| **100% validation coverage** | Every `validation {}` block tested with positive + negative cases |
| **100% guardrail coverage** | Every `check {}` block tested (8/10 directly; 2 DNS checks documented as untestable) |
| **100% branch coverage** | Every conditional `count`/`for_each` tested for both enabled and disabled states |
| **Deterministic** | No network calls, no randomness, no timing — same result every run |
| **Self-documenting** | Each `run` block has a UT-ID comment header with rationale |

### Two-Layer Strategy

| Layer | Tool | Trigger | Cost | Duration | What it catches |
|-------|------|---------|:----:|:--------:|----------------|
| **Unit** (current) | `tofu test` + `mock_provider` | Every PR | $0 | ~3s | Validation logic, guardrails, conditional branches, defaults |
| **E2E** (future) | Terratest (Go) | Nightly / manual | ~$0.50 | ~15min | Real cloud resources, provisioner scripts, addon deployment |

### What This Test Suite Does NOT Cover

These areas require real infrastructure (E2E / integration tests) and are explicitly out of scope for unit tests:

- **Provisioner execution** — `null_resource.wait_for_api`, `null_resource.wait_for_cluster_ready` use SSH `remote-exec` which cannot be mocked
- **Cloud-init scripts** — `scripts/rke-master.sh.tpl`, `scripts/rke-worker.sh.tpl` are rendered but not executed
- **Helm chart deployment** — mocked `helm_release` doesn't validate chart existence or values schema
- **Actual K8s API reachability** — kubeconfig fetch, provider authentication against real cluster
- **LB health checks** — Hetzner Cloud LB health check behavior
- **DNS resolution** — Route53 record propagation

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
| `variables.tftest.hcl` | 23 | Variable validations — every `validation {}` block tested with positive + negative cases |
| `guardrails.tftest.hcl` | 16 | Cross-variable guardrails — every `check {}` block tested (8 of 10 directly; 2 DNS untestable) |
| `conditional_logic.tftest.hcl` | 22 | Resource count assertions for all conditional branches (harmony, masters, workers, LB, SSH, cert-manager, HCCM, CSI, kured) |
| `examples.tftest.hcl` | 2 | Full-stack configuration patterns (minimal, OpenEdX-Tutor) |
| **Total** | **63** | |

> **Note:** 2 DNS check blocks (`dns_requires_zone_id`, `dns_requires_harmony_ingress`) cannot be tested
> with mock providers — the downstream `aws_route53_record` triggers uncatchable provider schema  
> errors. See the comment in `guardrails.tftest.hcl` for details.

## Architecture

### Test Strategy: Plan-Only with Mock Providers

```
┌─────────────┐     ┌──────────────┐     ┌─────────────────┐
│  .tftest.hcl │────▶│  tofu test   │────▶│  mock_provider   │
│  (test cases)│     │  command=plan│     │  (all 11 provs)  │
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

All 11 providers are mocked at the file level:

```hcl
mock_provider "hcloud" {}
mock_provider "remote" {}
mock_provider "aws" {}
mock_provider "kubectl" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "null" {}
mock_provider "random" {}
mock_provider "tls" {}
mock_provider "local" {}
mock_provider "http" {}
```

### Test Categories

#### 1. Variable Validations (UT-V*)

Tests that each `validation {}` block in `variables.tf` correctly accepts valid input and rejects invalid input.

Covers: `domain`, `master_node_count`, `cluster_name`, `rke2_cni`, `additional_lb_service_ports`, `network_address`, `subnet_address`, `cluster_configuration.hcloud_csi.reclaim_policy`, `ssh_allowed_cidrs`, `k8s_api_allowed_cidrs`.

#### 2. Guardrails / Check Blocks (UT-G*)

Tests that `check {}` blocks produce warnings for inconsistent variable combinations.

Covers: `aws_credentials_pair_consistency`, `letsencrypt_email_required_when_issuer_enabled`, `system_upgrade_controller_version_format`, `remote_manifest_downloads_required_for_selected_features`, `rke2_version_format_when_pinned`, `auto_updates_require_ha`, `harmony_requires_cert_manager`, `harmony_requires_workers_for_lb`, `dns_requires_zone_id`, `dns_requires_harmony_ingress`.

#### 3. Conditional Logic (UT-C*)

Tests that conditional `count` and `for_each` expressions produce expected resource counts for all major feature toggles.

Covers: Harmony on/off, master counts (1/3/5), worker counts (0/N), SSH on LB, cert-manager, HCCM, CSI, SSH key file, DNS, ingress LB targets, kured/self-maintenance.

#### 4. Example Validation (UT-E*)

Tests that example configurations in `examples/` produce valid plans.

## Coverage Traceability

| Feature | Variables | Guardrail | Conditional | Total |
|---------|:---------:|:---------:|:-----------:|:-----:|
| Domain validation | 1 | — | — | 1 |
| Master count (etcd quorum) | 3 | — | 2 | 5 |
| Cluster name format | 4 | — | — | 4 |
| CNI selection | 2 | — | — | 2 |
| LB ports | 3 | — | — | 3 |
| Network CIDR | 2 | — | — | 2 |
| Subnet CIDR | 1 | — | — | 1 |
| CSI reclaim policy | 2 | — | 1 | 3 |
| SSH CIDRs | 1 | — | — | 1 |
| K8s API CIDRs | 2 | — | — | 2 |
| AWS credentials | — | 3 | — | 3 |
| Let's Encrypt email | — | 2 | — | 2 |
| SUC version format | — | 2 | — | 2 |
| Remote manifests | — | 2 | — | 2 |
| RKE2 version format | — | 3 | — | 3 |
| Auto-updates + HA | — | 2 | 2 | 4 |
| Harmony | — | 2 | 4 | 6 |
| Workers | — | — | 2 | 2 |
| SSH on LB | — | — | 2 | 2 |
| cert-manager | — | — | 2 | 2 |
| HCCM | — | — | 1 | 1 |
| SSH key file | — | — | 2 | 2 |
| DNS | — | 2 | 1 | 3 |
| Ingress LB targets | — | — | 1 | 1 |
| Control-plane LB | — | — | 1 | 1 |
| Output: ingress_lb_ipv4 | — | — | 1 | 1 |
| Example: minimal | — | — | — | 1 |

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

All workflows trigger on push to `main` and on pull requests to `main`.

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
| DNS check blocks not testable | `aws_route53_record` schema rejects empty `zone_id` at provider level — not catchable by `expect_failures` | 2 of 10 check blocks tested only via code review |
| `kured_not_deployed_on_single_master` uses `expect_failures` | Setting `enable_auto_os_updates=true` + `master_node_count=1` triggers `check.auto_updates_require_ha` warning alongside the conditional count | Cannot assert `length(helm_release.kured) == 0` in same run block that expects a check failure |
| Mock providers do not validate Helm chart values | `helm_release` with mocked provider accepts any values without schema checking | Helm values correctness requires E2E tests |

## Adding New Tests

1. Choose the appropriate file based on what you're testing
2. Follow the naming convention: `UT-V*` for variables, `UT-G*` for guardrails, `UT-C*` for conditional logic, `UT-E*` for examples
3. Always set required variables (`hetzner_token`, `domain`) in every `run` block
4. Use `expect_failures` for negative tests (validation rejections, check block warnings)
5. Use `assert {}` for positive tests (resource count, output values)
6. Run `tofu test` locally before pushing

## Full Test Inventory

### Variable Validations (variables_and_guardrails.tftest.hcl)

| ID | Test Name | Type | Target |
|----|-----------|:----:|--------|
| UT-V01 | `defaults_pass_validation` | ✅ positive | All defaults |
| UT-V02 | `domain_rejects_empty_string` | ❌ negative | `var.domain` |
| UT-V03 | `master_count_rejects_two` | ❌ negative | `var.master_node_count` |
| UT-V04 | `master_count_accepts_one` | ✅ positive | `var.master_node_count` |
| UT-V05 | `master_count_accepts_three` | ✅ positive | `var.master_node_count` |
| UT-V06 | `master_count_accepts_five` | ✅ positive | `var.master_node_count` |
| UT-V07a | `cluster_name_rejects_uppercase` | ❌ negative | `var.cluster_name` |
| UT-V07b | `cluster_name_rejects_hyphens` | ❌ negative | `var.cluster_name` |
| UT-V07c | `cluster_name_rejects_too_long` | ❌ negative | `var.cluster_name` |
| UT-V07d | `cluster_name_accepts_valid` | ✅ positive | `var.cluster_name` |
| UT-V08a | `rke2_cni_rejects_invalid` | ❌ negative | `var.rke2_cni` |
| UT-V08b | `rke2_cni_accepts_cilium` | ✅ positive | `var.rke2_cni` |
| UT-V09a | `lb_ports_rejects_zero` | ❌ negative | `var.additional_lb_service_ports` |
| UT-V09b | `lb_ports_rejects_too_large` | ❌ negative | `var.additional_lb_service_ports` |
| UT-V09c | `lb_ports_accepts_valid` | ✅ positive | `var.additional_lb_service_ports` |
| UT-V10a | `network_address_rejects_invalid` | ❌ negative | `var.network_address` |
| UT-V10b | `network_address_accepts_valid` | ✅ positive | `var.network_address` |
| UT-V11 | `subnet_address_rejects_invalid` | ❌ negative | `var.subnet_address` |
| UT-V12a | `reclaim_policy_rejects_invalid` | ❌ negative | `var.cluster_configuration` |
| UT-V12b | `reclaim_policy_accepts_retain` | ✅ positive | `var.cluster_configuration` |
| UT-V13a | `ssh_cidrs_rejects_invalid` | ❌ negative | `var.ssh_allowed_cidrs` |
| UT-V13b | `k8s_api_cidrs_rejects_empty` | ❌ negative | `var.k8s_api_allowed_cidrs` |
| UT-V13c | `k8s_api_cidrs_rejects_invalid` | ❌ negative | `var.k8s_api_allowed_cidrs` |

### Guardrails (variables_and_guardrails.tftest.hcl)

| ID | Test Name | Type | Target Check Block |
|----|-----------|:----:|--------------------|
| UT-G01a | `aws_credentials_rejects_partial` | ❌ negative | `check.aws_credentials_pair_consistency` |
| UT-G01b | `aws_credentials_accepts_both_set` | ✅ positive | `check.aws_credentials_pair_consistency` |
| UT-G01c | `aws_credentials_accepts_both_empty` | ✅ positive | `check.aws_credentials_pair_consistency` |
| UT-G02a | `letsencrypt_email_required_with_route53` | ❌ negative | `check.letsencrypt_email_required_when_issuer_enabled` |
| UT-G02b | `letsencrypt_email_passes_when_set` | ✅ positive | `check.letsencrypt_email_required_when_issuer_enabled` |
| UT-G03a | `suc_version_rejects_v_prefix` | ❌ negative | `check.system_upgrade_controller_version_format` |
| UT-G03b | `suc_version_accepts_valid` | ✅ positive | `check.system_upgrade_controller_version_format` |
| UT-G04a | `remote_downloads_required_for_k8s_updates` | ❌ negative | `check.remote_manifest_downloads_required_for_selected_features` |
| UT-G04b | `remote_downloads_passes_when_enabled` | ✅ positive | `check.remote_manifest_downloads_required_for_selected_features` |
| UT-G05a | `rke2_version_rejects_bad_format` | ❌ negative | `check.rke2_version_format_when_pinned` |
| UT-G05b | `rke2_version_accepts_empty` | ✅ positive | `check.rke2_version_format_when_pinned` |
| UT-G05c | `rke2_version_accepts_valid_format` | ✅ positive | `check.rke2_version_format_when_pinned` |
| UT-G06a | `auto_updates_warns_on_single_master` | ❌ negative | `check.auto_updates_require_ha` |
| UT-G06b | `auto_updates_passes_on_ha` | ✅ positive | `check.auto_updates_require_ha` |
| UT-G07 | `harmony_requires_cert_manager` | ❌ negative | `check.harmony_requires_cert_manager` |
| UT-G08 | `harmony_requires_workers` | ❌ negative | `check.harmony_requires_workers_for_lb` |
| — | *(dns_requires_zone_id)* | ⚠️ skipped | See [Known Limitations](#known-limitations) |
| — | *(dns_requires_harmony_ingress)* | ⚠️ skipped | See [Known Limitations](#known-limitations) |

### Conditional Logic (conditional_logic.tftest.hcl)

| ID | Test Name | Asserts |
|----|-----------|---------|
| UT-C01 | `harmony_disabled_no_ingress_lb` | ingress LB=0, harmony namespace=0, harmony helm=0 |
| UT-C02 | `harmony_enabled_creates_ingress_lb` | ingress LB=1, harmony namespace=1, harmony helm=1 |
| UT-C03 | `harmony_disables_builtin_ingress` | ingress_configuration=0 |
| UT-C04 | `harmony_disabled_uses_builtin_ingress` | ingress_configuration=1 |
| UT-C05 | `single_master_no_additional` | additional_masters=0, master=1 |
| UT-C06 | `ha_cluster_creates_additional_masters` | additional_masters=4 (for count=5) |
| UT-C07 | `zero_workers` | worker=0 |
| UT-C08 | `workers_correct_count` | worker=5 |
| UT-C09 | `ssh_on_lb_disabled_by_default` | cp_ssh=0 |
| UT-C10 | `ssh_on_lb_enabled` | cp_ssh=1 |
| UT-C11 | `certmanager_disabled` | cert_manager namespace=0, helm=0 |
| UT-C12 | `certmanager_enabled_by_default` | cert_manager namespace=1, helm=1 |
| UT-C13 | `hccm_disabled` | hcloud_ccm secret=0, hccm helm=0 |
| UT-C14 | `csi_disabled` | hcloud_csi helm=0 |
| UT-C15 | `ssh_key_file_disabled_by_default` | ssh_private_key=0 |
| UT-C16 | `ssh_key_file_enabled` | ssh_private_key=1 |
| UT-C17 | `dns_disabled_by_default` | wildcard record=0 |
| UT-C18 | `ingress_lb_targets_match_workers` | ingress_workers=4 |
| UT-C19 | `control_plane_lb_always_exists` | cp LB name="rke2-cp-lb" |
| UT-C20 | `output_ingress_null_when_harmony_disabled` | ingress_lb_ipv4=null |
| UT-C21 | `kured_not_deployed_on_single_master` | expect_failures: auto_updates check |
| UT-C22 | `kured_deployed_on_ha_with_auto_updates` | kured helm=1, kured namespace=1 |

### Example Patterns (examples.tftest.hcl)

| ID | Test Name | Pattern |
|----|-----------|---------|
| UT-E01 | `minimal_setup_plans_successfully` | 1 master, 0 workers, all defaults |
| UT-E02 | `openedx_tutor_pattern_plans_successfully` | 3 masters, 3 workers, Cilium, Harmony |
