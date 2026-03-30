# EKS + Vault com OpenTofu

Esta stack provisiona uma **plataforma de gerenciamento de segredos de alta disponibilidade** na AWS, totalmente automatizada via GitHub Actions.

## Infraestrutura de Rede e Computacao

Uma VPC dedicada com 3 sub-redes privadas e 3 publicas distribuidas em diferentes zonas de disponibilidade. O cluster EKS com 3 nos `t3.large` serve como substrato de execucao, com acesso publico e privado ao endpoint da API.

## HashiCorp Vault

3 replicas do Vault em modo HA usando **Raft consensus** como storage backend. Cada pod utiliza TLS mutual (certificado emitido pelo cert-manager com CA interna) para comunicacao entre peers. O desbloqueio automatico usa **AWS KMS** — sem recovery keys manuais. Snapshots do estado do Raft sao armazenados em S3 com criptografia SSE-KMS.

## Exposicao Publica e Seguranca de Borda

Um **ALB compartilhado** serve Vault (`https://vault.*`) e Grafana (`https://grafana.*`) com roteamento por host. TLS termina no ALB com certificado ACM validado via Route53. O External DNS sincroniza automaticamente os hostnames dos Ingress com Route53.

Um **WAF Regional** protege o ALB com: rate limiting por IP (2000 req/5min), lista de reputacao AWS, regras OWASP Top 10, filtro de inputs maliciosos e bloqueio de IPs anonimos/VPN.

## Observabilidade

Prometheus coleta metricas de todo o cluster incluindo o endpoint de telemetria do Vault. Grafana expoe os dashboards. Loki agrega os logs via Promtail rodando como DaemonSet em todos os nos.

## PostgreSQL e Credenciais Dinamicas

Um StatefulSet PostgreSQL 17 com volume EBS gp3 de 5Gi. O Vault gerencia o ciclo de vida de credenciais: cria usuarios temporarios com TTL de 10 minutos e os deleta automaticamente ao expirar — nenhuma aplicacao precisa conhecer a senha administrativa.

## CI/CD

| Workflow | Trigger | O que faz |
|----------|---------|-----------|
| `terraform-apply` | Manual | Provisiona toda a infra + bootstrap do Vault |
| `terraform-destroy` | Manual (requer digitar "DESTROY") | Limpa ALBs/NLBs/SGs antes do destroy para evitar dependencias circulares AWS, depois destroi tudo |

---

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
- `deletion_protection.enabled=false` por padrao em lab para facilitar o `destroy`.
- Se quiser um ambiente mais protegido contra remocao acidental, defina `alb_enable_deletion_protection = true` conscientemente.
- `Shield Advanced` opcional via `alb_enable_shield_advanced = true`.

## DNS Mais Rapido

- O `external-dns` agora faz reconciliacao por eventos com `--events`.
- O intervalo de sync caiu para `30s`.
- Isso reduz a janela em que os hostnames podem ficar em `NXDOMAIN` logo apos um novo `apply`.

## O Que O Bootstrap Configura

O script `scripts/bootstrap_vault.py` configura automaticamente no Vault:

- inicializacao e persistencia do `root_token` em S3 (`s3://bucket/vault-bootstrap/vault-init.json`, criptografado com KMS) ou localmente em `bootstrap/vault-init.json`
- secret engine `kv-v2` em `kv/`
- auth method `kubernetes/`
- auth method `approle/`
- audit device `file/` com `file_path=stdout` e `format=json`
- client counters com `enabled=enable` e `retention_months=12`
- secret engine `database/`
- connection `postgres`
- role dinamica `postgres-dynamic` com `default_ttl=10m` e `max_ttl=1h`
- policy `admin` com acesso total a todos os paths
- policy `ssh-rotator` com acesso restrito a `kv/data/ssh-passwords/*` (capabilities: create, update)
- role AppRole `ssh-rotator` vinculada a policy `ssh-rotator`, com `token_ttl=5m` e `token_max_ttl=10m`
- impressao do `role_id` e `secret_id` do AppRole `ssh-rotator` nos logs do bootstrap

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

AppRole ssh-rotator:

```bash
ROOT_TOKEN=$(jq -r .root_token bootstrap/vault-init.json)

kubectl exec -n vault vault-0 -- sh -lc "VAULT_ADDR=https://vault-0.vault-internal.vault.svc.cluster.local:8200 VAULT_CACERT=/vault/userconfig/ca/ca.crt VAULT_TOKEN=$ROOT_TOKEN vault read auth/approle/role/ssh-rotator/role-id"
kubectl exec -n vault vault-0 -- sh -lc "VAULT_ADDR=https://vault-0.vault-internal.vault.svc.cluster.local:8200 VAULT_CACERT=/vault/userconfig/ca/ca.crt VAULT_TOKEN=$ROOT_TOKEN vault policy read ssh-rotator"
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
- O `secret_id` do AppRole `ssh-rotator` e gerado a cada bootstrap. Secret_ids anteriores nao sao invalidados automaticamente — use o accessor para revogacao se necessario.
