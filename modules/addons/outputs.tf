# ──────────────────────────────────────────────────────────────────────────────
# Addons module outputs
# ──────────────────────────────────────────────────────────────────────────────

output "harmony_deployed" {
  description = "Whether Harmony was deployed"
  value       = var.harmony.enabled
}

output "longhorn_deployed" {
  description = "Whether Longhorn was deployed"
  value       = var.cluster_configuration.longhorn.preinstall
}

# --- Diagnostic resource counts (for unit testing conditional logic) ---
#
# NOTE: These outputs expose conditional resource counts so that root-level
# tests can verify feature toggles without accessing module internals.
# OpenTofu test assertions can only reference module outputs, not internal
# resources of child modules.
output "_test_counts" {
  description = "Resource counts for unit testing. Not part of the public API."
  value = {
    harmony_namespace             = length(kubernetes_namespace_v1.harmony)
    harmony_release               = length(helm_release.harmony)
    ingress_config                = length(kubectl_manifest.ingress_configuration)
    cert_manager_namespace        = length(keys(kubernetes_namespace_v1.cert_manager))
    cert_manager_release          = length(keys(helm_release.cert_manager))
    hccm_secret                   = length(keys(kubernetes_secret_v1.hccm_credentials))
    hccm_release                  = length(keys(helm_release.hcloud_ccm))
    csi_release                   = length(helm_release.hcloud_csi)
    kured_namespace               = length(kubernetes_namespace_v1.kured)
    kured_release                 = length(helm_release.kured)
    longhorn_namespace            = length(kubernetes_namespace_v1.longhorn)
    longhorn_release              = length(helm_release.longhorn)
    longhorn_s3_secret            = length(kubernetes_secret_v1.longhorn_s3)
    longhorn_iscsi_installer      = length(kubectl_manifest.longhorn_iscsi_installer)
    longhorn_worker_labels        = length(kubernetes_labels.longhorn_worker)
    longhorn_health_check         = length(terraform_data.longhorn_health_check)
    longhorn_pre_upgrade_snapshot = length(terraform_data.longhorn_pre_upgrade_snapshot)
  }
}
