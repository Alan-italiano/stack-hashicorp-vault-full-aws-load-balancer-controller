variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "lab"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "vault-eks-lab"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.30"
}

variable "vault_hostname" {
  description = "Vault FQDN"
  type        = string
  default     = "vault.lab-internal.com.br"
}

variable "vault_image_tag" {
  description = "Vault container image tag"
  type        = string
  default     = "1.21.4"
}

variable "domain_name" {
  description = "Primary DNS zone domain name"
  type        = string
  default     = "lab-internal.com.br"
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID"
  type        = string
  default     = "Z085094335FXPD3PXEQRT"
}

variable "alb_scheme" {
  description = "Scheme used by the shared ALB"
  type        = string
  default     = "internet-facing"
}

variable "alb_group_name" {
  description = "Ingress group name used to share a single ALB between services"
  type        = string
  default     = "platform-edge"
}

variable "alb_ssl_policy" {
  description = "TLS policy applied to the public ALB HTTPS listener"
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

variable "alb_enable_deletion_protection" {
  description = "Enable deletion protection on the public ALB. For lab environments, keeping this false makes destroy safer."
  type        = bool
  default     = false
}

variable "alb_enable_shield_advanced" {
  description = "Enable AWS Shield Advanced on the public ALB. Additional AWS charges apply."
  type        = bool
  default     = false
}

variable "alb_waf_rate_limit" {
  description = "Requests per 5-minute window per source IP before WAF blocks the request"
  type        = number
  default     = 2000
}

variable "vault_allowed_cidrs" {
  description = "Source CIDRs allowed to access Vault through the ALB. Leave empty to keep Vault publicly reachable."
  type        = list(string)
  default     = []
}

variable "vault_snapshot_bucket_name" {
  description = "Bucket used by Vault snapshots"
  type        = string
  default     = "vault-lab-snapshots-unique"
}

variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  default     = "10.42.0.0/16"
}

variable "private_subnets" {
  description = "Private subnet CIDRs"
  type        = list(string)
  default     = ["10.42.1.0/24", "10.42.2.0/24", "10.42.3.0/24"]
}

variable "public_subnets" {
  description = "Public subnet CIDRs"
  type        = list(string)
  default     = ["10.42.101.0/24", "10.42.102.0/24", "10.42.103.0/24"]
}

variable "node_instance_type" {
  description = "EKS node instance type"
  type        = string
  default     = "t3.large"
}

variable "vault_storage_class_name" {
  description = "StorageClass used by Vault data PVCs"
  type        = string
  default     = "ebs-gp3"
}

variable "grafana_hostname" {
  description = "Grafana FQDN"
  type        = string
  default     = "grafana.lab-internal.com.br"
}

variable "postgres_allowed_cidrs" {
  description = "Allowed source CIDRs for external PostgreSQL LoadBalancer access"
  type        = list(string)
  default     = []
}

variable "postgres_database_name" {
  description = "PostgreSQL database name"
  type        = string
}

variable "postgres_admin_username" {
  description = "PostgreSQL admin username"
  type        = string
}

variable "postgres_admin_password" {
  description = "PostgreSQL admin password"
  type        = string
  sensitive   = true
}
