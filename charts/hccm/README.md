# HCCM (Hetzner Cloud Controller Manager) — Helmfile Configuration

## Overview

HCCM is the **first** chart that must be deployed after cluster bootstrap.

Until HCCM runs, all nodes carry the `node.cloudprovider.kubernetes.io/uninitialized`
taint, which prevents any non-system pods from scheduling.

## Prerequisites

1. A running RKE2 cluster with `cloud-provider-name: external` in server config
2. A valid kubeconfig for the cluster
3. Hetzner Cloud API token
4. Hetzner private network name

## Deployment

```bash
# 1. Create the Secret (edit manifests/secret.yaml first with real values)
kubectl apply -f charts/hccm/manifests/secret.yaml

# 2. Deploy HCCM via Helmfile
cd charts/
helmfile -l name=hccm apply
```

Or deploy everything in order:

```bash
cd charts/
helmfile apply
```

Helmfile will run the presync hook automatically to create the Secret.

## Secret Management

The `manifests/secret.yaml` file is a **template**. You must replace the
placeholder values with base64-encoded credentials before applying.

For production, consider using:
- [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets)
- [External Secrets Operator](https://external-secrets.io/)
- SOPS + age encryption
