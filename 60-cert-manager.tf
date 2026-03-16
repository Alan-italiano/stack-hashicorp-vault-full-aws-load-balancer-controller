resource "kubernetes_namespace" "cert_manager" {
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

resource "null_resource" "cert_manager_resources" {
  triggers = {
    vault_hostname        = var.vault_hostname
    vault_namespace       = local.vault_namespace
    internal_ca_cert_hash = sha1(tls_self_signed_cert.vault_internal_ca.cert_pem)
  }

  provisioner "local-exec" {
    command = <<-EOT
      cat <<EOF | kubectl apply -f -
      apiVersion: cert-manager.io/v1
      kind: Issuer
      metadata:
        name: vault-internal-ca
        namespace: ${local.vault_namespace}
      spec:
        ca:
          secretName: ${kubernetes_secret_v1.vault_internal_ca.metadata[0].name}
      ---
      apiVersion: cert-manager.io/v1
      kind: Certificate
      metadata:
        name: vault-server-tls
        namespace: ${local.vault_namespace}
      spec:
        secretName: vault-server-tls
        duration: 2160h
        renewBefore: 360h
        issuerRef:
          name: vault-internal-ca
          kind: Issuer
        commonName: ${var.vault_hostname}
        dnsNames:
          - ${var.vault_hostname}
          - vault
          - vault.${local.vault_namespace}
          - vault.${local.vault_namespace}.svc
          - vault.${local.vault_namespace}.svc.cluster.local
          - vault-active.${local.vault_namespace}.svc
          - vault-active.${local.vault_namespace}.svc.cluster.local
          - vault-internal.${local.vault_namespace}.svc
          - vault-internal.${local.vault_namespace}.svc.cluster.local
          - '*.vault-internal.${local.vault_namespace}.svc.cluster.local'
          - localhost
        ipAddresses:
          - 127.0.0.1
        usages:
          - server auth
          - client auth
          - digital signature
          - key encipherment
      EOF
    EOT
  }

  depends_on = [
    helm_release.cert_manager,
    kubernetes_secret_v1.vault_internal_ca
  ]
}

resource "null_resource" "wait_for_certificates" {
  triggers = {
    certs_hash = sha1(null_resource.cert_manager_resources.id)
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl wait --namespace ${local.vault_namespace} --for=condition=Ready certificate/vault-server-tls --timeout=10m
    EOT
  }

  depends_on = [
    null_resource.cert_manager_resources
  ]
}
