# OpenBao — Secrets Management for Kubernetes (EXPERIMENTAL)

> **Status**: Experimental — API and workflow may change without notice.

## What This Is

OpenBao is an open-source fork of HashiCorp Vault, providing secrets management,
encryption as a service, and identity-based access. In this stack, it serves as
an optional layer for secure kubeconfig distribution and team secrets management.

## Architecture

```
Terraform (L3)          Helmfile (L4)              Operator
───────────────         ──────────────             ────────
1. tofu apply
   ├─ Create cluster
   ├─ Fetch kubeconfig     2. helmfile sync
   │  (data "external")       ├─ Deploy HCCM
   ├─ Generate bootstrap       ├─ Deploy cert-manager
   │  token (random)           ├─ Deploy Longhorn
   │                           ├─ Deploy OpenBao (dev mode)
   │                           │  └─ presync: create token Secret
   │                           │  └─ postsync: push-kubeconfig Job
   │                           └─ OpenBao ready
   │
   └─ Outputs:
      openbao_url             3. First login:
      openbao_bootstrap_token    bao login (with bootstrap token)
      kube_config                bao kv get secret/cluster/kubeconfig
                              4. Configure permanent auth
                              5. Revoke bootstrap token
```

## Quick Start: Dev Mode (Bootstrap)

Use `values-dev.yaml` if you only want to use OpenBao temporarily to hand off the kubeconfig.

### Prerequisites

- `openbao_enabled = true` in your Terraform variables
- `enable_secrets_encryption = true` (required — enforced by guardrail)
- `agent_node_count >= 1` (required — enforced by guardrail)
- `harmony_enabled = true` (required — for ingress to OpenBao)

### Step 1: Deploy infrastructure

```bash
tofu apply
```

### Step 2: Prepare the bootstrap token

```bash
# Get the token from Terraform output
export OPENBAO_TOKEN=$(tofu output -raw openbao_bootstrap_token)

# Create the K8s namespace and Secret
kubectl create namespace openbao
kubectl create secret generic openbao-bootstrap-token \
  --namespace openbao \
  --from-literal=token="$OPENBAO_TOKEN"
```

### Step 3: Update values.yaml

Replace the placeholders in `charts/openbao/values.yaml`:
- `OPENBAO_BOOTSTRAP_TOKEN` → your token (from step 2)
- `CLUSTER_DOMAIN` → your cluster domain

### Step 4: Deploy OpenBao

```bash
cd charts/
helmfile -l name=openbao sync
```

### Step 5: Access OpenBao

```bash
export VAULT_ADDR="https://vault.your-cluster-domain.com"
export BAO_ADDR="$VAULT_ADDR"

# Login with bootstrap token
bao login "$OPENBAO_TOKEN"

# Retrieve kubeconfig (pushed by the bootstrap Job)
bao kv get -field=kubeconfig secret/cluster/kubeconfig > ~/.kube/config
```

### Step 6: Configure permanent auth & revoke bootstrap token

```bash
# Example: enable UserPass auth
bao auth enable userpass
bao write auth/userpass/users/admin password="..." policies=admin

# IMPORTANT: Revoke the bootstrap token
bao token revoke "$OPENBAO_TOKEN"
```

### Step 7 (optional): Tear down OpenBao

If you only needed OpenBao for kubeconfig handoff:

```bash
helmfile -l name=openbao destroy
kubectl delete namespace openbao
```

## Quick Start: Production Mode (Default Secret Manager)

Use `values.yaml` to deploy OpenBao in HA mode with Raft storage and the Agent Injector. This makes OpenBao the default secret manager for all Kubernetes workloads.

### Step 1: Deploy OpenBao

Ensure `CLUSTER_DOMAIN` is set in `values.yaml`, then deploy:

```bash
cd charts/
helmfile -l name=openbao sync
```

### Step 2: Initialize and Unseal

Because production mode uses Raft storage, OpenBao starts **sealed**. You must initialize it manually:

```bash
# Initialize OpenBao (save the output securely!)
kubectl exec -n openbao openbao-0 -- bao operator init

# Unseal OpenBao (run 3 times with different keys from the init output)
kubectl exec -n openbao openbao-0 -- bao operator unseal
```

### Step 3: Configure Kubernetes Auth

To allow Kubernetes pods to authenticate with OpenBao using their ServiceAccounts, enable the Kubernetes Auth method:

```bash
# Login with the root token from the init step
export VAULT_ADDR="https://vault.your-cluster-domain.com"
export BAO_ADDR="$VAULT_ADDR"
bao login <ROOT_TOKEN>

# Enable Kubernetes Auth
bao auth enable kubernetes

# Configure the Kubernetes Auth method
bao write auth/kubernetes/config \
    kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443"
```

### Step 4: Create a Policy and Role

Create a policy that allows reading secrets, and bind it to a Kubernetes ServiceAccount:

```bash
# Create a policy
bao policy write my-app-policy - <<EOF
path "secret/data/my-app/*" {
  capabilities = ["read"]
}
EOF

# Create a role binding the policy to a ServiceAccount
bao write auth/kubernetes/role/my-app-role \
    bound_service_account_names=my-app-sa \
    bound_service_account_namespaces=default \
    policies=my-app-policy \
    ttl=24h
```

### Step 5: Inject Secrets into Pods

Add annotations to your pod deployments to inject secrets automatically:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  template:
    metadata:
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "my-app-role"
        vault.hashicorp.com/agent-inject-secret-config: "secret/data/my-app/config"
```

## Security Model

| Layer | Protection | Responsibility |
|-------|-----------|---------------|
| Transport | TLS via cert-manager + ingress | Module (automatic) |
| Bootstrap token | 32-char random, `sensitive = true` | Operator (must revoke) |
| Unseal key | K8s Secret + etcd encryption at rest | Module (guardrail enforces encryption) |
| Kubeconfig in OpenBao | OpenBao ACL policies | Operator (must configure) |
| Kubeconfig in state | Terraform state encryption | Operator (must protect state) |

## Security Disclaimer

> **The default mode (openbao_enabled = false) uses SSH + `data "external"` to
> retrieve kubeconfig. This is secure for single-operator use but stores the
> kubeconfig in Terraform state. If you need audit logging, RBAC, or team
> access — enable OpenBao.**
>
> **With either mode, protecting the Terraform state file is the OPERATOR'S
> responsibility.** Use an encrypted remote backend (S3 + server-side encryption,
> OpenTofu Cloud, etc.) with proper ACLs.
