locals {
  tags = {
    Project     = "vault-eks"
    Environment = var.environment
    ManagedBy   = "OpenTofu"
  }

  postgres_allowed_cidrs = distinct(concat(var.postgres_allowed_cidrs, [var.vpc_cidr]))
  vault_allowed_cidrs    = distinct(var.vault_allowed_cidrs)

  vault_namespace              = "vault"
  vault_service_account        = "vault"
  monitoring_namespace         = "monitoring"
  postgres_namespace           = "postgres-aks"
  cert_manager_namespace       = "cert-manager"
  cert_manager_service_account = "cert-manager"
  external_dns_namespace       = "external-dns"
  external_dns_service_account = "external-dns"
}
