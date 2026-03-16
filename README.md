# EKS + Vault com OpenTofu

Esta stack provisiona:

1. VPC e EKS com add-ons basicos
2. IRSA e IAM para o Vault
3. KMS para auto-unseal do Vault
4. Bucket S3 para snapshots do Vault
5. cert-manager para a PKI interna do Vault
6. AWS Load Balancer Controller e external-dns para publicar Vault e Grafana por ALB
7. Certificado ACM no ALB validado automaticamente no Route53
8. WAF regional com regras gerenciadas da AWS e rate limiting no ALB
9. Prometheus, Grafana, Loki e Promtail
10. Vault HA com Raft e telemetria integrada
11. PostgreSQL no cluster para uso com secrets dinamicos

## Uso

No PowerShell:

```powershell
$env:TF_VAR_postgres_admin_password = "sua-senha-postgres"
```

```bash
cp tofu.tfvars.example tofu.tfvars
# ajuste valores em tofu.tfvars

export TF_VAR_postgres_admin_password='sua-senha-postgres'

tofu init
tofu plan -var-file=tofu.tfvars
tofu apply -var-file=tofu.tfvars -auto-approve
```

## Acesso

- Vault: `https://vault.lab-internal.com.br`
- Grafana: `https://grafana.lab-internal.com.br`
- Usuario padrao do Grafana: `admin`
- Senha padrao do Grafana:

```bash
kubectl -n monitoring get secret kube-prometheus-stack-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d; echo
```

Comandos uteis tambem via outputs do Terraform:

```bash
tofu output vault_url
tofu output grafana_url
tofu output grafana_admin_username
tofu output -raw grafana_admin_password_command
tofu output -raw vault_status_command
tofu output -raw vault_raft_peers_command
tofu output alb_acm_certificate_arn
tofu output alb_waf_web_acl_arn
tofu output route53_zone_id
```

## Protecao Do Vault

- O `vault` pode ser restringido por CIDR no proprio ALB com `vault_allowed_cidrs`.
- Quando `vault_allowed_cidrs` estiver preenchido, o Ingress do Vault recebe `alb.ingress.kubernetes.io/inbound-cidrs`.
- O Grafana continua sem essa restricao, a menos que voce queira aplicar a mesma estrategia nele.

## Protecoes Do ALB

- AWS WAF regional anexado ao ALB com `AWSManagedRulesAmazonIpReputationList`, `AWSManagedRulesCommonRuleSet`, `AWSManagedRulesKnownBadInputsRuleSet` e `AWSManagedRulesAnonymousIpList`.
- Rate limiting por IP no WAF, configurado por `alb_waf_rate_limit` por janela de 5 minutos.
- `routing.http.drop_invalid_header_fields.enabled=true` para reduzir risco de HTTP desync.
- `routing.http.desync_mitigation_mode=strictest` no ALB.
- `deletion_protection.enabled=true` por padrao.
- `Shield Advanced` opcional via `alb_enable_shield_advanced = true`.

## DNS Mais Rapido

- O `external-dns` agora faz reconciliacao por eventos com `--events`.
- O intervalo de sync caiu para `30s`.
- Isso reduz a janela em que os hostnames podem ficar em `NXDOMAIN` logo apos um novo `apply`.

## O Que O Bootstrap Configura

O script `scripts/bootstrap_vault.py` configura automaticamente no Vault:

- inicializacao e persistencia do `root_token` em `bootstrap/vault-init.json`
- secret engine `kv-v2` em `kv/`
- auth method `kubernetes/`
- audit device `file/` com `file_path=stdout` e `format=json`
- client counters com `enabled=enable` e `retention_months=12`
- secret engine `database/`
- connection `postgres`
- role dinamica `postgres-dynamic` com `default_ttl=10m` e `max_ttl=1h`

## Validacoes

Certificados emitidos no cluster:

```bash
kubectl get certificates -A
```

Pods principais:

```bash
kubectl get pods -n monitoring
kubectl get pods -n vault
kubectl get pods -n external-dns
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

Status do Vault:

```bash
kubectl exec -n vault vault-0 -- sh -lc 'VAULT_ADDR=https://vault-0.vault-internal.vault.svc.cluster.local:8200 VAULT_CACERT=/vault/userconfig/ca/ca.crt vault status'
```

Peers do Raft:

```bash
ROOT_TOKEN=$(jq -r .root_token bootstrap/vault-init.json)
kubectl exec -n vault vault-0 -- sh -lc "VAULT_ADDR=https://vault-0.vault-internal.vault.svc.cluster.local:8200 VAULT_CACERT=/vault/userconfig/ca/ca.crt VAULT_TOKEN=$ROOT_TOKEN vault operator raft list-peers"
```

Audit, counters e database engine:

```bash
ROOT_TOKEN=$(jq -r .root_token bootstrap/vault-init.json)

kubectl exec -n vault vault-0 -- sh -lc "VAULT_ADDR=https://vault-0.vault-internal.vault.svc.cluster.local:8200 VAULT_CACERT=/vault/userconfig/ca/ca.crt VAULT_TOKEN=$ROOT_TOKEN vault audit list"
kubectl exec -n vault vault-0 -- sh -lc "VAULT_ADDR=https://vault-0.vault-internal.vault.svc.cluster.local:8200 VAULT_CACERT=/vault/userconfig/ca/ca.crt VAULT_TOKEN=$ROOT_TOKEN vault read sys/internal/counters/config"
kubectl exec -n vault vault-0 -- sh -lc "VAULT_ADDR=https://vault-0.vault-internal.vault.svc.cluster.local:8200 VAULT_CACERT=/vault/userconfig/ca/ca.crt VAULT_TOKEN=$ROOT_TOKEN vault read database/config/postgres"
kubectl exec -n vault vault-0 -- sh -lc "VAULT_ADDR=https://vault-0.vault-internal.vault.svc.cluster.local:8200 VAULT_CACERT=/vault/userconfig/ca/ca.crt VAULT_TOKEN=$ROOT_TOKEN vault read database/roles/postgres-dynamic"
```

Ingressos e DNS:

```bash
kubectl get ingress -A
kubectl logs -n external-dns deploy/external-dns --since=5m
```

## Observacoes

- Substitua `SEU_IP_PUBLICO/32` em `tofu.tfvars` pelo IP ou bloco CIDR que deve acessar o Vault.
- Se `vault_allowed_cidrs = []`, o Vault continua publicamente alcancavel.
- Zona DNS esperada no Route53: `lab-internal.com.br`, com Hosted Zone ID `Z085094335FXPD3PXEQRT`.
- O `external-dns` cria e atualiza os registros `vault.lab-internal.com.br` e `grafana.lab-internal.com.br` na propria zona Route53.
- O ALB usa um certificado publico do ACM validado por DNS no Route53 para os endpoints externos.
- O WAF regional protege o ALB com regras gerenciadas e rate limiting. Ajuste `alb_waf_rate_limit` conforme seu volume legitimo.
- `alb_enable_shield_advanced` fica `false` por padrao porque Shield Advanced tem custo adicional.
- O `cert-manager` depende do `aws-load-balancer-controller` para evitar falhas de webhook durante o bootstrap.
- O `cert-manager` fica restrito a automacao da PKI interna do Vault dentro do cluster.
- O Vault usa uma CA interna dedicada para trafego entre pods.
- O Vault publica metricas de telemetria e cria `ServiceMonitor` para coleta pelo Prometheus Operator.
