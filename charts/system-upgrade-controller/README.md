# System Upgrade Controller — RKE2 automatic Kubernetes upgrades
#
# NOTE: SUC is deployed via raw manifests (not Helm chart).
# Download CRDs and controller from:
#   https://github.com/rancher/system-upgrade-controller/releases
#
# Deployment order:
#   1. kubectl apply -f manifests/suc-crd.yaml
#   2. kubectl apply -f manifests/suc-controller.yaml
#   3. kubectl apply -f manifests/server-plan.yaml
#   4. kubectl apply -f manifests/agent-plan.yaml
#
# Alternatively, use kustomize or ArgoCD to apply the manifests directory.

# Common configuration:
# NOTE: SUC version is centralized in charts/versions.yaml (key: suc).
kubernetes_channel: "https://update.rke2.io/v1-release/channels"
