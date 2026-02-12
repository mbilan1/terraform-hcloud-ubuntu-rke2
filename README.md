<div align="center" width="100%">
    <h2>hcloud rke2 module</h2>
    <p>Enterprise-grade RKE2 Kubernetes cluster on Hetzner Cloud, purpose-built for Open edX deployments in Europe.</p>
    <a target="_blank" href="https://github.com/mbilan1/terraform-hcloud-rke2/releases"><img src="https://img.shields.io/github/v/release/mbilan1/terraform-hcloud-rke2?display_name=tag" /></a>
    <a target="_blank" href="https://github.com/mbilan1/terraform-hcloud-rke2/commits/main"><img src="https://img.shields.io/github/last-commit/mbilan1/terraform-hcloud-rke2" /></a>
</div>

> **This is a fork of [wenzel-felix/terraform-hcloud-rke2](https://github.com/wenzel-felix/terraform-hcloud-rke2).**
> The original module is available on the [Terraform Registry](https://registry.terraform.io/modules/wenzel-felix/rke2/hcloud/latest).

## 🎯 Mission

The primary goal of this module is to provide an **enterprise-grade, cost-effective, and secure Kubernetes cluster** optimized for deploying [Open edX](https://openedx.org/) in Europe via [openedx-k8s-harmony](https://github.com/openedx/openedx-k8s-harmony).

By running on **Hetzner Cloud** — a European infrastructure provider with data centers in Germany and Finland — this module supports **European digital sovereignty**: student data, course content, and platform operations stay within EU jurisdiction, fully compliant with GDPR and European data protection regulations.

**Key principles:**
- **Open edX-first** — every default, dependency version, and architectural decision is aligned with the Harmony chart and Tutor deployment workflow
- **Affordable** — Hetzner Cloud offers some of the best price-to-performance ratios in Europe, making production-grade Open edX accessible to universities, NGOs, and small enterprises
- **Fast** — a fully operational cluster with all prerequisites (ingress, cert-manager, CSI, monitoring, Harmony) deploys in under 15 minutes
- **Secure** — hardened firewall rules, TLS everywhere via cert-manager + Let's Encrypt, OTel collector with least-privilege security context, sensitive outputs marked as such
- **Sovereign** — EU-hosted infrastructure, no dependency on US hyperscalers for compute or storage

## Changes from upstream

This fork includes the following improvements over the original module:

### Reliability
- **Cluster readiness check** — replaced `time_sleep` with a two-phase `null_resource` that polls `/readyz` and waits for all nodes to report `Ready` status before deploying workloads
- **Firewall attachment fix** — removed `hcloud_firewall_attachment` (only one per firewall allowed by the provider); firewall is now bound via `firewall_ids` on each `hcloud_server`, fixing `tofu destroy` race conditions
- **cert-manager helm fix** — use `crds.enabled` + `crds.keep` (correct for v1.19.x), increased timeout to 600s and `startupapicheck.timeout` to 5m
- **Load balancer health checks** — HTTP `/healthz` for K8s API (6443), TCP for SSH (22), RKE2 registration (9345), and custom ports

### DNS & TLS
- **Replaced Cloudflare with AWS Route53** — DNS records are now created via `aws_route53_record` in a Route53 hosted zone
- **cert-manager ClusterIssuer** — uses Route53 DNS-01 solver; ClusterIssuer named `harmony-letsencrypt-global` by default for compatibility with [openedx-k8s-harmony](https://github.com/openedx/openedx-k8s-harmony) (configurable via `cluster_issuer_name`)
- **Supports both explicit and IAM credentials** — pass `aws_access_key`/`aws_secret_key` or rely on default AWS credentials chain (IRSA, instance profile, env vars)

### Harmony (Open edX) compatibility
- **ClusterIssuer name `harmony-letsencrypt-global`** — matches the name hardcoded in Harmony's Tutor plugin `k8s-services` patch (`cert-manager.io/cluster-issuer: harmony-letsencrypt-global`); configurable via `cluster_issuer_name` variable
- **IngressClass `nginx`** — RKE2's built-in `rke2-ingress-nginx` provides IngressClass `nginx`, matching Harmony's `K8S_HARMONY_INGRESS_CLASS_NAME` default
- **cert-manager v1.19.3 with CRDs** — installed via Helm with `crds.enabled: true`, `crds.keep: true`, ClusterIssuer uses DNS-01 solver (Route53) for wildcard certificate support. Version synced with Harmony's cert-manager dependency
- **kube-prometheus-stack v81.0.1** — version synced with Harmony's `prometheusstack` dependency to avoid CRD conflicts
- **metrics-server** — provided by RKE2's built-in `rke2-metrics-server`
- **Hetzner CSI driver** — provides `hcloud-volumes` StorageClass (default) for persistent volumes required by Open edX (MySQL, MongoDB, Elasticsearch, Meilisearch PVCs); installed via Helm chart from `charts.hetzner.cloud`
- **proxy-body-size** — nginx ingress controller defaults to `100m` (matching Harmony's ingress annotation `nginx.ingress.kubernetes.io/proxy-body-size: 100m`), configurable via `nginx_ingress_proxy_body_size`
- **ssl-redirect** — monitoring ingress annotated with `nginx.ingress.kubernetes.io/ssl-redirect: "true"`
- **Harmony values output** — `harmony_recommended_values` output provides a ready-to-use `values.yaml` snippet for the Harmony Helm chart (includes `prometheusstack.enabled: false`)

### Security
- **Firewall rules** — proper ingress rules for all required ports; internal-only access for etcd, kubelet, RKE2 registration, and NodePort ranges
- **Sensitive variables** — `sensitive = true` on `hetzner_token`, `aws_access_key`, `aws_secret_key`, and all credential outputs
- **OTel collector hardening** — pinned image by digest, `runAsNonRoot`, `readOnlyRootFilesystem`, `drop ALL` capabilities, `seccompProfile: RuntimeDefault`, resource requests/limits, liveness/readiness probes

### Bug fixes
- **network.tf** — subnet was incorrectly using `network_address` instead of `subnet_address`
- **rke-master.sh.tpl** — fixed `kube-proxy` → `kube-proxy-arg`, OIDC condition `!= null` → `!= ""`, added `set -euo pipefail`
- **rke-worker.sh.tpl** — added `set -euo pipefail` and error handling
- **ssh.tf** — renamed `local_file "name"` → `"ssh_private_key"`
- **OIDC ingress** — moved from `default` to `kube-system` namespace, fixed count condition to use bool type

### Code quality
- Added `required_version >= 1.5.0` and declared all implicit providers with version constraints
- Added input validations: domain non-empty, `master_node_count` prevents split-brain (must be 1 or >= 3)
- Added descriptions to all outputs
- Updated defaults: `ubuntu-24.04`, `cx23`, three-location spread (`hel1`, `nbg1`, `fsn1`)
- Normalized all files to Unix (LF) line endings
- Clean pass: `tofu fmt`, `tofu validate`, `tflint`
- Security aligned with Trivy, Checkov, and KICS best practices

## ✨ Features

- Create a robust Kubernetes cluster deployed to multiple zones
- Fast and easy to use
- Available as module

## 🤔 Why?

There are existing Kubernetes projects with Terraform on Hetzner Cloud, but they often seem to have a large overhead of code. This project focuses on creating an integrated Kubernetes experience for Hetzner Cloud with high availability and resilience while keeping a small code base. 

## 🔧 Prerequisites

There are no special prerequirements in order to take advantage of this module. Only things required are:
* a Hetzner Cloud account
* access to Terraform
* (Optional) If you want DNS and TLS certificate management you need an AWS account with a Route53 hosted zone

## 🚀 Usage

### Standalone

``` bash
terraform init
terraform apply
```

### As module

Refer to the module registry documentation [here](https://registry.terraform.io/modules/wenzel-felix/rke2/hcloud/latest).

## Maintain/upgrade your cluster (API server)

### Change node size / Change node operating system / Upgrade cluster version
Change the Terraform variable to the desired configuration, then go to the Hetzner Cloud UI and remove one master at a time and apply the configuration after each.
To ensure minimal downtime while you upgrade the cluster consider [draining the node](https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/) you plan to replace/upgrade.

_Note:_ For upgrading your cluster version please review any breaking changes on the [official rke2 repository](https://github.com/rancher/rke2/releases).

## Deploying Open edX with Harmony

This module is pre-aligned with [openedx-k8s-harmony](https://github.com/openedx/openedx-k8s-harmony). The following components are already provided by the RKE2 cluster and **must be disabled** in the Harmony chart:

| Component | Provided by | Harmony setting |
|---|---|---|
| ingress-nginx | RKE2 built-in (`rke2-ingress-nginx`, IngressClass: `nginx`) | `ingress-nginx.enabled: false` |
| cert-manager | This Terraform module (namespace: `cert-manager`) | `cert-manager.enabled: false` |
| ClusterIssuer | This module (`harmony-letsencrypt-global`, DNS-01/Route53) | — (auto-discovered by name) |
| metrics-server | RKE2 built-in (`rke2-metrics-server`) | `metricsserver.enabled: false` |
| kube-prometheus-stack | This Terraform module (namespace: `monitoring`, v81.0.1) | `prometheusstack.enabled: false` |
| Hetzner CSI driver | This Terraform module (StorageClass: `hcloud-volumes`) | — (default StorageClass for PVCs) |

### Step 1: Deploy the cluster

```hcl
module "rke2" {
  source             = "mbilan1/rke2/hcloud"
  hetzner_token      = var.hetzner_token
  domain             = "example.com"
  master_node_count  = 3
  worker_node_count  = 2
  create_dns_record  = true
  route53_zone_id    = var.route53_zone_id
  letsencrypt_issuer = "admin@example.com"

  cluster_configuration = {
    hcloud_controller = { preinstall = true }
    hcloud_csi        = { preinstall = true, default_storage_class = true }
    cert_manager      = { preinstall = true }
  }
}
```

### Step 2: Install the Harmony chart

Use the `harmony_recommended_values` output as a starting point:

```bash
terraform output -raw harmony_recommended_values > harmony-values.yaml
```

Install the chart:

```bash
helm repo add harmony https://openedx.github.io/openedx-k8s-harmony
helm install harmony harmony/harmony-chart \
  --namespace harmony --create-namespace \
  -f harmony-values.yaml
```

### Step 3: Deploy Tutor instances

Install the Harmony Tutor plugin and configure your instance:

```bash
pip install tutor-contrib-harmony-plugin
tutor plugins enable k8s_harmony
tutor config save
tutor k8s launch
```

The plugin automatically creates Ingress resources with:
- `cert-manager.io/cluster-issuer: harmony-letsencrypt-global` — matched by this module's ClusterIssuer
- `ingressClassName: nginx` — matched by RKE2's built-in ingress controller
- `nginx.ingress.kubernetes.io/proxy-body-size: 100m` — matched by this module's ingress controller default
