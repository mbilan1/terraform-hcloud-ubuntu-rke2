check "dns_requires_zone_id" {
  assert {
    condition     = !var.create_dns_record || var.route53_zone_id != ""
    error_message = "route53_zone_id must be set when create_dns_record is true."
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
