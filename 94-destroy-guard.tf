resource "null_resource" "lb_destroy_guard" {
  triggers = {
    monitoring_namespace   = kubernetes_namespace.monitoring.metadata[0].name
    vault_namespace        = kubernetes_namespace.vault.metadata[0].name
    postgres_namespace     = kubernetes_namespace.postgres.metadata[0].name
    grafana_ingress        = kubernetes_ingress_v1.grafana.metadata[0].name
    vault_ingress          = kubernetes_ingress_v1.vault.metadata[0].name
    postgres_service       = kubernetes_service_v1.postgres.metadata[0].name
    alb_attributes_destroy = "deletion_protection.enabled=false,routing.http.drop_invalid_header_fields.enabled=true,routing.http.desync_mitigation_mode=strictest"
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-lc"]

    command = <<-EOT
      set -euo pipefail

      patch_tgbs() {
        namespace="$1"

        if ! kubectl get namespace "$namespace" >/dev/null 2>&1; then
          return 0
        fi

        kubectl get targetgroupbindings.elbv2.k8s.aws -n "$namespace" -o name 2>/dev/null | while read -r tgb; do
          [ -n "$tgb" ] || continue
          kubectl patch -n "$namespace" "$tgb" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
          kubectl delete -n "$namespace" "$tgb" --ignore-not-found=true >/dev/null 2>&1 || true
        done
      }

      kubectl annotate ingress -n "${self.triggers.monitoring_namespace}" "${self.triggers.grafana_ingress}" \
        alb.ingress.kubernetes.io/load-balancer-attributes='${self.triggers.alb_attributes_destroy}' \
        --overwrite >/dev/null 2>&1 || true

      kubectl annotate ingress -n "${self.triggers.vault_namespace}" "${self.triggers.vault_ingress}" \
        alb.ingress.kubernetes.io/load-balancer-attributes='${self.triggers.alb_attributes_destroy}' \
        --overwrite >/dev/null 2>&1 || true

      sleep 20

      kubectl delete ingress -n "${self.triggers.monitoring_namespace}" "${self.triggers.grafana_ingress}" --ignore-not-found=true >/dev/null 2>&1 || true
      kubectl delete ingress -n "${self.triggers.vault_namespace}" "${self.triggers.vault_ingress}" --ignore-not-found=true >/dev/null 2>&1 || true
      kubectl delete svc -n "${self.triggers.postgres_namespace}" "${self.triggers.postgres_service}" --ignore-not-found=true >/dev/null 2>&1 || true

      kubectl wait --for=delete ingress/"${self.triggers.grafana_ingress}" -n "${self.triggers.monitoring_namespace}" --timeout=10m >/dev/null 2>&1 || true
      kubectl wait --for=delete ingress/"${self.triggers.vault_ingress}" -n "${self.triggers.vault_namespace}" --timeout=10m >/dev/null 2>&1 || true
      kubectl wait --for=delete svc/"${self.triggers.postgres_service}" -n "${self.triggers.postgres_namespace}" --timeout=10m >/dev/null 2>&1 || true

      patch_tgbs "${self.triggers.monitoring_namespace}"
      patch_tgbs "${self.triggers.vault_namespace}"
      patch_tgbs "${self.triggers.postgres_namespace}"
    EOT
  }

  depends_on = [
    helm_release.aws_load_balancer_controller,
    kubernetes_ingress_v1.grafana,
    kubernetes_ingress_v1.vault,
    kubernetes_service_v1.postgres
  ]
}
