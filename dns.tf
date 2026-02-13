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

resource "aws_route53_record" "wildcard" {
  count   = var.create_dns_record ? 1 : 0
  zone_id = var.route53_zone_id
  name    = "*.${var.domain}"
  type    = "A"
  ttl     = 300

  records = [hcloud_load_balancer.ingress[0].ipv4]
}
