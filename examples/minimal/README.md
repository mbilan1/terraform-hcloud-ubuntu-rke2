# Minimal RKE2 Cluster Example

Smallest viable cluster configuration — 1 master, 0 workers, all defaults.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
tofu init
tofu plan
tofu apply
```

## Required Variables

| Variable | Description |
|----------|-------------|
| `hcloud_token` | Hetzner Cloud API token |
| `cluster_domain` | Cluster domain (default: `test.example.com`) |

## What Gets Created

- 1 control-plane node (cx23, Ubuntu 24.04)
- 1 control-plane load balancer (lb11)
- Private network + subnet
- Firewall
- SSH key pair

L4 addons (HCCM, CSI, cert-manager) are deployed separately via Helmfile — see `charts/README.md`.

## Cost

~€15/month (1× cx23 + 1× lb11)
