resource "kubernetes_namespace" "cert_manager" {
  depends_on = [time_sleep.eks_access_ready]

  metadata {
    name = local.cert_manager_namespace
  }
}

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.20.0"
  namespace        = kubernetes_namespace.cert_manager.metadata[0].name
  create_namespace = false
  wait             = true
  timeout          = 600

  values = [
    yamlencode({
      crds = {
        enabled = true
      }
      serviceAccount = {
        create = true
        name   = local.cert_manager_service_account
      }
      prometheus = {
        enabled = false
        servicemonitor = {
          enabled = false
        }
      }
    })
  ]

  depends_on = [
    helm_release.aws_load_balancer_controller
  ]
}

resource "kubectl_manifest" "vault_internal_ca_issuer" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Issuer"
    metadata = {
      name      = "vault-internal-ca"
      namespace = local.vault_namespace
    }
    spec = {
      ca = {
        secretName = kubernetes_secret_v1.vault_internal_ca.metadata[0].name
      }
    }
  })

  depends_on = [
    helm_release.cert_manager,
    kubernetes_namespace.vault,
    kubernetes_secret_v1.vault_internal_ca,
  ]
}

resource "kubectl_manifest" "vault_server_certificate" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "vault-server-tls"
      namespace = local.vault_namespace
    }
    spec = {
      secretName  = "vault-server-tls"
      duration    = "2160h"
      renewBefore = "360h"
      issuerRef = {
        name = "vault-internal-ca"
        kind = "Issuer"
      }
      commonName = var.vault_hostname
      dnsNames = [
        var.vault_hostname,
        "vault",
        "vault.${local.vault_namespace}",
        "vault.${local.vault_namespace}.svc",
        "vault.${local.vault_namespace}.svc.cluster.local",
        "vault-active.${local.vault_namespace}.svc",
        "vault-active.${local.vault_namespace}.svc.cluster.local",
        "vault-internal.${local.vault_namespace}.svc",
        "vault-internal.${local.vault_namespace}.svc.cluster.local",
        "*.vault-internal.${local.vault_namespace}.svc.cluster.local",
        "localhost",
      ]
      ipAddresses = [
        "127.0.0.1",
      ]
      usages = [
        "server auth",
        "client auth",
        "digital signature",
        "key encipherment",
      ]
    }
  })

  depends_on = [
    kubectl_manifest.vault_internal_ca_issuer,
  ]
}
