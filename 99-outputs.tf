output "eks_cluster_name" {
  value       = module.eks.cluster_name
  description = "EKS cluster name"
}

output "eks_cluster_endpoint" {
  value       = module.eks.cluster_endpoint
  description = "EKS API endpoint"
}

output "vault_kms_key_arn" {
  value       = aws_kms_key.vault_unseal.arn
  description = "KMS key ARN used by Vault auto-unseal"
}

output "vault_irsa_role_arn" {
  value       = module.irsa_vault.iam_role_arn
  description = "IAM role used only by Vault service account"
}

output "vault_snapshot_bucket" {
  value       = aws_s3_bucket.vault_snapshots.id
  description = "S3 bucket for Vault snapshots"
}

output "vault_url" {
  value       = "https://${var.vault_hostname}"
  description = "Vault public URL exposed through the shared ALB"
}

output "vault_status_command" {
  value       = "kubectl exec -n vault vault-0 -- sh -lc 'VAULT_ADDR=https://vault-0.vault-internal.vault.svc.cluster.local:8200 VAULT_CACERT=/vault/userconfig/ca/ca.crt vault status'"
  description = "Command to check Vault status from the active pod"
}

output "vault_raft_peers_command" {
  value       = "ROOT_TOKEN=$(jq -r .root_token bootstrap/vault-init.json) && kubectl exec -n vault vault-0 -- sh -lc \"VAULT_ADDR=https://vault-0.vault-internal.vault.svc.cluster.local:8200 VAULT_CACERT=/vault/userconfig/ca/ca.crt VAULT_TOKEN=$ROOT_TOKEN vault operator raft list-peers\""
  description = "Command to list Vault raft peers using the persisted bootstrap root token"
}

output "grafana_url" {
  value       = "https://${var.grafana_hostname}"
  description = "Grafana public URL exposed through the shared ALB"
}

output "grafana_admin_username" {
  value       = "admin"
  description = "Default Grafana admin username"
}

output "grafana_admin_password_command" {
  value       = "kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath=\"{.data.admin-password}\" | base64 -d; echo"
  description = "Command to retrieve the default Grafana admin password"
}

output "alb_acm_certificate_arn" {
  value       = aws_acm_certificate.edge.arn
  description = "ACM certificate ARN attached to the shared ALB listeners"
}

output "alb_waf_web_acl_arn" {
  value       = aws_wafv2_web_acl.edge.arn
  description = "Regional AWS WAF web ACL attached to the shared ALB"
}

output "route53_zone_id" {
  value       = var.route53_zone_id
  description = "Route53 hosted zone ID used by ACM validation and external-dns"
}

output "postgres_internal_host" {
  value       = "postgres-service.${local.postgres_namespace}.svc.cluster.local"
  description = "PostgreSQL internal DNS name inside the cluster"
}

output "postgres_internal_port" {
  value       = 5432
  description = "PostgreSQL internal port"
}

output "postgres_external_service" {
  value       = "postgres-service.${local.postgres_namespace}"
  description = "Kubernetes service name exposed externally via LoadBalancer"
}
