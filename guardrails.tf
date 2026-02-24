# Cross-variable guardrails for safer plans.
#
# Why check-blocks instead of relying on downstream provider errors:
# - Provider/API failures are usually later and less actionable.
# - check/assert fails early with operator-friendly messages.
# - This keeps defaults usable while still enforcing critical consistency.

# ── Worker placement guardrails ───────────────────────────────────────────

check "workers_must_not_mix_countries" {
  assert {
    # DECISION: Optional strict policy to disallow mixed-country worker pools.
    # Why: Cross-country RTT pushes synchronous fsync latency into tens of ms,
    #      making MySQL migrations and other sync-heavy workloads unusably slow.
    #      Masters can be spread wider; workers should be confined.
    # NOTE: We only enforce when enforce_single_country_workers=true to keep
    #       module defaults/backward compatibility intact.
    condition = (
      !var.enforce_single_country_workers || (
        alltrue([for l in local.effective_worker_locations : l == "hel1"]) ||
        alltrue([for l in local.effective_worker_locations : contains(["nbg1", "fsn1"], l)])
      )
    )
    error_message = "Workers must be Finland-only (hel1) or Germany-only (nbg1/fsn1) when enforce_single_country_workers=true. Do not mix hel1 with nbg1/fsn1 for workers."
  }
}

# ── DNS guardrails (moved from dns.tf — resource moved to modules/infrastructure/) ──

check "dns_requires_zone_id" {
  assert {
    condition     = !var.create_dns_record || var.route53_zone_id != ""
    error_message = "route53_zone_id must be set when create_dns_record is true."
  }
}

check "dns_requires_harmony_ingress" {
  assert {
    # Why explicit check instead of conditional indexing / try():
    # - DNS in this module is intentionally tied to ingress LB endpoint.
    # - Hiding this coupling with try()/fallback would mask configuration mistakes.
    # - Explicit failure gives a deterministic, operator-friendly error message
    #   before provider graph evaluation reaches ingress[0].
    # Alternative considered: support DNS without Harmony by targeting another endpoint.
    # Rejected in current design to avoid ambiguous traffic model and mixed ingress paths.
    condition     = !var.create_dns_record || var.harmony.enabled
    error_message = "create_dns_record = true requires harmony.enabled = true because DNS points to the ingress load balancer."
  }
}

# ── AWS guardrails ──────────────────────────────────────────────────────────

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

check "kubernetes_version_format_when_pinned" {
  assert {
    # Reproducibility compromise:
    # - Empty value is still allowed for usability (installs latest stable).
    # - If operator pins a version, enforce expected RKE2 tag format early.
    # Alternative considered: force non-empty pinned version always.
    # Rejected for now to avoid breaking existing consumers; stricter policy can
    # be introduced later as an explicit opt-in/major-version change.
    condition = (
      trimspace(var.kubernetes_version) == "" ||
      can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+\\+rke2r[0-9]+$", var.kubernetes_version))
    )
    error_message = "kubernetes_version must be empty or match format like v1.31.6+rke2r1."
  }
}

# ── Longhorn guardrails ─────────────────────────────────────────────────────

# DECISION: Cross-addon guardrail — only one default StorageClass at a time.
# Why: Two default StorageClasses cause ambiguous PVC binding.
#      Operators must choose one (Longhorn or Hetzner CSI) as default.
check "longhorn_and_csi_default_sc_exclusivity" {
  assert {
    condition = !(
      var.cluster_configuration.longhorn.preinstall &&
      var.cluster_configuration.longhorn.default_storage_class &&
      var.cluster_configuration.hcloud_csi.preinstall &&
      var.cluster_configuration.hcloud_csi.default_storage_class
    )
    error_message = "Both Longhorn and Hetzner CSI are set as default StorageClass. Set only one as default."
  }
}

# DECISION: Warn when Longhorn is enabled — it is experimental.
# Why: Longhorn is a new addition and not battle-tested in production.
#      Operators should test thoroughly before production use.
# TODO: Remove this warning when Longhorn is promoted to stable.
check "longhorn_experimental_warning" {
  assert {
    condition     = !var.cluster_configuration.longhorn.preinstall
    error_message = "WARNING: Longhorn is EXPERIMENTAL. Test thoroughly before production use. See PLAN-operational-readiness.md Appendix A for tuning guidance."
  }
}

# DECISION: Longhorn backup requires S3 credentials.
# Why: Prevents silent backup failures from missing credentials.
check "longhorn_backup_requires_s3_config" {
  assert {
    condition = (
      !var.cluster_configuration.longhorn.preinstall ||
      trimspace(var.cluster_configuration.longhorn.backup_target) == "" ||
      (
        trimspace(var.cluster_configuration.longhorn.s3_access_key) != "" &&
        trimspace(var.cluster_configuration.longhorn.s3_secret_key) != ""
      )
    )
    error_message = "Longhorn backup_target requires s3_access_key and s3_secret_key to be set."
  }
}

# DECISION: Longhorn RF=2 requires at least 2 workers; RF=3 requires at least 3.
# Why: Longhorn cannot replicate data if fewer nodes than replica count.
check "longhorn_minimum_workers" {
  assert {
    condition = (
      !var.cluster_configuration.longhorn.preinstall ||
      var.agent_node_count >= var.cluster_configuration.longhorn.replica_count
    )
    error_message = "Longhorn replica_count requires at least that many worker nodes (agent_node_count >= replica_count)."
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Harmony guardrails
# ──────────────────────────────────────────────────────────────────────────────

# DECISION: Harmony check blocks live in root (not in modules/addons/) so that
# `tofu test` can reference them as `check.name` without module path prefixes.
# Why: OpenTofu test expect_failures uses root-scoped addresses.

check "harmony_requires_cert_manager" {
  assert {
    condition     = !var.harmony.enabled || var.cluster_configuration.cert_manager.preinstall
    error_message = "Harmony requires cert-manager CRDs. Set cluster_configuration.cert_manager.preinstall = true when harmony.enabled = true."
  }
}

check "harmony_requires_workers_for_lb" {
  assert {
    condition     = !var.harmony.enabled || var.agent_node_count > 0
    error_message = "Harmony routes HTTP/HTTPS through worker node targets on the ingress LB. Set agent_node_count >= 1 when harmony.enabled = true, or traffic will not reach ingress-nginx."
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Self-maintenance guardrails
# ──────────────────────────────────────────────────────────────────────────────

# Warn when auto-update flags are true but cluster is non-HA (single master).
# Kured and System Upgrade Controller are only deployed on HA clusters (>= 3 masters)
# because rebooting/upgrading a single control-plane node causes full downtime.
check "auto_updates_require_ha" {
  assert {
    condition     = var.control_plane_count >= 3 || (!var.enable_auto_os_updates && !var.enable_auto_kubernetes_updates)
    error_message = "enable_auto_os_updates and enable_auto_kubernetes_updates have no effect on non-HA clusters (control_plane_count < 3). Kured and System Upgrade Controller are only deployed on HA clusters."
  }
}