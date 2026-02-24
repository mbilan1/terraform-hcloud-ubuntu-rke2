# 🇺🇦 terraform-hcloud-rke2

![OpenTofu](https://img.shields.io/badge/OpenTofu-%3E%3D%201.5.0-blue?logo=opentofu)
![RKE2](https://img.shields.io/badge/RKE2-v1.34.4-blue?logo=rancher)
![hcloud](https://img.shields.io/badge/hcloud-~%3E%201.44-blue?logo=hetzner)
![Harmony](https://img.shields.io/badge/Harmony-0.10.0-blue?logo=helm)
![License](https://img.shields.io/github/license/mbilan1/terraform-hcloud-rke2)
![GitHub Release](https://img.shields.io/github/v/release/mbilan1/terraform-hcloud-rke2?include_prereleases&label=Release)

**Quality Gate Results:**

<!-- Lint -->
[![Lint: fmt](https://github.com/mbilan1/terraform-hcloud-rke2/actions/workflows/lint-fmt.yml/badge.svg)](https://github.com/mbilan1/terraform-hcloud-rke2/actions/workflows/lint-fmt.yml)
[![Lint: validate](https://github.com/mbilan1/terraform-hcloud-rke2/actions/workflows/lint-validate.yml/badge.svg)](https://github.com/mbilan1/terraform-hcloud-rke2/actions/workflows/lint-validate.yml)
[![Lint: tflint](https://github.com/mbilan1/terraform-hcloud-rke2/actions/workflows/lint-tflint.yml/badge.svg)](https://github.com/mbilan1/terraform-hcloud-rke2/actions/workflows/lint-tflint.yml)
<!-- SAST -->
[![SAST: Checkov](https://github.com/mbilan1/terraform-hcloud-rke2/actions/workflows/sast-checkov.yml/badge.svg)](https://github.com/mbilan1/terraform-hcloud-rke2/actions/workflows/sast-checkov.yml)
[![SAST: KICS](https://github.com/mbilan1/terraform-hcloud-rke2/actions/workflows/sast-kics.yml/badge.svg)](https://github.com/mbilan1/terraform-hcloud-rke2/actions/workflows/sast-kics.yml)
[![SAST: tfsec](https://github.com/mbilan1/terraform-hcloud-rke2/actions/workflows/sast-tfsec.yml/badge.svg)](https://github.com/mbilan1/terraform-hcloud-rke2/actions/workflows/sast-tfsec.yml)
<!-- Unit -->
[![Unit: variables](https://github.com/mbilan1/terraform-hcloud-rke2/actions/workflows/unit-variables.yml/badge.svg)](https://github.com/mbilan1/terraform-hcloud-rke2/actions/workflows/unit-variables.yml)
[![Unit: guardrails](https://github.com/mbilan1/terraform-hcloud-rke2/actions/workflows/unit-guardrails.yml/badge.svg)](https://github.com/mbilan1/terraform-hcloud-rke2/actions/workflows/unit-guardrails.yml)
[![Unit: conditionals](https://github.com/mbilan1/terraform-hcloud-rke2/actions/workflows/unit-conditionals.yml/badge.svg)](https://github.com/mbilan1/terraform-hcloud-rke2/actions/workflows/unit-conditionals.yml)
[![Unit: examples](https://github.com/mbilan1/terraform-hcloud-rke2/actions/workflows/unit-examples.yml/badge.svg)](https://github.com/mbilan1/terraform-hcloud-rke2/actions/workflows/unit-examples.yml)
<!-- Integration -->
[![Integration: plan](https://github.com/mbilan1/terraform-hcloud-rke2/actions/workflows/integration-plan.yml/badge.svg)](https://github.com/mbilan1/terraform-hcloud-rke2/actions/workflows/integration-plan.yml)
<!-- E2E -->
[![E2E: apply](https://github.com/mbilan1/terraform-hcloud-rke2/actions/workflows/e2e-apply.yml/badge.svg)](https://github.com/mbilan1/terraform-hcloud-rke2/actions/workflows/e2e-apply.yml)

RKE2 Kubernetes cluster on Hetzner Cloud with Open edX (Harmony) integration.

## Acknowledgements / Upstream

This project started as an experimental fork of https://github.com/wenzel-felix/terraform-hcloud-rke2.
Credit for the original baseline work goes to the upstream author and contributors.

For clarity and license compliance, the upstream MIT license text is preserved in:
- `LICENSES/MIT-upstream-wenzel-felix.txt`

> [!WARNING]
> **Experimental module.** APIs, variable names, and default values may change without notice between releases. Not production-ready. Use at your own risk.

## Overview

This module provisions a multi-node RKE2 Kubernetes cluster on Hetzner Cloud (EU), with optional [openedx-k8s-harmony](https://github.com/openedx/openedx-k8s-harmony) integration for deploying Open edX.

Key capabilities:

- Multi-DC master distribution (Helsinki, Nuremberg, Falkenstein)
- Dual load balancer architecture (control plane + ingress)
- cert-manager with Let's Encrypt (DNS-01 via Route53)
- Hetzner CCM for cloud integration (CSI optional)
- Self-maintenance: Kured + System Upgrade Controller (HA clusters only)
- Backup: etcd snapshots (RKE2 native) + PVC backup via Longhorn native S3 backup

> [!NOTE]
> The module allows full `tofu destroy` (including primary control-plane node). In production, protect this operationally with code review, environment protections, and targeted plans/applies.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for design decisions and trade-offs.

## Prerequisites

- Hetzner Cloud account + API token
- OpenTofu >= 1.5.0 or Terraform >= 1.5.0
- (Optional) AWS account with Route53 hosted zone for DNS + TLS

## Usage

### Minimal (single master, dev/test)

```hcl
module "rke2" {
  source        = "git::https://github.com/mbilan1/terraform-hcloud-rke2.git?ref=bac8aef"
  hetzner_token = var.hetzner_token
  domain        = "example.com"
  master_node_count = 1
  worker_node_count = 0
}
```

### Production (HA with Harmony)

```hcl
module "rke2" {
  source            = "git::https://github.com/mbilan1/terraform-hcloud-rke2.git?ref=bac8aef"
  hetzner_token     = var.hetzner_token
  domain            = "example.com"
  harmony           = { enabled = true }
  master_node_count = 3
  worker_node_count = 3
  create_dns_record = true
  route53_zone_id   = var.route53_zone_id
  letsencrypt_issuer = "admin@example.com"

  ssh_allowed_cidrs     = ["YOUR_IP/32"]
  k8s_api_allowed_cidrs = ["YOUR_IP/32"]
}
```

### Deploy

```bash
tofu init
tofu apply
```

### Access the cluster

```bash
tofu output -raw kube_config > kubeconfig.yaml
export KUBECONFIG=kubeconfig.yaml
kubectl get nodes
```

## Open edX with Harmony

When `harmony.enabled = true`, the module deploys the [openedx-k8s-harmony](https://github.com/openedx/openedx-k8s-harmony) chart with infrastructure-aligned defaults:

| Component | Source | Harmony override |
|-----------|--------|:---:|
| ingress-nginx | Harmony chart | `ingress-nginx.enabled: true` |
| cert-manager | This module | `cert-manager.enabled: false` |
| metrics-server | RKE2 built-in | `metricsserver.enabled: false` |
| Persistent volumes | This module | Hetzner CSI (default) or Longhorn (opt-in) |

After cluster creation, deploy Tutor instances:

```bash
pip install tutor-contrib-harmony-plugin
tutor plugins enable k8s_harmony
tutor config save
tutor k8s launch
```

### HTTPS out of the box (Harmony)

When `harmony.enabled = true`, the module can bootstrap a **default TLS certificate** for the apex
`domain` and configure Harmony's ingress-nginx controller to use it as the
`--default-ssl-certificate`.

Why this exists: the Harmony chart's default "echo" Ingress is HTTP-only, so without a default
certificate ingress-nginx serves its self-signed fallback (often seen in browsers as a “Fake
Certificate”) until Tutor creates TLS-enabled Ingress resources.

Controls:

- `harmony.enable_default_tls_certificate` (default: `true`)
- `harmony.default_tls_secret_name` (default: `harmony-default-tls`)

## Backup

The module provides a **two-layer backup architecture** to Hetzner Object Storage (S3-compatible):

| Layer | What | Mechanism | Variable |
|-------|------|-----------|----------|
| **etcd** | Cluster state (resources, secrets, configs) | RKE2 native snapshots via `config.yaml` | `cluster_configuration.etcd_backup` |
| **PVC** | Application data (persistent volumes) | Longhorn native S3 backup (experimental) | `cluster_configuration.longhorn` |

Each layer uses **independent S3 credentials** — share them at module invocation level if desired.

> [!NOTE]
> Longhorn storage is marked **experimental** (`preinstall = false` by default).
> When enabled, it replaces Hetzner CSI as the primary storage driver with
> cross-worker replication, native VolumeSnapshot, and instant pre-upgrade snapshots.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#operations-backup-upgrade-rollback) for design rationale.

## Module Reference

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.0.0, < 7.0.0 |
| <a name="requirement_cloudinit"></a> [cloudinit](#requirement\_cloudinit) | >= 2.3.0, < 3.0.0 |
| <a name="requirement_hcloud"></a> [hcloud](#requirement\_hcloud) | >= 1.44.0, < 2.0.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | >= 2.11.0 |
| <a name="requirement_http"></a> [http](#requirement\_http) | >= 3.4.0, < 4.0.0 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | >= 1.19.0, < 2.0.0 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | >= 2.23.0 |
| <a name="requirement_local"></a> [local](#requirement\_local) | >= 2.4.0, < 3.0.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | >= 3.5.0, < 4.0.0 |
| <a name="requirement_remote"></a> [remote](#requirement\_remote) | >= 0.2.0, < 1.0.0 |
| <a name="requirement_tls"></a> [tls](#requirement\_tls) | >= 4.0.0, < 5.0.0 |
### Providers

No providers.
### Resources

No resources.
### Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_cluster_domain"></a> [cluster\_domain](#input\_cluster\_domain) | Base DNS domain associated with this Kubernetes cluster (e.g. 'k8s.example.com') | `string` | n/a | yes |
| <a name="input_hcloud_api_token"></a> [hcloud\_api\_token](#input\_hcloud\_api\_token) | Authentication token for the Hetzner Cloud provider (read/write access required) | `string` | n/a | yes |
| <a name="input_agent_node_count"></a> [agent\_node\_count](#input\_agent\_node\_count) | Count of dedicated agent nodes that run workloads. Set to 0 to co-locate pods on control-plane servers. | `number` | `3` | no |
| <a name="input_allow_remote_manifest_downloads"></a> [allow\_remote\_manifest\_downloads](#input\_allow\_remote\_manifest\_downloads) | Allow downloading external manifests from GitHub at plan/apply time (System Upgrade Controller). Disable for stricter reproducibility/offline workflows. | `bool` | `true` | no |
| <a name="input_aws_access_key"></a> [aws\_access\_key](#input\_aws\_access\_key) | AWS access key for Route53 and cert-manager DNS-01 solver. If empty, uses default AWS credentials chain. | `string` | `""` | no |
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | AWS region used by the Route53 provider. | `string` | `"eu-central-1"` | no |
| <a name="input_aws_secret_key"></a> [aws\_secret\_key](#input\_aws\_secret\_key) | AWS secret key for Route53 and cert-manager DNS-01 solver. If empty, uses default AWS credentials chain. | `string` | `""` | no |
| <a name="input_cluster_configuration"></a> [cluster\_configuration](#input\_cluster\_configuration) | Addon stack configuration — controls which Kubernetes components are pre-installed<br/>and their Helm chart versions. Each subsection maps to a file in modules/addons/.<br/>See README.md Inputs section for the full attribute reference and defaults. | <pre>object({<br/>    # ── Hetzner Cloud Controller Manager ──────────────────────────────────<br/>    # Manages node lifecycle, cloud routes, and LB reconciliation with the<br/>    # Hetzner Cloud API. Should almost always stay enabled.<br/>    hcloud_controller = optional(object({<br/>      preinstall = optional(bool, true)<br/>      version    = optional(string, "1.30.1")<br/><br/>      # NOTE: Optional metadata for operators.<br/>      # Why: These fields are intentionally *not* consumed by the module today.<br/>      #      They exist to document intent and allow future extension without a<br/>      #      breaking variable-schema change.<br/>      release_name = optional(string, "")<br/>      namespace    = optional(string, "")<br/>    }), {})<br/><br/>    # ── Hetzner CSI Driver ────────────────────────────────────────────────<br/>    # Provides ReadWriteOnce volumes backed by Hetzner Cloud Volumes.<br/>    # Can be demoted once Longhorn is battle-tested.<br/>    hcloud_csi = optional(object({<br/>      preinstall            = optional(bool, true)<br/>      version               = optional(string, "2.19.1")<br/>      default_storage_class = optional(bool, true)<br/>      reclaim_policy        = optional(string, "Delete")<br/><br/>      # NOTE: Optional metadata for operators.<br/>      # Why: Keeping room for future chart knobs without forcing consumers to<br/>      #      upgrade their variable schema immediately.<br/>      release_name = optional(string, "")<br/>      namespace    = optional(string, "")<br/>    }), {})<br/><br/>    # ── cert-manager (Jetstack) ───────────────────────────────────────────<br/>    # Automated TLS certificate lifecycle. Supports DNS-01 (Route53) and<br/>    # HTTP-01 ACME challenge types.<br/>    cert_manager = optional(object({<br/>      preinstall                      = optional(bool, true)<br/>      version                         = optional(string, "v1.19.3")<br/>      use_for_preinstalled_components = optional(bool, true)<br/><br/>      # NOTE: Optional metadata for operators.<br/>      release_name = optional(string, "")<br/>      namespace    = optional(string, "")<br/>    }), {})<br/><br/>    # ── Self-maintenance (Kured + SUC) ────────────────────────────────────<br/>    # Kured: unattended OS reboot daemon (cordon → reboot → uncordon).<br/>    # SUC: System Upgrade Controller for automated RKE2 patch upgrades.<br/>    # Both require HA (≥3 masters) and are gated in selfmaintenance.tf.<br/>    self_maintenance = optional(object({<br/>      kured_version                     = optional(string, "5.11.0")<br/>      system_upgrade_controller_version = optional(string, "0.19.0")<br/><br/>      # NOTE: Optional metadata for operators.<br/>      # Why: Makes it easier to keep internal naming conventions consistent<br/>      #      across multiple clusters.<br/>      kured_release_name = optional(string, "")<br/>      suc_release_name   = optional(string, "")<br/>    }), {})<br/><br/>    # ── etcd snapshot + S3 offsite backup ─────────────────────────────────<br/>    # DECISION: etcd backup via RKE2 native config.yaml params (zero dependencies)<br/>    # Why: etcd snapshot is built into RKE2, configured in cloud-init before K8s starts.<br/>    #      This makes it independent of cluster health — works even if K8s is down.<br/>    # See: https://docs.rke2.io/datastore/backup_restore<br/>    etcd_backup = optional(object({<br/>      enabled               = optional(bool, false)<br/>      compress              = optional(bool, true)<br/>      schedule_cron         = optional(string, "0 */6 * * *")<br/>      retention             = optional(number, 10)<br/>      s3_retention          = optional(number, 10)<br/>      s3_endpoint           = optional(string, "")<br/>      s3_bucket             = optional(string, "")<br/>      s3_folder             = optional(string, "")<br/>      s3_access_key         = optional(string, "")<br/>      s3_secret_key         = optional(string, "")<br/>      s3_region             = optional(string, "eu-central")<br/>      s3_bucket_lookup_type = optional(string, "path")<br/><br/>      # NOTE: Optional metadata for operators.<br/>      # Why: Cron/schedule semantics sometimes depend on human conventions.<br/>      description = optional(string, "")<br/>    }), {})<br/><br/>    # ── Longhorn distributed storage ──────────────────────────────────────<br/>    # DECISION: Longhorn as primary storage driver with native backup<br/>    # Why: Replication across workers (HA). Local NVMe IOPS (~50K vs ~10K).<br/>    #      Native VolumeSnapshot (Hetzner CSI has none — issue #849).<br/>    #      Integrated storage + backup in single component. Instant pre-upgrade snapshots.<br/>    #      Fewer components in restore path compared to external backup tools.<br/>    # NOTE: Longhorn is marked EXPERIMENTAL. Hetzner CSI retained as fallback.<br/>    # TODO: Promote Longhorn to default after battle-tested in production.<br/>    # See: docs/PLAN-operational-readiness.md — Step 2<br/>    longhorn = optional(object({<br/>      preinstall            = optional(bool, false)<br/>      version               = optional(string, "1.11.0")<br/>      replica_count         = optional(number, 2)<br/>      default_storage_class = optional(bool, true)<br/>      backup_target         = optional(string, "")<br/>      backup_schedule       = optional(string, "0 */6 * * *")<br/>      backup_retain         = optional(number, 10)<br/>      s3_endpoint           = optional(string, "")<br/>      s3_access_key         = optional(string, "")<br/>      s3_secret_key         = optional(string, "")<br/><br/>      # Tuning (see PLAN-operational-readiness.md Appendix A)<br/>      guaranteed_instance_manager_cpu = optional(number, 12)<br/>      storage_over_provisioning       = optional(number, 100)<br/>      storage_minimal_available       = optional(number, 15)<br/>      snapshot_max_count              = optional(number, 5)<br/><br/>      # NOTE: Optional metadata for operators.<br/>      release_name = optional(string, "")<br/>      namespace    = optional(string, "")<br/>    }), {})<br/>  })</pre> | `{}` | no |
| <a name="input_cluster_issuer_name"></a> [cluster\_issuer\_name](#input\_cluster\_issuer\_name) | Name of the cert-manager ClusterIssuer. Defaults to 'harmony-letsencrypt-global' for compatibility with openedx-k8s-harmony Tutor plugin (hardcoded in k8s-services patch). | `string` | `"harmony-letsencrypt-global"` | no |
| <a name="input_cni_plugin"></a> [cni\_plugin](#input\_cni\_plugin) | Container networking plugin for inter-pod communication. RKE2 bundles Canal (Flannel VXLAN + Calico network policy) by default. | `string` | `"canal"` | no |
| <a name="input_control_plane_count"></a> [control\_plane\_count](#input\_control\_plane\_count) | Count of server nodes in the control plane. Set to 1 for single-master or 3+ for high-availability (etcd quorum requires an odd count). | `number` | `3` | no |
| <a name="input_create_dns_record"></a> [create\_dns\_record](#input\_create\_dns\_record) | Provision a Route53 wildcard DNS record (*.cluster\_domain) pointing to the ingress load balancer. Requires harmony.enabled=true for the ingress LB to exist. | `bool` | `false` | no |
| <a name="input_enable_auto_kubernetes_updates"></a> [enable\_auto\_kubernetes\_updates](#input\_enable\_auto\_kubernetes\_updates) | Automatically upgrade RKE2 to the latest patch release within the configured channel using System Upgrade Controller (requires HA ≥ 3 masters). Gated by control\_plane\_count >= 3 at the addon level. | `bool` | `false` | no |
| <a name="input_enable_auto_os_updates"></a> [enable\_auto\_os\_updates](#input\_enable\_auto\_os\_updates) | Automatically apply OS security patches via unattended-upgrades and schedule reboots with Kured (requires HA ≥ 3 masters). Gated by control\_plane\_count >= 3 at the addon level. | `bool` | `false` | no |
| <a name="input_enable_nginx_modsecurity_waf"></a> [enable\_nginx\_modsecurity\_waf](#input\_enable\_nginx\_modsecurity\_waf) | Activate the ModSecurity web application firewall in the RKE2-bundled nginx ingress controller. Ineffective when Harmony deploys its own ingress-nginx. | `bool` | `false` | no |
| <a name="input_enable_secrets_encryption"></a> [enable\_secrets\_encryption](#input\_enable\_secrets\_encryption) | Enable Kubernetes Secrets encryption at rest in etcd via RKE2 secrets-encryption config. Strongly recommended for production. | `bool` | `true` | no |
| <a name="input_enable_ssh_on_lb"></a> [enable\_ssh\_on\_lb](#input\_enable\_ssh\_on\_lb) | Expose SSH (port 22) via the management load balancer. Disabled by default for security. Enable only for debugging or when bastion access is unavailable. | `bool` | `false` | no |
| <a name="input_enforce_single_country_workers"></a> [enforce\_single\_country\_workers](#input\_enforce\_single\_country\_workers) | When true, forbid mixing worker locations across countries (e.g., hel1 + nbg1). Why: sync-heavy storage (Longhorn/MySQL) becomes unusably slow with cross-country RTT; enforce a single-country worker pool (Germany-only or Finland-only). | `bool` | `false` | no |
| <a name="input_extra_lb_ports"></a> [extra\_lb\_ports](#input\_extra\_lb\_ports) | Additional TCP ports to expose on the management load balancer beyond those needed for the K8s API and RKE2 join (e.g. [8080, 8443]). | `list(number)` | `[]` | no |
| <a name="input_harmony"></a> [harmony](#input\_harmony) | Harmony chart (openedx-k8s-harmony) integration.<br/>- enabled: Deploy Harmony chart via Helm. Disables RKE2 built-in ingress-nginx and routes HTTP/HTTPS through the management LB.<br/>- version: Chart version to install. Empty string means latest.<br/>- extra\_values: Additional values.yaml content (list of YAML strings) merged after infrastructure defaults.<br/>- enable\_default\_tls\_certificate: When true, the module creates a cert-manager Certificate for var.cluster\_domain<br/>  and configures Harmony's ingress-nginx controller to use it as the default HTTPS certificate.<br/>- default\_tls\_secret\_name: Secret name (in the harmony namespace) used for the default TLS certificate. | <pre>object({<br/>    enabled      = optional(bool, false)<br/>    version      = optional(string, "")<br/>    extra_values = optional(list(string), [])<br/><br/>    # DECISION: TLS bootstrap for "platform is working" UX when Harmony is enabled.<br/>    # Why: openedx-k8s-harmony's echo Ingress is HTTP-only (no tls: block), so<br/>    #      ingress-nginx serves its self-signed "Fake Certificate" for catch-all HTTPS.<br/>    #      Providing a cert-manager Certificate + ingress-nginx default-ssl-certificate<br/>    #      makes https://<domain>/ present a valid cert out of the box, even before<br/>    #      Tutor/Open edX creates any TLS-enabled Ingress resources.<br/>    # See: https://kubernetes.github.io/ingress-nginx/user-guide/tls/#default-ssl-certificate<br/>    enable_default_tls_certificate = optional(bool, true)<br/>    default_tls_secret_name        = optional(string, "harmony-default-tls")<br/>  })</pre> | `{}` | no |
| <a name="input_hcloud_network_cidr"></a> [hcloud\_network\_cidr](#input\_hcloud\_network\_cidr) | IPv4 address range for the Hetzner private network in CIDR notation | `string` | `"10.0.0.0/16"` | no |
| <a name="input_hcloud_network_zone"></a> [hcloud\_network\_zone](#input\_hcloud\_network\_zone) | Hetzner network zone encompassing all node locations (must cover every datacenter in node\_locations) | `string` | `"eu-central"` | no |
| <a name="input_health_check_urls"></a> [health\_check\_urls](#input\_health\_check\_urls) | HTTP(S) URLs to check after cluster operations (upgrade, restore).<br/>Each URL must return 2xx/3xx to pass. Empty list skips HTTP checks.<br/>For OpenEdx: ["https://yourdomain.com/heartbeat"]<br/>The /heartbeat endpoint validates MySQL, MongoDB, and app availability. | `list(string)` | `[]` | no |
| <a name="input_k8s_api_allowed_cidrs"></a> [k8s\_api\_allowed\_cidrs](#input\_k8s\_api\_allowed\_cidrs) | CIDR blocks allowed to access the Kubernetes API (port 6443). Defaults to open for module usability; restrict in production. | `list(string)` | <pre>[<br/>  "0.0.0.0/0",<br/>  "::/0"<br/>]</pre> | no |
| <a name="input_kubernetes_version"></a> [kubernetes\_version](#input\_kubernetes\_version) | Specific RKE2 release tag to deploy (e.g. 'v1.34.4+rke2r1'). Leave empty to pull the latest from the stable channel. | `string` | `"v1.34.4+rke2r1"` | no |
| <a name="input_letsencrypt_issuer"></a> [letsencrypt\_issuer](#input\_letsencrypt\_issuer) | Contact email address registered with the ACME provider (Let's Encrypt) for certificate lifecycle and revocation alerts | `string` | `""` | no |
| <a name="input_load_balancer_location"></a> [load\_balancer\_location](#input\_load\_balancer\_location) | Hetzner datacenter location where both load balancers will be provisioned (e.g. 'hel1', 'nbg1', 'fsn1') | `string` | `"hel1"` | no |
| <a name="input_master_node_image"></a> [master\_node\_image](#input\_master\_node\_image) | OS image identifier for control-plane servers (e.g. 'ubuntu-24.04') | `string` | `"ubuntu-24.04"` | no |
| <a name="input_master_node_locations"></a> [master\_node\_locations](#input\_master\_node\_locations) | Optional list of Hetzner locations to place control-plane nodes. If empty, node\_locations is used. Why: allows masters spread across multiple cities while keeping workers in a subset (e.g., Germany-only). | `list(string)` | `[]` | no |
| <a name="input_master_node_server_type"></a> [master\_node\_server\_type](#input\_master\_node\_server\_type) | Hetzner Cloud server type for control-plane nodes (e.g. 'cx23', 'cx33', 'cx43'). | `string` | `"cx23"` | no |
| <a name="input_nginx_ingress_proxy_body_size"></a> [nginx\_ingress\_proxy\_body\_size](#input\_nginx\_ingress\_proxy\_body\_size) | Default max request body size for the nginx ingress controller. Set to 100m for Harmony/Open edX compatibility (course uploads). | `string` | `"100m"` | no |
| <a name="input_node_locations"></a> [node\_locations](#input\_node\_locations) | (Deprecated) Fallback placement locations when master\_node\_locations/worker\_node\_locations are unset. All entries must share the same network zone. | `list(string)` | <pre>[<br/>  "hel1",<br/>  "nbg1",<br/>  "fsn1"<br/>]</pre> | no |
| <a name="input_rke2_cluster_name"></a> [rke2\_cluster\_name](#input\_rke2\_cluster\_name) | Identifier prefix for all provisioned resources (servers, load balancers, network, firewall rules). Must be lowercase alphanumeric, max 20 characters. | `string` | `"rke2"` | no |
| <a name="input_route53_zone_id"></a> [route53\_zone\_id](#input\_route53\_zone\_id) | Hosted zone identifier in Route53. Required when create\_dns\_record is true. | `string` | `""` | no |
| <a name="input_save_ssh_key_locally"></a> [save\_ssh\_key\_locally](#input\_save\_ssh\_key\_locally) | Persist the auto-generated SSH private key to the local filesystem for manual node access | `bool` | `false` | no |
| <a name="input_ssh_allowed_cidrs"></a> [ssh\_allowed\_cidrs](#input\_ssh\_allowed\_cidrs) | CIDR blocks allowed to access SSH (port 22) on cluster nodes. Defaults to open because the module's provisioners require SSH to master[0]. Restrict to your runner/bastion CIDR in production (e.g. ['1.2.3.4/32']). | `list(string)` | <pre>[<br/>  "0.0.0.0/0",<br/>  "::/0"<br/>]</pre> | no |
| <a name="input_subnet_address"></a> [subnet\_address](#input\_subnet\_address) | Subnet allocation for cluster nodes in CIDR notation. Must fall within the hcloud\_network\_cidr range. | `string` | `"10.0.1.0/24"` | no |
| <a name="input_worker_node_image"></a> [worker\_node\_image](#input\_worker\_node\_image) | OS image identifier for agent (worker) servers | `string` | `"ubuntu-24.04"` | no |
| <a name="input_worker_node_locations"></a> [worker\_node\_locations](#input\_worker\_node\_locations) | Optional list of Hetzner locations to place worker nodes. If empty, node\_locations is used. Why: lets you keep workload I/O local (e.g., Germany-only) while masters can span more regions. | `list(string)` | `[]` | no |
| <a name="input_worker_node_server_type"></a> [worker\_node\_server\_type](#input\_worker\_node\_server\_type) | Hetzner Cloud server type for worker nodes (e.g. 'cx23', 'cx33', 'cx43'). | `string` | `"cx23"` | no |
### Outputs

| Name | Description |
|------|-------------|
| <a name="output_client_cert"></a> [client\_cert](#output\_client\_cert) | The client certificate for cluster authentication (PEM-encoded) |
| <a name="output_client_key"></a> [client\_key](#output\_client\_key) | The client private key for cluster authentication (PEM-encoded) |
| <a name="output_cluster_ca"></a> [cluster\_ca](#output\_cluster\_ca) | The cluster CA certificate (PEM-encoded) |
| <a name="output_cluster_host"></a> [cluster\_host](#output\_cluster\_host) | The Kubernetes API server endpoint URL |
| <a name="output_cluster_issuer_name"></a> [cluster\_issuer\_name](#output\_cluster\_issuer\_name) | The name of the cert-manager ClusterIssuer created by this module |
| <a name="output_cluster_master_nodes_ipv4"></a> [cluster\_master\_nodes\_ipv4](#output\_cluster\_master\_nodes\_ipv4) | The public IPv4 addresses of all master (control plane) nodes |
| <a name="output_cluster_worker_nodes_ipv4"></a> [cluster\_worker\_nodes\_ipv4](#output\_cluster\_worker\_nodes\_ipv4) | The public IPv4 addresses of all worker nodes |
| <a name="output_control_plane_lb_ipv4"></a> [control\_plane\_lb\_ipv4](#output\_control\_plane\_lb\_ipv4) | The IPv4 address of the control-plane load balancer (K8s API, registration) |
| <a name="output_etcd_backup_enabled"></a> [etcd\_backup\_enabled](#output\_etcd\_backup\_enabled) | Whether automated etcd snapshots with S3 upload are enabled |
| <a name="output_ingress_lb_ipv4"></a> [ingress\_lb\_ipv4](#output\_ingress\_lb\_ipv4) | The IPv4 address of the ingress load balancer (HTTP/HTTPS). Null when harmony is disabled. |
| <a name="output_kube_config"></a> [kube\_config](#output\_kube\_config) | The full kubeconfig file content for cluster access |
| <a name="output_longhorn_enabled"></a> [longhorn\_enabled](#output\_longhorn\_enabled) | Whether Longhorn distributed storage is enabled (experimental) |
| <a name="output_management_network_id"></a> [management\_network\_id](#output\_management\_network\_id) | The ID of the Hetzner Cloud private network |
| <a name="output_management_network_name"></a> [management\_network\_name](#output\_management\_network\_name) | The name of the Hetzner Cloud private network |
| <a name="output_storage_driver"></a> [storage\_driver](#output\_storage\_driver) | Primary storage driver: 'longhorn' if Longhorn is enabled, 'hcloud-csi' otherwise |
<!-- END_TF_DOCS -->

## Quality Gate Pipeline

The CI pipeline implements a **layered quality gate** model — each layer catches progressively deeper issues:

```
Gate 0 ─ Static Analysis     fmt · validate · tflint · Checkov · KICS · tfsec
Gate 1 ─ Unit Tests           variables · guardrails · conditionals · examples
Gate 2 ─ Integration          tofu plan against real providers (requires secrets)
Gate 3 ─ E2E                  tofu apply + smoke tests + destroy (manual only)
```

### Workflow Architecture

Every tool runs in its own GitHub Actions workflow file with its own badge:

| Gate | Category | Workflows | Trigger | Blocking |
|:----:|----------|-----------|---------|:--------:|
| 0a | Lint | `lint-fmt.yml`, `lint-validate.yml`, `lint-tflint.yml` | push + PR | Yes |
| 0b | SAST | `sast-checkov.yml`, `sast-kics.yml`, `sast-tfsec.yml` | push + PR | Checkov/KICS: Yes, tfsec: best-effort |
| 1 | Unit | `unit-variables.yml`, `unit-guardrails.yml`, `unit-conditionals.yml`, `unit-examples.yml` | push + PR | Yes |
| 2 | Integration | `integration-plan.yml` | PR + manual | No (requires cloud secrets) |
| 3 | E2E | `e2e-apply.yml` | Manual only | No (requires cost confirmation) |

### Execution Details

- **Gate 0–1** run on every push to `main` and every PR — fully offline, zero cost, ~30s total
- **Gate 2** runs `tofu plan` in `examples/minimal/` with real Hetzner + AWS credentials; skipped when `HAS_CLOUD_CREDENTIALS` repo variable is not `true`
- **Gate 3** provisions real infrastructure (`tofu apply`), runs smoke tests (`kubectl get nodes`), then cleans up (`tofu destroy`); requires manual dispatch with cost confirmation checkbox
- **84 unit tests** use `tofu test` with `mock_provider` — no cloud credentials needed

See [tests/README.md](tests/README.md) for detailed test strategy, coverage traceability, and mock provider workarounds.

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for:

- Design philosophy and engineering objectives
- Infrastructure topology diagrams
- Security model and compromise log
- Roadmap

## License

[MIT](LICENSE)
