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
    condition     = !var.create_dns_record || var.harmony_enabled
    error_message = "create_dns_record = true requires harmony_enabled = true because DNS points to the ingress load balancer."
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

# ── Harmony guardrails ────────────────────────────────────────────────────────

check "harmony_requires_workers_for_lb" {
  assert {
    # DECISION: Harmony routes HTTP/HTTPS through worker node targets on the
    # ingress LB. Without workers, traffic can't reach ingress-nginx.
    condition     = !var.harmony_enabled || var.agent_node_count > 0
    error_message = "Harmony routes HTTP/HTTPS through worker node targets on the ingress LB. Set agent_node_count >= 1 when harmony_enabled = true, or traffic will not reach ingress-nginx."
  }
}

# ── OpenBao guardrails ────────────────────────────────────────────────────────

check "openbao_requires_workers" {
  assert {
    # DECISION: OpenBao pods must schedule on worker nodes.
    # Why: Running vault workloads on control-plane nodes is an anti-pattern —
    #      it mixes security-critical services with cluster management.
    condition     = !var.openbao_enabled || var.agent_node_count > 0
    error_message = "openbao_enabled = true requires agent_node_count >= 1. OpenBao pods need worker nodes to schedule on."
  }
}

check "openbao_requires_secrets_encryption" {
  assert {
    # DECISION: OpenBao's unseal key is stored in a K8s Secret.
    # Why: Without etcd encryption at rest, the unseal key is stored in plaintext
    #      in etcd — defeating the purpose of running a secrets manager.
    #      RKE2's secrets-encryption config encrypts all Secrets in etcd (AES-CBC/GCM).
    condition     = !var.openbao_enabled || var.enable_secrets_encryption
    error_message = "openbao_enabled = true requires enable_secrets_encryption = true. The OpenBao unseal key is stored as a K8s Secret — without etcd encryption, it would be in plaintext."
  }
}