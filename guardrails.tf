# Cross-variable guardrails for safer plans.
#
# Why check-blocks instead of relying on downstream provider errors:
# - Provider/API failures are usually later and less actionable.
# - check/assert fails early with operator-friendly messages.
# - This keeps defaults usable while still enforcing critical consistency.

check "aws_credentials_pair_consistency" {
  assert {
    condition = (
      (var.aws_access_key == "" && var.aws_secret_key == "") ||
      (var.aws_access_key != "" && var.aws_secret_key != "")
    )
    error_message = "Set both aws_access_key and aws_secret_key together, or leave both empty to use the default AWS credentials chain."
  }
}

check "letsencrypt_email_required_when_issuer_enabled" {
  assert {
    # Compromise: require ACME contact email for Route53 DNS-01 (production-like path),
    # but allow empty email for local/dev HTTP-01 scenarios to reduce warning noise.
    # Alternative considered: always require email when issuer is enabled.
    # Rejected because it produces persistent warnings for test setups (e.g. test.local)
    # without improving practical reliability there.
    condition = (
      !var.cluster_configuration.cert_manager.use_for_preinstalled_components ||
      var.route53_zone_id == "" ||
      trimspace(var.letsencrypt_issuer) != ""
    )
    error_message = "letsencrypt_issuer must be set when using cert-manager preinstalled issuer with Route53 DNS-01 (route53_zone_id != \"\")."
  }
}

check "system_upgrade_controller_version_format" {
  assert {
    # Variable stores numeric semver (e.g. 0.13.4), URL template prefixes it with 'v'.
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.cluster_configuration.self_maintenance.system_upgrade_controller_version))
    error_message = "cluster_configuration.self_maintenance.system_upgrade_controller_version must be semantic version format like 0.13.4."
  }
}

check "remote_manifest_downloads_required_for_selected_features" {
  assert {
    # Reproducibility compromise:
    # - Default stays compatible (remote downloads enabled).
    # - Operators can explicitly disable remote downloads for controlled/offline
    #   environments, but then features that currently depend on GitHub-hosted
    #   manifests must be turned off.
    condition = (
      var.allow_remote_manifest_downloads ||
      !var.enable_auto_kubernetes_updates
    )
    error_message = "allow_remote_manifest_downloads=false requires enable_auto_kubernetes_updates=false (this feature currently relies on remote GitHub manifests)."
  }
}

check "etcd_backup_requires_s3_config" {
  assert {
    condition = (
      !var.cluster_configuration.etcd_backup.enabled ||
      (
        trimspace(var.cluster_configuration.etcd_backup.s3_bucket) != "" &&
        trimspace(var.cluster_configuration.etcd_backup.s3_access_key) != "" &&
        trimspace(var.cluster_configuration.etcd_backup.s3_secret_key) != ""
      )
    )
    error_message = "etcd_backup.enabled=true requires s3_bucket, s3_access_key, and s3_secret_key to be set."
  }
}

check "rke2_version_format_when_pinned" {
  assert {
    # Reproducibility compromise:
    # - Empty value is still allowed for usability (installs latest stable).
    # - If operator pins a version, enforce expected RKE2 tag format early.
    # Alternative considered: force non-empty pinned version always.
    # Rejected for now to avoid breaking existing consumers; stricter policy can
    # be introduced later as an explicit opt-in/major-version change.
    condition = (
      trimspace(var.rke2_version) == "" ||
      can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+\\+rke2r[0-9]+$", var.rke2_version))
    )
    error_message = "rke2_version must be empty or match format like v1.31.6+rke2r1."
  }
}