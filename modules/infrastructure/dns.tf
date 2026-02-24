# ──────────────────────────────────────────────────────────────────────────────
# Route53 DNS — wildcard A record → ingress LB
#
# DECISION: Use a wildcard record ("*.cluster_domain") instead of per-service records.
# Why: Wildcard covers all Ingress-based services (app.domain, studio.domain, etc.)
#      with a single record. Per-service records would require Terraform to track
#      every Ingress host, which creates tight coupling between infrastructure and
#      application layers. The wildcard pattern is standard for nginx-ingress setups.
#
# NOTE: Check blocks (dns_requires_zone_id, dns_requires_harmony_ingress)
# remain in the root module's guardrails.tf — they validate root-level
# variable combinations before values are passed to child modules.
# ──────────────────────────────────────────────────────────────────────────────

locals {
  # Pre-compute the wildcard FQDN used for the Route53 record.
  # Format: "*.k8s.example.com" — matches any subdomain under cluster_domain.
  wildcard_fqdn = format("*.%s", var.cluster_domain)

  # NOTE: Keep TTL a named constant so future adjustments are single-line.
  dns_record_ttl_seconds = 300

  # WORKAROUND: try() keeps plan-time evaluation safe when ingress LB is absent.
  # Why: The ingress LB only exists when Harmony is enabled.
  ingress_lb_ipv4 = try(hcloud_load_balancer.ingress[0].ipv4, "")

  # NOTE: Keep record parameters as a single object.
  # Why: Makes future changes (AAAA, different TTL, multiple records) localized
  #      and keeps the resource block focused on wiring.
  wildcard_record_spec = {
    type  = "A"
    ttl   = local.dns_record_ttl_seconds
    name  = local.wildcard_fqdn
    value = local.ingress_lb_ipv4
  }
}

resource "aws_route53_record" "wildcard" {
  #checkov:skip=CKV2_AWS_23: Wildcard A record targets ingress LB IPv4; alias pattern not applicable here.
  count = var.create_dns_record ? 1 : 0

  zone_id = var.route53_zone_id
  type    = local.wildcard_record_spec.type
  name    = local.wildcard_record_spec.name
  ttl     = local.wildcard_record_spec.ttl
  records = [local.wildcard_record_spec.value]

  allow_overwrite = true
}
