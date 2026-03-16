resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = local.monitoring_namespace
  }
}

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = false
  timeout          = 600

  values = [
    yamlencode({
      grafana = {
        enabled = true
        additionalDataSources = [
          {
            name      = "Loki"
            type      = "loki"
            uid       = "loki"
            access    = "proxy"
            url       = "http://loki-gateway.monitoring.svc.cluster.local"
            isDefault = false
          }
        ]
        ingress = {
          enabled = false
        }
        "grafana.ini" = {
          server = {
            domain   = var.grafana_hostname
            root_url = "https://${var.grafana_hostname}"
          }
        }
      }
      prometheus = {
        prometheusSpec = {
          retention                               = "10d"
          serviceMonitorSelectorNilUsesHelmValues = false
          serviceMonitorSelector                  = {}
          serviceMonitorNamespaceSelector         = {}
          podMonitorSelectorNilUsesHelmValues     = false
          podMonitorSelector                      = {}
          podMonitorNamespaceSelector             = {}
        }
      }
      alertmanager = {
        enabled = true
      }
    })
  ]

  depends_on = [
    helm_release.cert_manager,
    null_resource.wait_for_certificates
  ]
}
