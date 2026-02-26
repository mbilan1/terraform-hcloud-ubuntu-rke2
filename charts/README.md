# charts/ — GitOps-Ready Addon Deployment

> **These Helm charts are NOT managed by Terraform.**
> Terraform provisions infrastructure (L3); this directory manages
> Kubernetes workloads (L4) via Helmfile, ArgoCD, or Flux.

## Architecture

```
Terraform (L3)                     GitOps / Helmfile (L4)
┌─────────────────────┐           ┌──────────────────────────┐
│ Servers, LBs, DNS   │           │ HCCM (first!)            │
│ Network, Firewall   │──────────►│ cert-manager             │
│ Cloud-init bootstrap│ kubeconfig│ Longhorn                 │
│ SSH keys            │           │ Kured + SUC              │
└─────────────────────┘           │ Harmony (Open edX)       │
                                  └──────────────────────────┘
```

HCCM (Hetzner Cloud Controller Manager) must be deployed **first** via
Helmfile after cluster bootstrap. Nodes carry an `uninitialized` taint
until HCCM clears it. See `charts/hccm/README.md` for details.

## Quick Start

```bash
# Install Helmfile (https://helmfile.readthedocs.io/)
# Ensure KUBECONFIG points to your cluster

# Review what will be deployed
helmfile -f helmfile.yaml diff

# Deploy all addons
helmfile -f helmfile.yaml apply
```

## Directory Structure

```
charts/
├── helmfile.yaml              # Declarative release definitions
├── hccm/
│   ├── values.yaml            # HCCM Helm values
│   ├── manifests/
│   │   └── secret.yaml        # Template Secret for hcloud credentials
│   └── README.md              # HCCM deployment docs
├── cert-manager/
│   ├── values.yaml            # cert-manager Helm values
│   └── manifests/
│       └── clusterissuer.yaml # Let's Encrypt ClusterIssuer
├── longhorn/
│   ├── values.yaml            # Longhorn distributed storage values
│   └── manifests/
│       └── iscsi-installer.yaml
├── kured/
│   └── values.yaml            # Kured reboot daemon values
├── system-upgrade-controller/
│   ├── README.md              # SUC deployment docs
│   └── manifests/             # Raw manifests for SUC + upgrade plans
│       ├── server-plan.yaml
│       └── agent-plan.yaml
├── harmony/
│   └── values.yaml            # OpenEdX Harmony values
└── ingress/
    └── helmchartconfig.yaml   # RKE2 built-in ingress tuning (non-Harmony)
```

## Deployment Order

Addons have dependencies. Deploy in this order (Helmfile handles this
automatically via `needs:`):

1. **HCCM** — Cloud Controller Manager (must be first — clears node taints)
2. **cert-manager** — CRDs and controller (other charts reference ClusterIssuers)
3. **Longhorn** — distributed storage (PVCs depend on StorageClass)
4. **Kured** — reboot daemon (independent, but after storage)
5. **SUC** — System Upgrade Controller + plans (independent)
6. **Harmony** — Open edX platform (depends on cert-manager + storage)

## Migration from Terraform-Managed Addons

If upgrading from a version where Terraform managed addons:

> **NOTE:** Do NOT run `tofu state rm` manually. The module contains `removed {}`
> blocks that automatically drop addon resources from state without destroying
> live Kubernetes objects. Manual `state rm` before `apply` can cause those
> blocks to silently no-op, leaving state inconsistent on rollback.

```bash
# 1. Update module source to the new version (with removed {} blocks)
# 2. Run tofu apply — removed {} blocks handle state cleanup automatically
tofu apply

# 3. Deploy addons via Helmfile
helmfile -f helmfile.yaml apply
```

> **WARNING:** This is a one-way migration. After `tofu apply` removes addon
> resources from state, rolling back to the old module version requires manual
> `tofu import` of every addon resource. Plan accordingly.

## ArgoCD / Flux Integration

For GitOps operators, point your Application/Kustomization at the
individual chart directories. Each `values.yaml` is self-contained.

Example ArgoCD Application:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
spec:
  source:
    repoURL: https://charts.jetstack.io
    chart: cert-manager
    targetRevision: "v1.17.2"
    helm:
      valueFiles:
        - $values/charts/cert-manager/values.yaml
```
