resource "kubernetes_namespace" "external_dns" {
  metadata {
    name = local.external_dns_namespace
  }
}

resource "helm_release" "aws_load_balancer_controller" {
  name             = "aws-load-balancer-controller"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-load-balancer-controller"
  namespace        = "kube-system"
  create_namespace = false
  wait             = true
  timeout          = 600

  values = [
    yamlencode({
      clusterName = module.eks.cluster_name
      region      = var.region
      vpcId       = module.vpc.vpc_id
      serviceAccount = {
        create = true
        name   = "aws-load-balancer-controller"
        annotations = {
          "eks.amazonaws.com/role-arn" = module.irsa_aws_load_balancer_controller.iam_role_arn
        }
      }
    })
  ]

  depends_on = [
    module.irsa_aws_load_balancer_controller
  ]
}

resource "helm_release" "external_dns" {
  name             = "external-dns"
  repository       = "https://kubernetes-sigs.github.io/external-dns/"
  chart            = "external-dns"
  namespace        = kubernetes_namespace.external_dns.metadata[0].name
  create_namespace = false
  wait             = true
  timeout          = 600

  values = [
    yamlencode({
      provider = {
        name = "aws"
      }
      policy             = "upsert-only"
      triggerLoopOnEvent = true
      interval           = "30s"
      txtOwnerId         = module.eks.cluster_name
      domainFilters      = [var.domain_name]
      sources            = ["ingress"]
      extraArgs = [
        "--aws-zone-type=public",
        "--zone-id-filter=${var.route53_zone_id}"
      ]
      serviceAccount = {
        create = true
        name   = local.external_dns_service_account
        annotations = {
          "eks.amazonaws.com/role-arn" = module.irsa_external_dns.iam_role_arn
        }
      }
    })
  ]

  depends_on = [
    module.irsa_external_dns
  ]
}

resource "aws_acm_certificate" "edge" {
  domain_name               = var.vault_hostname
  subject_alternative_names = [var.grafana_hostname]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = local.tags
}

resource "aws_route53_record" "edge_validation" {
  for_each = {
    for dvo in aws_acm_certificate.edge.domain_validation_options : dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }

  zone_id         = var.route53_zone_id
  allow_overwrite = true
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.value]
}

resource "aws_acm_certificate_validation" "edge" {
  certificate_arn         = aws_acm_certificate.edge.arn
  validation_record_fqdns = [for record in aws_route53_record.edge_validation : record.fqdn]
}

resource "kubernetes_ingress_v1" "vault" {
  metadata {
    name      = "vault-alb"
    namespace = kubernetes_namespace.vault.metadata[0].name
    annotations = merge({
      "alb.ingress.kubernetes.io/backend-protocol"           = "HTTPS"
      "alb.ingress.kubernetes.io/certificate-arn"            = aws_acm_certificate.edge.arn
      "alb.ingress.kubernetes.io/group.name"                 = "${var.cluster_name}-${var.alb_group_name}"
      "alb.ingress.kubernetes.io/group.order"                = "20"
      "alb.ingress.kubernetes.io/healthcheck-path"           = "/v1/sys/health?standbyok=true&sealedcode=204&uninitcode=204"
      "alb.ingress.kubernetes.io/listen-ports"               = "[{\"HTTP\":80},{\"HTTPS\":443}]"
      "alb.ingress.kubernetes.io/load-balancer-attributes"   = "deletion_protection.enabled=${lower(tostring(var.alb_enable_deletion_protection))},routing.http.drop_invalid_header_fields.enabled=true,routing.http.desync_mitigation_mode=strictest"
      "alb.ingress.kubernetes.io/scheme"                     = var.alb_scheme
      "alb.ingress.kubernetes.io/shield-advanced-protection" = lower(tostring(var.alb_enable_shield_advanced))
      "alb.ingress.kubernetes.io/ssl-policy"                 = var.alb_ssl_policy
      "alb.ingress.kubernetes.io/ssl-redirect"               = "443"
      "alb.ingress.kubernetes.io/success-codes"              = "200,204,429,472,473"
      "alb.ingress.kubernetes.io/target-type"                = "ip"
      "alb.ingress.kubernetes.io/wafv2-acl-arn"              = aws_wafv2_web_acl.edge.arn
      "external-dns.alpha.kubernetes.io/hostname"            = var.vault_hostname
      }, length(local.vault_allowed_cidrs) > 0 ? {
      "alb.ingress.kubernetes.io/inbound-cidrs" = join(",", local.vault_allowed_cidrs)
    } : {})
  }

  spec {
    ingress_class_name = "alb"

    rule {
      host = var.vault_hostname

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = "vault-active"
              port {
                number = 8200
              }
            }
          }
        }
      }
    }
  }

  depends_on = [
    aws_acm_certificate_validation.edge,
    aws_wafv2_web_acl.edge,
    helm_release.aws_load_balancer_controller,
    helm_release.external_dns,
    helm_release.vault
  ]
}

resource "kubernetes_ingress_v1" "grafana" {
  metadata {
    name      = "grafana-alb"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    annotations = {
      "alb.ingress.kubernetes.io/certificate-arn"            = aws_acm_certificate.edge.arn
      "alb.ingress.kubernetes.io/group.name"                 = "${var.cluster_name}-${var.alb_group_name}"
      "alb.ingress.kubernetes.io/group.order"                = "10"
      "alb.ingress.kubernetes.io/healthcheck-path"           = "/api/health"
      "alb.ingress.kubernetes.io/listen-ports"               = "[{\"HTTP\":80},{\"HTTPS\":443}]"
      "alb.ingress.kubernetes.io/load-balancer-attributes"   = "deletion_protection.enabled=${lower(tostring(var.alb_enable_deletion_protection))},routing.http.drop_invalid_header_fields.enabled=true,routing.http.desync_mitigation_mode=strictest"
      "alb.ingress.kubernetes.io/scheme"                     = var.alb_scheme
      "alb.ingress.kubernetes.io/shield-advanced-protection" = lower(tostring(var.alb_enable_shield_advanced))
      "alb.ingress.kubernetes.io/ssl-policy"                 = var.alb_ssl_policy
      "alb.ingress.kubernetes.io/ssl-redirect"               = "443"
      "alb.ingress.kubernetes.io/target-type"                = "ip"
      "alb.ingress.kubernetes.io/wafv2-acl-arn"              = aws_wafv2_web_acl.edge.arn
      "external-dns.alpha.kubernetes.io/hostname"            = var.grafana_hostname
    }
  }

  spec {
    ingress_class_name = "alb"

    rule {
      host = var.grafana_hostname

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = "kube-prometheus-stack-grafana"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  depends_on = [
    aws_acm_certificate_validation.edge,
    aws_wafv2_web_acl.edge,
    helm_release.aws_load_balancer_controller,
    helm_release.external_dns,
    helm_release.kube_prometheus_stack
  ]
}
