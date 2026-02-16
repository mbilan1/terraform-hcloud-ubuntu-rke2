# Architecture Document

> **Module**: `terraform-hcloud-rke2`
> **Status**: **Experimental** — under active development, not production-ready
> **Target**: Enterprise-grade, best-practice aligned (aspirational)
> **Last updated**: 2026-02-13

---

## Table of Contents

- [Design Philosophy](#design-philosophy)
- [Module Core](#module-core)
- [Infrastructure Topology](#infrastructure-topology)
- [Kubernetes Addon Stack](#kubernetes-addon-stack)
- [Deployment Flow](#deployment-flow)
- [Security Model](#security-model)
- [Why Ubuntu](#why-ubuntu)
- [Why Hetzner Cloud](#why-hetzner-cloud)
- [Why RKE2](#why-rke2)
- [Dual Load Balancer Architecture](#dual-load-balancer-architecture)
- [High Availability](#high-availability)
- [CI Quality Gates](#ci-quality-gates)
- [Compromise Log](#compromise-log)
- [Roadmap](#roadmap)
- [Out of Scope](#out-of-scope)

---

## Design Philosophy

This module is guided by six **engineering objectives**. These are practical design targets, each tied to concrete implementation choices and explicit limitations.

```mermaid
block-beta
    columns 1

    space

    block:principles["Engineering Objectives"]:1
        columns 6
        security["🔒 Security\nBaseline"]:1
        simplicity["⚡ Operator\nEfficiency"]:1
        sovereignty["🇪🇺 Cost-Effective\nEU Hosting"]:1
        community["🤝 Open edX\nCompatibility"]:1
        selfhealing["♻️ Resilience\n(HA Scope)"]:1
        excellence["📐 Incremental\nHardening"]:1
    end

    space

    foundation["terraform-hcloud-rke2"]:1

    style security fill:#e74c3c,color:#fff
    style simplicity fill:#e67e22,color:#fff
    style sovereignty fill:#f1c40f,color:#2c3e50
    style community fill:#2ecc71,color:#fff
    style selfhealing fill:#3498db,color:#fff
    style excellence fill:#9b59b6,color:#fff
    style foundation fill:#2c3e50,color:#fff
    style principles fill:#ecf0f1,stroke:#bdc3c7
```

| Principle | Meaning |
|-----------|---------|
| **Security Baseline** | Encryption at rest, TLS automation, private networking, and explicit firewall controls are enabled by default. Production hardening is still required (CIDR restriction, bastion/VPN, policy layers). |
| **Operator Efficiency** | The recommended topology is designed for single-command bootstrap with sensible defaults. Non-standard combinations are supported, but may require explicit configuration. |
| **Cost-Effective EU Hosting** | The default topology targets pragmatic HA in EU regions (~€38/mo for 3×cx22 masters + 3×cx22 workers + 2×lb11, including IPv4 costs). Actual monthly total depends on IPv4, storage volumes, and traffic. Workloads remain portable at the Kubernetes layer. |
| **Open edX Compatibility** | Defaults align with Open edX ecosystem conventions (ClusterIssuer naming, ingress behavior, cert-manager expectations) while keeping the module usable outside Open edX. |
| **Resilience (HA Scope)** | Automated node reboots and Kubernetes upgrade workflows are available for HA clusters. Backup/DR and incident response remain operator responsibilities. |
| **Incremental Hardening** | Improvements are delivered in verifiable steps. Trade-offs are documented in the Compromise Log, and planned controls are explicitly marked as planned. |

### Technology Choices

Each objective maps to specific, opinionated implementation choices:

| Objective | Implementation |
|-----------|---------------|
| Security Baseline | RKE2 (CIS hardened, FIPS-capable), secrets encryption at rest, Hetzner firewall, RSA 4096 SSH keys, private network isolation |
| Operator Efficiency | Single `tofu apply`, Helm-managed addon lifecycle, auto-generated SSH keys, `terraform-docs` integration |
| Cost-Effective EU Hosting | Hetzner Cloud EU (Nuremberg, Falkenstein, Helsinki), GDPR-native, ~€38/mo for 3×cx22 masters + 3×cx22 workers + 2×lb11 (non-default HA config) |
| Open edX Compatibility | Ubuntu 24.04 LTS (AppArmor for codejail), openedx-k8s-harmony chart, `harmony-letsencrypt-global` ClusterIssuer convention |
| Resilience (HA Scope) | Kured (auto-reboot, HA only), System Upgrade Controller (K8s upgrades, HA only), RKE2 embedded etcd snapshots |
| Incremental Hardening | IaC patterns, `terraform-docs`, `.pre-commit-config.yaml`, and a documented Compromise Log; CI security scanning remains planned work |

The primary constraint is Hetzner Cloud platform limitations and the balance between custom-built complexity and off-the-shelf pragmatism.

---

## Module Core

```
┌─────────────────────────────────────────────────┐
│            terraform-hcloud-rke2                │
│                                                 │
│   Ubuntu 24.04 LTS (Hetzner ISO)               │
│   + RKE2 (Rancher Kubernetes Engine v2)         │
│   + openedx-k8s-harmony (opt-in)                │
│                                                 │
│   Can operate independently of Open edX,        │
│   but is adopted for and oriented toward it.    │
└─────────────────────────────────────────────────┘
```

The module's core is **Ubuntu + RKE2** — a production-oriented Kubernetes cluster on Hetzner Cloud. It can operate as a standalone Kubernetes platform for diverse workloads.

The **openedx-k8s-harmony** chart integration is the module's primary adoption target. The built-in compatibility with [Open edX](https://openedx.org/) community standards (ClusterIssuer naming, IngressClass conventions, cert-manager version alignment, proxy-body-size defaults) is a tribute to the Open edX community and a reflection of the module's origin: deploying production Open edX instances on Kubernetes with best practices and security.

This module was originally forked from [wenzel-felix/terraform-hcloud-rke2](https://github.com/wenzel-felix/terraform-hcloud-rke2) — the only proven working solution combining Hetzner Cloud + Ubuntu + RKE2 at the time. The architecture and idea were sound; this fork focuses on production hardening, clearer guardrails, and Open edX alignment, with enterprise controls still evolving.

> **⚠️ First deploy warning**: The module still needs production hardening after bootstrap:
> - defaults create `master_node_count = 3`, `worker_node_count = 3` (HA baseline)
> - `harmony.enabled = false` by default — enable Harmony explicitly for Open edX
> - `ssh_allowed_cidrs` and `k8s_api_allowed_cidrs` default to `0.0.0.0/0` (open to the internet)
>
> A production-ready minimum: 3 masters, 3+ workers, restricted CIDRs.

---

## Infrastructure Topology

```mermaid
flowchart TB
    subgraph internet["Internet"]
        users["👤 Users / Students"]
        operator["🔧 Operator / CI Runner"]
    end

    subgraph hetzner["Hetzner Cloud (EU)"]
        subgraph lb_layer["Load Balancers"]
            cp_lb["Control Plane LB\nlb11\n6443 / 9345 / 22 (opt-in)"]
            ingress_lb["Ingress LB\nlb11\n80 / 443"]
        end

        subgraph fw["Firewall"]
            cluster_fw["Cluster Firewall\n80, 443 (public)\n22, 6443 (configurable CIDR)\n9345, 2379-2380, 10250 (private)\n30000-32767 (private)"]
        end

        subgraph dc1["DC: Helsinki (hel1)"]
            master1["master-0\nUbuntu 24.04\nRKE2 Server\netcd member"]
        end

        subgraph dc2["DC: Nuremberg (nbg1)"]
            master2["master-1\nUbuntu 24.04\nRKE2 Server\netcd member"]
        end

        subgraph dc3["DC: Falkenstein (fsn1)"]
            master3["master-2\nUbuntu 24.04\nRKE2 Server\netcd member"]
        end

        subgraph workers["Worker Pool"]
            worker1["Worker 1\nUbuntu 24.04\nRKE2 Agent\ningress-nginx"]
            worker2["Worker 2\nUbuntu 24.04\nRKE2 Agent\ningress-nginx"]
            workerN["Worker N\n..."]
        end

        subgraph network["Private Network (10.0.0.0/16)"]
            subnet["Subnet 10.0.1.0/24"]
        end
    end

    subgraph aws["AWS"]
        r53["Route53\nDNS Hosted Zone\n*.domain → Ingress LB"]
    end

    subgraph letsencrypt["Let's Encrypt"]
        acme["ACME v2\nDNS-01 / HTTP-01"]
    end

    users -->|"HTTPS :443"| ingress_lb
    operator -->|"kubectl :6443"| cp_lb
    operator -.->|"SSH :22"| cp_lb

    cp_lb --> master1
    cp_lb --> master2
    cp_lb --> master3

    ingress_lb --> worker1
    ingress_lb --> worker2
    ingress_lb --> workerN

    master1 --- subnet
    master2 --- subnet
    master3 --- subnet
    worker1 --- subnet
    worker2 --- subnet
    workerN --- subnet

    r53 -.->|"DNS resolution"| ingress_lb
    acme -.->|"TLS certificates"| ingress_lb
```

### Key Points

- **3 master nodes across 3 data centers** (Helsinki, Nuremberg, Falkenstein) — default order from `node_locations = ["hel1", "nbg1", "fsn1"]`. All within the `eu-central` network zone but in separate physical locations for datacenter-level fault tolerance.
- **Dedicated worker pool** for application workloads with ingress-nginx running as DaemonSet using hostPort.
- **Dual load balancer** architecture — control plane and ingress traffic are isolated (see [Dual LB Architecture](#dual-load-balancer-architecture)).
- **Private network** for all inter-node communication (etcd, kubelet, pod traffic via CNI overlay).
- **DNS via AWS Route53** — wildcard `*.domain` record pointing to the ingress LB. This is a temporary solution and will be replaced with a more sovereignty-aligned DNS provider in a future iteration.
- **⚠️ DNS depends on Harmony** — `create_dns_record = true` points DNS to the ingress LB, which exists only when `harmony.enabled = true`. The module now enforces this with an explicit preflight `check`.
- **No egress filtering** — all outbound traffic from nodes is unrestricted (Hetzner default). Egress firewall rules are not currently implemented.

---

## Kubernetes Addon Stack

```mermaid
flowchart TB
    subgraph k8s["Kubernetes Cluster (RKE2)"]
        subgraph system["kube-system"]
            hccm["Hetzner CCM\n(cloud-controller-manager)"]
            csi["Hetzner CSI\n(persistent volumes)"]
            rke2_ingress["RKE2 Ingress\n(when Harmony disabled)"]
        end

        subgraph certmgr["cert-manager"]
            cm["cert-manager\nv1.19.x"]
            issuer["ClusterIssuer\nharmony-letsencrypt-global\nDNS-01 (Route53)"]
        end

        subgraph harmony_ns["harmony"]
            harmony["Harmony Chart\n(openedx-k8s-harmony)"]
            nginx["ingress-nginx\nDaemonSet + hostPort"]
        end

        subgraph maintenance["Self-Maintenance (HA only)"]
            kured["Kured\n(auto-reboot)"]
            suc["System Upgrade Controller\n(K8s version upgrades)"]
        end
    end

    cm --> issuer
    harmony --> nginx
    harmony --> cm
```

| Component | Role | Always Installed | Notes |
|-----------|------|:---:|-------|
| **Hetzner CCM** | Cloud controller (node lifecycle, LB integration) | Yes | Shared `hcloud` secret with CSI |
| **Hetzner CSI** | Persistent volumes (`hcloud-volumes` StorageClass) | Yes | Required for Open edX PVCs (MySQL, Mongo, etc.) |
| **cert-manager** | TLS certificate automation | Yes | ClusterIssuer name matches Harmony convention |
| **Harmony** | Open edX Kubernetes orchestration | Opt-in | `harmony.enabled` defaults to `false`. When enabled, it disables RKE2 built-in ingress and deploys Harmony ingress-nginx. |
| **Kured** | Automatic node reboot after OS updates | HA only | Skipped on single-master clusters |
| **System Upgrade Controller** | Automated K8s version upgrades | HA only | Follows `stable` channel |

---

## Deployment Flow

```mermaid
flowchart LR
    subgraph phase1["Phase 1: Infrastructure"]
        direction TB
        net["Network + Subnet"]
        fw["Firewall"]
        ssh["SSH Key"]
        lb["Load Balancers"]
        m0["master-0"]
        net --> fw --> m0
        ssh --> m0
        lb --> m0
    end

    subgraph phase2["Phase 2: Cluster Formation"]
        direction TB
        reg["LB Registration\nService :9345"]
        addm["Additional Masters\n(master-1, master-2)"]
        wrk["Workers"]
        api["wait_for_api\n(SSH provisioner)"]
        ready["wait_for_cluster_ready\n(all nodes Ready)"]
        reg --> addm
        reg --> wrk
        m0 -.-> api --> ready
    end

    subgraph phase3["Phase 3: Cluster Addons"]
        direction TB
        kubeconfig["Fetch kubeconfig\n(data.remote_file)"]
        hccm2["HCCM + CSI"]
        cm2["cert-manager\n+ ClusterIssuer"]
        harm2["Harmony Chart\n(ingress-nginx)"]
        kubeconfig --> hccm2 --> cm2 --> harm2
    end

    phase1 --> phase2 --> phase3
```

### Phase 1: Infrastructure (parallel)

1. **Network** — private network `10.0.0.0/16` with subnet `10.0.1.0/24`
2. **Firewall** — cluster-wide ingress rules (currently mixed-role; role-split hardening planned)
3. **SSH key** — auto-generated TLS key pair, uploaded to Hetzner
4. **Load balancers** — control-plane LB (always) + ingress LB (when Harmony enabled)
5. **master-0** — first control-plane node, bootstraps the cluster

### Phase 2: Cluster Formation (sequential)

6. **LB registration service** (port 9345) — enables additional nodes to join
7. **Additional masters** — join via LB → master-0 (etcd quorum formed)
8. **Workers** — join via LB → any master
9. **wait_for_api** — SSH into master-0, poll until API server responds (uses `null_resource` with SSH provisioner — a Terraform anti-pattern, but the only option without external tooling)
10. **wait_for_cluster_ready** — poll until all nodes report `Ready` (also via SSH provisioner)

### Phase 3: Cluster Addons (sequential, after kubeconfig fetch)

11. **Fetch kubeconfig** — downloaded from master-0 via SSH
12. **HCCM + CSI** — cloud integration (node labeling, persistent volumes)
13. **cert-manager** — TLS automation with Let's Encrypt ClusterIssuer
14. **Harmony** — Open edX platform chart with infrastructure-specific values

---

## Security Model

```mermaid
flowchart LR
    subgraph security["Security Layers"]
        direction TB
        L1["Layer 1: Infrastructure\nHetzner Firewall\nSSH key auth (RSA 4096)\nPrivate network isolation"]
        L2["Layer 2: Kubernetes\nRBAC · Pod Security Standards\nSecrets encryption at rest\nNetwork Policies"]
        L3["Layer 3: Application\ncert-manager TLS everywhere\nModSecurity WAF (Harmony-off only)"]
        L4["Layer 4: Operations\nSAST / IaC security scanning\nAudit logging\nAutomated OS patching (Kured)"]
        L1 --> L2 --> L3 --> L4
    end
```

### Principles

- **Security by default** — secrets encryption, SSH key auth, and TLS are enabled by default; network exposure defaults should be restricted for production.
- **Zero trust** — target state; explicit controls are in place, with additional policy layers (NetworkPolicy, audit) planned.
- **Least privilege** — partially implemented today (RBAC + explicit rules); firewall split by node role is planned.
- **Defense in depth** — multiple overlapping layers (network, K8s, application, operational)

### Layer 1: Infrastructure

| Control | Implementation | Status |
|---------|---------------|--------|
| Firewall | Hetzner Cloud Firewall with cluster-wide mixed-role rules; split-by-role hardening is planned | 🟡 Partially implemented |
| SSH authentication | Auto-generated RSA 4096 key pair, no password auth (Ed25519 migration planned) | ✅ Implemented |
| Network isolation | Private network for inter-node traffic | ✅ Implemented |
| SSH access restriction | Configurable `ssh_allowed_cidrs` | ✅ Implemented |
| K8s API restriction | Configurable `k8s_api_allowed_cidrs` | ✅ Implemented |
| Egress filtering | Not implemented — all outbound traffic is allowed (Hetzner default) | 🔲 Not implemented |

### Layer 2: Kubernetes

| Control | Implementation | Status |
|---------|---------------|--------|
| Secrets encryption at rest | RKE2 `secrets-encryption: true` | ✅ Implemented |
| RBAC | Kubernetes native RBAC | ✅ Built-in (RKE2) |
| Pod Security Standards | Admission controller | 🔲 Planned |
| Network Policies | Default deny + explicit allow | 🔲 Planned |

### Layer 3: Application

| Control | Implementation | Status |
|---------|---------------|--------|
| TLS everywhere | cert-manager + Let's Encrypt ClusterIssuer | ✅ Implemented |
| ModSecurity WAF | nginx ingress annotation (opt-in) | 🟡 Only when Harmony disabled |

> **⚠️ ModSecurity WAF limitation**: The `enable_nginx_modsecurity_waf` variable only takes effect when `harmony.enabled = false` (default). When Harmony is enabled, it deploys its own ingress-nginx without ModSecurity configuration. This is a known gap.

### Layer 4: Operations

| Control | Implementation | Status |
|---------|---------------|--------|
| SAST / security scanning | Checkov, KICS, tfsec (CI Gate 0b) | ✅ Implemented |
| Audit logging | K8s audit policy | 🔲 Planned |
| Automated OS patching | Kured (HA clusters only) | ✅ Implemented |
| K8s version upgrades | System Upgrade Controller (HA only) | ✅ Implemented |

### Important: What This Module Does NOT Cover

Security of the Ubuntu host OS itself (on which RKE2 runs) **must be addressed separately**. The module provisions the server and installs RKE2, but hardening the OS (sysctl tuning, unnecessary service removal, file permissions, PAM configuration) is the operator's responsibility.

Recommended approach: apply a hardening baseline via Ansible after provisioning — for example, the [dev-sec/ansible-collection-hardening](https://github.com/dev-sec/ansible-collection-hardening) collection.

The module's Terraform code, Helm charts, and Kubernetes manifests are continuously scanned via CI (Checkov, KICS, tfsec — see [CI Quality Gates](#ci-quality-gates)).

### Operational Limitations

- **SSH private key is not exposed as a module output.** To SSH into nodes for debugging, extract the key from Terraform state (`tls_private_key.machines.private_key_openssh`) or enable `generate_ssh_key_file = true` to write it to disk. Adding `ssh_private_key` as a sensitive output is planned.
- **Longer first apply for safer addon sequencing** — `data.remote_file.kubeconfig` now depends on `wait_for_cluster_ready` to avoid early addon races while workers are still joining. This improves determinism at the cost of slower initial provisioning.

---

## Why Ubuntu

Ubuntu is the chosen operating system for the following reasons:

1. **Open edX community standard** — Ubuntu is the [recommended distribution](https://docs.openedx.org/) for Open edX deployments, with the most thoroughly tested installation paths and community support.

2. **AppArmor compatibility** — Open edX's [codejail](https://github.com/openedx/codejail) plugin, which provides sandboxed code execution for student-facing embedded terminals in courses, requires **AppArmor** for process isolation. AppArmor is a Linux Security Module (LSM) that cannot coexist at the kernel level with **SELinux**, which is the mandatory LSM on all RHEL-family distributions (Fedora, CentOS, Rocky, Alma, SUSE). The Hetzner Cloud ISO mirror provides pre-built images with SELinux enabled by default on these distributions. Replacing SELinux with AppArmor would require rebuilding the ISO with different kernel parameters — adding significant operational complexity with no benefit.

3. **LTS release stability** — Ubuntu LTS releases (20.04 → 22.04 → 24.04) provide 5-year support cycles with a proven track record in production environments. The `apt` package manager and the built-in `do-release-upgrade` tool provide a safe upgrade path between LTS versions.

4. **Hetzner Cloud availability** — Ubuntu 24.04 is a first-class ISO image on Hetzner Cloud, maintained and updated by Hetzner's mirror infrastructure.

---

## Why Hetzner Cloud

1. **European sovereignty** — data centers in Germany (Nuremberg, Falkenstein) and Finland (Helsinki). Student data, course content, and platform operations stay within EU jurisdiction, fully compliant with GDPR.

2. **Cost efficiency** — Hetzner offers some of the best price-to-performance ratios in Europe. A production HA cluster (3 masters + 3 workers + 2 LBs) costs approximately **€38/month** — making production-grade Open edX accessible to universities, NGOs, and small enterprises.

3. **Controlled lock-in at infrastructure layer** — this module is intentionally optimized for Hetzner primitives (CCM, CSI, firewall/LB semantics). The workload and application layer (Open edX / Harmony on Kubernetes) remains portable.

---

## Why RKE2

[RKE2](https://docs.rke2.io/) (Rancher Kubernetes Engine v2) was chosen over alternatives (k3s, kubeadm, managed K8s services) for the following reasons:

1. **FIPS 140-2 compliance** — RKE2 is the only lightweight Kubernetes distribution that offers FIPS-validated cryptographic modules, relevant for government and regulated education deployments.

2. **CIS hardened by default** — RKE2 ships with CIS Kubernetes Benchmark profiles applied out of the box, reducing the security hardening burden.

3. **Built-in components** — includes ingress-nginx, metrics-server, and CoreDNS as managed Helm charts (HelmChartConfig CRD), reducing external dependencies.

4. **etcd embedded** — no separate etcd cluster to manage. RKE2 bundles etcd with automatic snapshotting.

5. **Stable release cadence** — follows upstream Kubernetes releases with a focus on stability over bleeding-edge features.

> **Note**: The module **pins** RKE2 by default via the `rke2_version` input (currently `v1.34.x`).
> This makes first deployments reproducible. If you explicitly set `rke2_version = ""`, the install script will use the upstream `stable` channel (less reproducible but sometimes desirable for quick trials).

---

## Dual Load Balancer Architecture

The module deploys **two separate Hetzner Cloud load balancers** instead of a single shared one:

| LB | Role | Targets | Ports | Always Created |
|----|------|---------|-------|:-:|
| **Control Plane** | K8s API + node registration | Masters only | 6443, 9345, 22 (opt-in via `enable_ssh_on_lb`, default off) | Yes |
| **Ingress** | HTTP/HTTPS application traffic | Workers only | 80, 443, custom | When Harmony enabled |

### Why Not a Single LB?

1. **Hetzner Cloud LBs do not support per-service target groups.** All targets receive health checks from ALL services. With a single LB, workers fail health checks for K8s API (6443) and registration (9345) — showing "yellow" status in Hetzner console. The false-negative health status defeats monitoring and alerting.

2. **DDoS blast radius isolation.** If the public-facing ingress LB is under attack and saturated, the separate control-plane LB remains reachable — operators can still `kubectl` into the cluster to mitigate the incident.

3. **Independent scaling and lifecycle.** The ingress LB can be upgraded to `lb21`/`lb31` under load without touching the control-plane path. Firewall rules differ: API LB should be restricted (VPN/bastion), ingress LB must be public.

4. **Industry standard.** This is the pattern used by AWS EKS (NLB for API + ALB for Ingress), GKE, and AKS.

**Trade-off:** +1 `lb11` ≈ €5.39/month. Acceptable for production workloads where operational clarity and security isolation outweigh the cost.

> **Note**: Both LBs use type `lb11` (hardcoded). To scale the ingress LB under load (`lb21`/`lb31`), the module source must be modified — LB type is not currently exposed as a variable.

---

## High Availability

### etcd Quorum

The module defaults to **3 master nodes** for production HA deployments:

| Masters | etcd Members | Fault Tolerance | Verdict |
|:-------:|:------------:|:---------------:|---------|
| 1 | 1 | 0 (any failure = cluster down) | Dev / learning only |
| 2 | 2 | 0 (split-brain risk, **rejected**) | ❌ Blocked by validation |
| 3 | 3 | 1 node can fail | ✅ Production minimum |
| 5 | 5 | 2 nodes can fail | Large-scale production |

### Geographic Distribution

Master nodes are deployed across **three Hetzner data centers**, all within the `eu-central` network zone:

| Node | Data Center | Location |
|------|-------------|----------|
| master-0 | `hel1` | Helsinki, Finland |
| master-1 | `nbg1` | Nuremberg, Germany |
| master-2 | `fsn1` | Falkenstein, Germany |

This provides **datacenter-level fault tolerance** — the loss of an entire DC leaves the cluster operational with 2/3 etcd members (quorum maintained).

### Self-Maintenance (HA only)

On HA clusters (≥ 3 masters), two self-maintenance systems are deployed:

- **Kured** — monitors for pending OS reboots (after `apt upgrade`) and reboots nodes one at a time, respecting pod disruption budgets.
- **System Upgrade Controller** — automates Kubernetes version upgrades via the `stable` channel, draining nodes before upgrade.

Both are **disabled on single-master clusters** because rebooting or upgrading the only control-plane node causes full downtime.

---

## CI Quality Gates

The module uses a **layered quality gate pipeline** in GitHub Actions. Each gate catches progressively deeper issues, and every tool has its own workflow file and badge in the README.

### Quality Gate Pyramid

```
                    ╱╲
                   ╱  ╲          Gate 3: E2E
                  ╱ E2E╲         Real infra, apply + smoke + destroy, manual only
                 ╱──────╲
                ╱        ╲       Gate 2: Integration
               ╱  Plan    ╲     tofu plan with real providers, PR + manual
              ╱────────────╲
             ╱              ╲    Gate 1: Unit Tests
            ╱  63 unit tests ╲   tofu test + mock_provider, every PR, ~3s, $0
           ╱──────────────────╲
          ╱                    ╲  Gate 0: Static Analysis
         ╱  fmt · validate ·    ╲ tflint · Checkov · KICS · tfsec
        ╱────────────────────────╲
```

### Workflow Inventory

| Gate | Badge Label | Workflow File | Trigger | Cost |
|:----:|-------------|---------------|---------|:----:|
| 0a | Lint: fmt | `lint-fmt.yml` | push + PR | $0 |
| 0a | Lint: validate | `lint-validate.yml` | push + PR | $0 |
| 0a | Lint: tflint | `lint-tflint.yml` | push + PR | $0 |
| 0b | SAST: Checkov | `sast-checkov.yml` | push + PR | $0 |
| 0b | SAST: KICS | `sast-kics.yml` | push + PR | $0 |
| 0b | SAST: tfsec | `sast-tfsec.yml` | push + PR | $0 |
| 1 | Unit: variables | `unit-variables.yml` | push + PR | $0 |
| 1 | Unit: guardrails | `unit-guardrails.yml` | push + PR | $0 |
| 1 | Unit: conditionals | `unit-conditionals.yml` | push + PR | $0 |
| 1 | Unit: examples | `unit-examples.yml` | push + PR | $0 |
| 2 | Integration: plan | `integration-plan.yml` | PR + manual | $0 (plan only) |
| 3 | E2E: apply | `e2e-apply.yml` | Manual only | ~$0.50/run |

### Naming Convention

All workflow files follow the pattern `{category}-{tool}.yml`:
- **Category**: `lint`, `sast`, `unit`, `integration`, `e2e`
- **Badge label**: `Category: Tool` (e.g., `Lint: fmt`, `SAST: Checkov`, `Unit: variables`)

This ensures each badge maps 1:1 to exactly one workflow and one tool.

### Execution Flow

```mermaid
flowchart LR
    subgraph gate0["Gate 0: Static Analysis"]
        direction TB
        fmt["tofu fmt -check"]
        validate["tofu validate"]
        tflint["tflint"]
        checkov["Checkov"]
        kics["KICS"]
        tfsec["tfsec"]
    end

    subgraph gate1["Gate 1: Unit Tests (63 tests)"]
        direction TB
        vars["variables.tftest.hcl\n23 tests"]
        guards["guardrails.tftest.hcl\n16 tests"]
        cond["conditional_logic.tftest.hcl\n22 tests"]
        examples["examples.tftest.hcl\n2 tests"]
    end

    subgraph gate2["Gate 2: Integration"]
        plan["tofu plan\nexamples/minimal/"]
    end

    subgraph gate3["Gate 3: E2E"]
        apply["tofu apply"]
        smoke["kubectl get nodes"]
        destroy["tofu destroy"]
        apply --> smoke --> destroy
    end

    gate0 --> gate1 --> gate2 --> gate3
```

### Unit Test Architecture

All 63 unit tests run **offline** using `tofu test` with `mock_provider`:

| Test File | Tests | Scope |
|-----------|:-----:|-------|
| `variables.tftest.hcl` | 23 | Every `validation {}` block with positive + negative cases |
| `guardrails.tftest.hcl` | 16 | Every `check {}` block (8/10 directly; 2 DNS untestable) |
| `conditional_logic.tftest.hcl` | 22 | Resource count assertions for all feature toggles |
| `examples.tftest.hcl` | 2 | Full-stack patterns (minimal, OpenEdX-Tutor) |

Key design decisions:
- **`mock_provider`** — all 11 providers mocked (hcloud, remote, aws, kubectl, kubernetes, helm, null, random, tls, local, http). Zero credentials, zero cost, ~3s total.
- **Plan-only** — tests run `command = plan`, never `apply`. No state, no side effects.
- **Per-file CI** — each test file has its own workflow using `tofu test -filter=tests/{file}.tftest.hcl` for granular badges.

See [tests/README.md](../tests/README.md) for detailed coverage traceability, mock workarounds, and test inventory.

### Integration & E2E Gates

**Integration (Gate 2):**
- Runs `tofu plan` in `examples/minimal/` with real Hetzner + AWS credentials
- Triggered on PRs and manual dispatch
- Skipped when `HAS_CLOUD_CREDENTIALS` repository variable is not `true`
- Validates provider compatibility and real resource planning without provisioning

**E2E (Gate 3):**
- Manual dispatch only with explicit cost confirmation checkbox
- Provisions real infrastructure in `examples/minimal/` (~$0.50/run)
- Runs smoke test: `kubectl get nodes` to verify cluster is operational
- Always destroys infrastructure on completion (even on failure)
- Full lifecycle: `init → plan → apply → smoke → destroy`

---

## Operations: Backup, Upgrade, Rollback

### Backup Strategy

The module implements a **two-layer backup architecture** separating cluster state from application data:

```
┌─────────────────────────────────────────────────────────┐
│                   Backup Targets                        │
│                                                         │
│  ┌──────────────────────┐  ┌─────────────────────────┐  │
│  │  Layer 1: etcd       │  │  Layer 2: PVC data      │  │
│  │  (cluster state)     │  │  (application data)     │  │
│  │                      │  │                          │  │
│  │  Mechanism: RKE2     │  │  Mechanism: Velero +     │  │
│  │  native snapshots    │  │  Kopia FSB               │  │
│  │                      │  │                          │  │
│  │  Config: cloud-init  │  │  Config: Helm release    │  │
│  │  (pre-K8s)           │  │  (requires running K8s)  │  │
│  └──────────┬───────────┘  └──────────┬──────────────┘  │
│             │                         │                  │
│             └─────────┬───────────────┘                  │
│                       ▼                                  │
│          Hetzner Object Storage (S3)                     │
│          {location}.your-objectstorage.com               │
│          Path-style only, 750 req/s limit                │
└─────────────────────────────────────────────────────────┘
```

#### Layer 1: etcd (RKE2 Native)

- **Mechanism:** RKE2's built-in `etcd-snapshot-schedule-cron` in `/etc/rancher/rke2/config.yaml`
- **Configured at:** cloud-init time (before Kubernetes starts)
- **S3 upload:** Optional, via `etcd-s3`, `etcd-s3-endpoint`, `etcd-s3-bucket` parameters
- **Path style:** `etcd-s3-bucket-lookup-type: path` (required for Hetzner Object Storage)
- **Retention:** `etcd-s3-retention` (RKE2 v1.34.0+, separate from local `etcd-snapshot-retention`)
- **Variable:** `cluster_configuration.etcd_backup`
- **See:** https://docs.rke2.io/datastore/backup_restore

#### Layer 2: PVC Data (Velero + Kopia)

- **Mechanism:** Velero Helm chart with Kopia file-system backup (FSB)
- **Why Kopia:** Hetzner CSI does not support VolumeSnapshot ([issue #849](https://github.com/hetznercloud/csi-driver/issues/849)). Restic was removed in Velero v1.17; Kopia is the sole uploader.
- **Plugin:** `velero-plugin-for-aws` v1.13.x (compatibility: v1.13.x ↔ Velero v1.17.x)
- **S3 workaround:** `checksumAlgorithm: ""` disables aws-chunked transfer encoding that Hetzner rejects ([issue #8660](https://github.com/vmware-tanzu/velero/issues/8660))
- **Variable:** `velero` (independent credentials from etcd_backup)
- **File:** `cluster-velero.tf` (self-contained addon with inline guardrails)

#### Design Decisions

| Decision | Rationale |
|----------|----------|
| Separate etcd + Velero layers | etcd backup is pre-K8s (cloud-init), Velero requires running cluster. Different failure modes, different recovery paths. |
| Separate S3 credentials | Module's self-contained addon pattern. Each addon owns its config. Operators share credentials at invocation level if desired. |
| Kopia over Restic | Restic removed in Velero v1.17. Kopia is faster (parallelized, content-defined chunking) and has been the default since v1.14. |
| `snapshotsEnabled: false` | Hetzner CSI has no VolumeSnapshot driver. Disabling prevents unavailable VolumeSnapshotLocation CRD error logs. |
| Path-style S3 | Hetzner Object Storage does not support virtual-hosted style. Both etcd and Velero require path-style configuration. |

### Upgrade Strategy

Upgrades follow a **snapshot-before-upgrade** pattern:

1. Pre-upgrade on-demand etcd snapshot (via System Upgrade Controller `prepare` hook)
2. Cordon + drain node
3. RKE2 binary upgrade (System Upgrade Controller)
4. Post-upgrade health check (`null_resource.cluster_health_check`)

If the health check fails, the operator can restore the pre-upgrade etcd snapshot.

### Rollback Strategy

Full etcd restore (not binary downgrade) is the recommended rollback path:

1. Stop RKE2 on all nodes
2. Restore etcd snapshot on master-0
3. Start master-0, wait for API
4. Restart additional masters + workers
5. Velero PVC restore (if needed)
6. Health check validation

**Why not binary downgrade:** Kubernetes API objects may have been migrated to newer schemas during upgrade. Binary downgrade leaves the cluster in an inconsistent state. etcd restore guarantees consistency.

---

## Compromise Log

The module contains many deliberate compromises. Each is documented in code comments at the point of implementation. Here is the summary:

| Decision | Compromise | Rationale |
|----------|-----------|-----------|
| SSH/API open by default | Security vs usability | Provisioners require SSH to master-0; blocking SSH causes `tofu apply` to hang. Follows terraform-aws-eks pattern. |
| Single firewall for all nodes | Granularity vs simplicity | A split firewall (master/worker) is planned. Current single firewall applies to all nodes — masters get HTTP/HTTPS rules they don't need, workers get etcd/API rules they don't need. Simpler to reason about and manage. |
| `null_resource` provisioners | Idempotency vs necessity | Provisioners are a Terraform anti-pattern, but are the only way to wait for cluster readiness and fetch kubeconfig without external tooling. |
| Providers inside module | Composability vs simplicity | Prevents provider aliasing and multi-account patterns. Provider extraction is planned as a breaking change. |
| Route53 for DNS | EU sovereignty vs maturity | Cloudflare was removed for sovereignty reasons. Route53 is a temporary solution — will be replaced with a more aligned provider. |
| `data.http` for CRD downloads | Reproducibility vs simplicity | Manifests are downloaded from GitHub at plan time by default. Operators can disable this path via `allow_remote_manifest_downloads = false` (requires disabling dependent features) for stricter/offline workflows. Vendoring into repo remains planned. |
| `harmony.enabled` default `false` | Convention vs safety | Harmony remains opt-in by default so the module can serve both generic Kubernetes and Open edX use cases. Open edX deployments must enable it explicitly. |
| master-0 replacement race | Bootstrap vs lifecycle | `INITIAL_MASTER` flag is set at server create-time via `user_data` and never re-evaluated (`ignore_changes = [user_data]`). **We intentionally do not hard-block destroy** in the module baseline to keep full lifecycle management possible (dev/test). For production, protect master-0 operationally (reviews, environment protections, targeted plans) and treat replacement as a deliberate maintenance event. |
| ModSecurity + Harmony gap | Integration vs complexity | `enable_nginx_modsecurity_waf` has no effect when `harmony.enabled = true` (opt-in). Harmony deploys its own ingress-nginx without ModSecurity support. |
| DNS requires Harmony | Simplicity vs composability | `create_dns_record = true` targets the ingress LB, so `harmony.enabled = true` is required. This is now guarded by an explicit preflight `check` with a clear error. |
| RKE2 version pinned | Reproducibility vs freshness | RKE2 defaults to `v1.34.4+rke2r1` (latest in the Rancher-supported v1.34 line). Operators can override via `rke2_version` variable or set to `""` for latest stable. |
| Hetzner S3 checksum workaround | Compatibility vs standard SDK | `checksumAlgorithm=""` disables aws-sdk-go-v2 default CRC32 checksum. Required because Hetzner Object Storage rejects `aws-chunked` transfer encoding. Community-sourced workaround ([#8660](https://github.com/vmware-tanzu/velero/issues/8660)), E2E validation mandatory. |
| Separate backup credentials | DRY vs safety | etcd and Velero use independent S3 credentials despite potentially sharing the same Hetzner Object Storage account. `coalesce("","")` causes runtime errors, and credential sharing obscures which addon depends on which secret. Operators can share at invocation level. |
| GitHub downloads at plan time | Simplicity vs reliability | System Upgrade Controller CRDs are downloaded from GitHub via `data.http` at `tofu plan`. If GitHub is unreachable, plan fails. Vendoring is planned. |

---

## Roadmap

The path from current state to enterprise-grade, grouped by priority:

### Near-term (active development)

- [ ] Fix critical bugs (DNS crash, SSH key leak, conflicting defaults)
- [ ] Split firewall per node role (master / worker)
- [ ] CIDR validation on all network variables
- [ ] Add ACME staging option for development
- [ ] Vendor external manifests (remove `data.http` from GitHub)

### Mid-term

- [ ] Proxy protocol on ingress LB (real client IP visibility)
- [ ] Add `moved` blocks for safe resource renames
- [x] Add `.tftest.hcl` unit tests — **63 tests** across 4 files (variables, guardrails, conditional logic, examples)
- [x] GitHub Actions CI pipeline — **12 workflows** (lint ×3, SAST ×3, unit ×4, integration ×1, E2E ×1)
- [ ] Add `ssh_private_key` and additional outputs

### Long-term (enterprise-grade target)

- [ ] **Provider extraction** — remove all provider configurations from module (breaking change, major version bump)
- [x] etcd backup strategy (automated snapshots to S3-compatible storage) — **implemented** via `cluster_configuration.etcd_backup`
- [x] Velero PVC backup to Hetzner Object Storage — **implemented** via `velero` variable
- [ ] Velero backup observability (monitoring, alerting on failed backups)
- [ ] Automated restore drill / backup validation
- [ ] Network Policies (default deny + explicit allow)
- [ ] Pod Security Standards / admission policies
- [ ] Kubernetes audit logging
- [ ] Zero-downtime cluster upgrade strategy
- [ ] Full `CHANGELOG.md`, `CONTRIBUTING.md`, `SECURITY.md`
- [x] Integration tests — `tofu plan` with real providers (`integration-plan.yml`) + E2E apply/smoke/destroy (`e2e-apply.yml`)

---

## Out of Scope

The following are intentionally **not** part of this module:

| Topic | Reason |
|-------|--------|
| **OS-level hardening** | Server hardening is the operator's responsibility. Use Ansible roles (e.g., `dev-sec/ansible-collection-hardening`) after provisioning. |
| **Application deployment** | The module deploys infrastructure and the Harmony chart. Individual Open edX instance deployment (Tutor) is a separate concern. |
| **Backup and disaster recovery** | The module provides etcd S3 backup (RKE2 native) and Velero + Kopia PVC backup to Hetzner Object Storage. Application-level consistency (pre-backup hooks, `mysqldump`/`mongodump`) is the operator's responsibility at the Tutor deployment layer. Restore drills and backup monitoring are on the roadmap. |
| **Multi-cluster federation** | The module deploys a single cluster. Multi-cluster patterns are out of scope. |
| **Custom CNI configuration** | The module supports CNI selection (canal, calico, cilium, none) but does not manage CNI-specific configuration (BGP peers, IP pools, etc.). |
| **CI/CD pipelines for applications** | The module provides infrastructure. Application CI/CD (ArgoCD, Flux, etc.) is a separate layer. |
