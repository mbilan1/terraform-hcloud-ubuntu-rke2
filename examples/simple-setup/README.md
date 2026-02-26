# Simple Setup Example

Deploys a minimal HA RKE2 cluster on Hetzner Cloud: 3 control-plane nodes, 1 worker.

## Prerequisites

- OpenTofu >= 1.7
- Hetzner Cloud API token (`HCLOUD_TOKEN` env var or `hcloud_api_token` variable)

## Usage

```bash
tofu init
tofu plan
tofu apply
```

After provisioning, a `kubeconfig.yaml` file is written to the working directory:

```bash
export KUBECONFIG="$(pwd)/kubeconfig.yaml"
kubectl get nodes
```

## What This Example Deploys

- 3 master nodes (etcd quorum)
- 1 worker node
- Control-plane load balancer (K8s API + node registration)
- Private network + subnet
- Firewall
- SSH key pair (exported locally via `save_ssh_key_locally = true`)
- RKE2 built-in ingress-nginx (Harmony disabled)

L4 addons (HCCM, CSI, cert-manager, etc.) are deployed separately via Helmfile — see `charts/README.md`.

## Cleanup

```bash
tofu destroy
```