# Open edX on Hetzner Cloud (Tutor + Harmony)

This example deploys an RKE2 Kubernetes cluster on Hetzner Cloud with all prerequisites for running [Open edX](https://openedx.org/) via [Tutor](https://docs.tutor.edly.io/) and the [openedx-k8s-harmony](https://github.com/openedx/openedx-k8s-harmony) chart.

The Harmony Tutor plugin (`k8s_harmony`) handles Ingress creation, TLS settings, and Caddy configuration automatically — no manual YAML patches required.

## What it creates

| Resource | Details |
|----------|---------|
| RKE2 cluster | 3 masters + 3 workers across 3 EU data centers |
| Ingress controller | nginx via Harmony chart (hostPort DaemonSet + dedicated LB) |
| TLS | cert-manager with Route53 DNS-01 ClusterIssuer (`harmony-letsencrypt-global`) |
| Storage | Hetzner CSI driver (`hcloud-volumes` StorageClass) |
| DNS | Route53 A + wildcard CNAME records |

## Prerequisites

- [OpenTofu](https://opentofu.org/) or Terraform >= 1.5
- Hetzner Cloud account + API token
- AWS account with a Route53 hosted zone
- [Tutor](https://docs.tutor.edly.io/) >= 18
- Python 3.12+ (for Tutor)

## Quick start

### 1. Configure

```bash
cd examples/openedx-tutor
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your real values
```

### 2. Deploy infrastructure

```bash
tofu init
tofu apply
```

### 3. Get kubeconfig

```bash
tofu output -raw kubeconfig > ~/.kube/config
chmod 600 ~/.kube/config

# Verify
kubectl get nodes
kubectl get pods -n harmony
```

### 4. Install Tutor with the Harmony plugin

```bash
pip install "tutor[full]"
pip install "git+https://github.com/openedx/openedx-k8s-harmony.git#egg=tutor-contrib-harmony&subdirectory=tutor-contrib-harmony-plugin"
tutor plugins enable k8s_harmony
```

The plugin automatically sets `ENABLE_WEB_PROXY=false` and `ENABLE_HTTPS=true` — this is required because TLS termination is handled by the ingress controller (Harmony), not by Caddy.

### 5. Configure and deploy Open edX

```bash
tutor config save \
  --set LMS_HOST=openedx.example.com \
  --set CMS_HOST=studio.openedx.example.com

tutor k8s start
tutor k8s init    # migrations + initial setup (~15-30 min on first run)
```

The plugin creates Ingress resources for each host (LMS, CMS, MFE) with:
- `cert-manager.io/cluster-issuer: harmony-letsencrypt-global` — matched by this module's ClusterIssuer
- `ingressClassName: nginx` — matched by Harmony's ingress-nginx
- `nginx.ingress.kubernetes.io/proxy-body-size: 100m` — matched by this module's ingress controller config

### 6. Verify

```bash
kubectl get pods -n openedx          # all Running
kubectl get ingress -n openedx       # Ingress per host, created by plugin
kubectl get certificate -n openedx   # Ready: True

curl -I https://openedx.example.com
curl -I https://studio.openedx.example.com
curl -I https://apps.openedx.example.com
```

## Architecture

```
Browser (HTTPS)
  → Hetzner LB (TCP passthrough, ports 80/443)
    → ingress-nginx DaemonSet (TLS termination via cert-manager)
      → Caddy ClusterIP :80 (per-instance host routing)
        → LMS / CMS / MFE containers
```

### Why Caddy stays in the chain

Tutor uses Caddy as an internal reverse proxy that routes requests by hostname to the correct uwsgi/gunicorn backend. The Harmony plugin converts Caddy from a public LoadBalancer to a ClusterIP service, delegating TLS and external routing to ingress-nginx. This is the architecture designed by the Open edX community for shared Kubernetes clusters.

## DNS records

| Record | Type | Target |
|--------|------|--------|
| `openedx.example.com` | A | Ingress LB IPv4 (`tofu output ingress_lb_ipv4`) |
| `*.openedx.example.com` | CNAME | `openedx.example.com` |

The wildcard covers subdomains: `studio.*` (CMS), `apps.*` (MFE), `preview.*` (Preview).

## Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| 308 redirect loop | `ENABLE_WEB_PROXY=true` — Caddy tries HTTPS redirect, but ingress-nginx already handles TLS | Ensure `k8s_harmony` plugin is enabled (it forces `ENABLE_WEB_PROXY=false`) |
| Blank MFE page | `ENABLE_HTTPS=false` — MFE gets `http://` API URLs → mixed-content blocked by browser | Ensure `k8s_harmony` plugin is enabled (it forces `ENABLE_HTTPS=true`) |
| No Ingress in `openedx` namespace | Plugin not enabled, or `tutor config save` not run after enabling | `tutor plugins enable k8s_harmony && tutor config save && tutor k8s start` |
| `namespace openedx not found` | `tutor k8s init` called before `tutor k8s start` | Always run `start` before `init` |

## Cleanup

```bash
tofu destroy
```
