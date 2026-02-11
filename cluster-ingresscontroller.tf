resource "kubectl_manifest" "ingress_configuration" {
  depends_on = [time_sleep.wait_30_seconds, hcloud_server.master, hcloud_server.additional_masters, hcloud_server.worker]
  count      = var.enable_nginx_modsecurity_waf ? 1 : 0
  yaml_body  = file("${path.module}/templates/values/ingress_controller.yaml")
}