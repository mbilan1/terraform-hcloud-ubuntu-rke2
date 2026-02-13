resource "kubernetes_namespace_v1" "monitoring" {
  depends_on = [null_resource.wait_for_cluster_ready]
  count      = var.cluster_configuration.monitoring_stack.preinstall ? 1 : 0
  metadata {
    name = "monitoring"
  }

  lifecycle {
    ignore_changes = [
      metadata[0].annotations,
    ]
  }
}

resource "helm_release" "prom_stack" {
  depends_on = [kubernetes_namespace_v1.monitoring, helm_release.loki, kubernetes_config_map_v1.dashboard, helm_release.tempo]

  count = var.cluster_configuration.monitoring_stack.preinstall ? 1 : 0
  name  = "prom-stack"
  # https://github.com/prometheus-community/helm-charts/blob/main/charts/kube-prometheus-stack/values.yaml
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.cluster_configuration.monitoring_stack.kube_prom_stack_version

  namespace = "monitoring"

  values = [file("${path.module}/templates/values/kube-prometheus-stack.yaml")]
}

resource "helm_release" "loki" {
  depends_on = [kubernetes_namespace_v1.monitoring]

  count = var.cluster_configuration.monitoring_stack.preinstall ? 1 : 0
  name  = "loki"
  # https://github.com/grafana/helm-charts/blob/main/charts/loki-stack/values.yaml
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki-stack"
  version    = var.cluster_configuration.monitoring_stack.loki_stack_version

  namespace = "monitoring"
  values    = [file("${path.module}/templates/values/loki-stack.yaml")]
}

resource "kubernetes_ingress_v1" "monitoring_ingress" {
  depends_on = [kubernetes_namespace_v1.monitoring]

  # Security/usability compromise:
  # - Monitoring stack installation and monitoring UI exposure are decoupled.
  # - Public ingress is explicit opt-in because Prometheus/Grafana endpoints are
  #   high-value reconnaissance targets when exposed without external auth gateway.
  # Alternative considered: always create ingress when monitoring is enabled.
  # Rejected to keep safer defaults while preserving optional public access for labs.
  count = var.cluster_configuration.monitoring_stack.preinstall && var.expose_monitoring_ingress ? 1 : 0
  metadata {
    name      = "monitoring-ingress"
    namespace = "monitoring"
    annotations = {
      "cert-manager.io/cluster-issuer"              = var.cluster_issuer_name
      "nginx.ingress.kubernetes.io/proxy-body-size" = var.nginx_ingress_proxy_body_size
      "nginx.ingress.kubernetes.io/ssl-redirect"    = "true"
    }
  }

  spec {
    ingress_class_name = "nginx"
    rule {
      host = "grafana.${var.domain}"
      http {
        path {
          backend {
            service {
              name = "prom-stack-grafana"
              port {
                number = 80
              }
            }
          }
          path = "/"
        }
      }
    }

    rule {
      host = "prometheus.${var.domain}"
      http {
        path {
          backend {
            service {
              name = "prom-stack-kube-prometheus-prometheus"
              port {
                number = 9090
              }
            }
          }
          path = "/"
        }
      }
    }

    tls {
      hosts = [
        "grafana.${var.domain}",
        "prometheus.${var.domain}"
      ]
      secret_name = "monitoring-tls"
    }
  }

  lifecycle {
    ignore_changes = [
      metadata[0].annotations,
    ]
  }
}

resource "kubernetes_config_map_v1" "dashboard" {
  depends_on = [kubernetes_namespace_v1.monitoring]

  count = var.cluster_configuration.monitoring_stack.preinstall ? 1 : 0
  metadata {
    name      = "dashboard"
    namespace = "monitoring"
    labels = {
      grafana_dashboard : "1"
    }
  }

  data = {
    "dashboard.json" = file("${path.module}/templates/misc/grafana-dashboard.json")
  }

  lifecycle {
    ignore_changes = [
      metadata[0].annotations,
    ]
  }
}
