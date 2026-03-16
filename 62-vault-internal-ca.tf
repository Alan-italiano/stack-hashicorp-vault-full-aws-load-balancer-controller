resource "tls_private_key" "vault_internal_ca" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "vault_internal_ca" {
  private_key_pem       = tls_private_key.vault_internal_ca.private_key_pem
  is_ca_certificate     = true
  validity_period_hours = 87600
  early_renewal_hours   = 720

  allowed_uses = [
    "cert_signing",
    "key_encipherment",
    "digital_signature",
    "server_auth",
    "client_auth"
  ]

  subject {
    common_name  = "vault-internal-ca"
    organization = "vault-eks"
  }
}

resource "kubernetes_secret_v1" "vault_internal_ca" {
  metadata {
    name      = "vault-internal-ca"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }

  data = {
    "tls.crt" = tls_self_signed_cert.vault_internal_ca.cert_pem
    "tls.key" = tls_private_key.vault_internal_ca.private_key_pem
    "ca.crt"  = tls_self_signed_cert.vault_internal_ca.cert_pem
  }

  type = "Opaque"
}
