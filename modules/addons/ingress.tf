# When Harmony is enabled, rke2-ingress-nginx is disabled and Harmony manages
# its own ingress-nginx. This HelmChartConfig only applies when using the
# RKE2 built-in ingress controller (harmony.enabled = false).
resource "kubectl_manifest" "ingress_configuration" {
  count      = var.harmony.enabled ? 0 : 1
  depends_on = [terraform_data.wait_for_infrastructure]
  yaml_body = yamlencode({
    apiVersion = "helm.cattle.io/v1"
    kind       = "HelmChartConfig"
    metadata = {
      name      = "rke2-ingress-nginx"
      namespace = "kube-system"
    }
    spec = {
      valuesContent = join("\n", compact([
        "controller:",
        "  config:",
        "    proxy-body-size: \"${var.nginx_ingress_proxy_body_size}\"",
        var.enable_nginx_modsecurity_waf ? "    enable-modsecurity: \"true\"" : "",
        var.enable_nginx_modsecurity_waf ? "    enable-owasp-modsecurity-crs: \"true\"" : "",
        var.enable_nginx_modsecurity_waf ? "    modsecurity-snippet: |-" : "",
        var.enable_nginx_modsecurity_waf ? "      SecRuleEngine On" : ""
      ]))
    }
  })
}
