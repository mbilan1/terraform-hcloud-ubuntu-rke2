# ──────────────────────────────────────────────────────────────────────────────
# Addons module — required providers
#
# DECISION: Declare required_providers but do NOT configure them.
# Why: HashiCorp best practice for child modules — providers are configured
#      in the root module and passed via the providers argument.
# See: https://developer.hashicorp.com/terraform/language/modules/develop/providers
# ──────────────────────────────────────────────────────────────────────────────

terraform {
  # NOTE: Keep the same minimum OpenTofu/Terraform version as the root module.
  # Why: Child modules may be used directly in tests or future refactors; having
  #      an explicit constraint avoids confusing mismatches across layers.
  required_version = ">= 1.5.0"

  required_providers {
    # Core K8s API — namespaces, secrets, labels, config maps
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.23.0"
    }

    # Helm chart deployment — HCCM, CSI, cert-manager, Longhorn, Kured, Harmony
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.11.0"
    }

    # COMPROMISE: Using gavinbunney/kubectl for raw manifest application.
    # Why: hashicorp/kubernetes doesn't support applying arbitrary YAML (CRDs,
    #      multi-doc manifests). alekc/kubectl is a newer fork but migration is
    #      a breaking change requiring provider source swap + state surgery.
    # See: docs/ARCHITECTURE.md — Provider Constraints
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.19.0, < 2.0.0"
    }

    # HTTP data fetching — SUC manifest downloads from GitHub releases
    http = {
      source  = "hashicorp/http"
      version = ">= 3.4.0, < 4.0.0"
    }
  }
}
