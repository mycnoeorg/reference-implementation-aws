# Demo Artifacts — CGU

Manifestos usados pelo roteiro **`../DEMO-CGU.md`**. Aplicar na ordem numérica.

Todos foram validados contra o cluster `cnoe-ref-impl` em `us-west-1`.

## Ordem de aplicação na demo

| Arquivo | Tecnologia | Seção anexo | O que demonstra |
|---|---|---|---|
| `01-environment-config.yaml` | Crossplane `EnvironmentConfig` | §8.1, §10.2 | Fonte única de defaults da plataforma (tags, região, CIDRs) |
| `02-cgu-bucket-claim.yaml` | Crossplane Composition + Claim | §3, §10.1 | 1 Claim → 3 Managed Resources AWS (Bucket + PublicAccessBlock + SSE) |
| `03-kro-webapp-rgd.yaml` | KRO `ResourceGraphDefinition` | §10.1 bullet 2 | Registra um schema customizado `WebApp` (Deployment+Service) |
| `04-kro-webapp-instance.yaml` | Consumir o CRD gerado pelo KRO | §9 | Usuário final cria um `WebApp` e KRO materializa o grafo |
| `05-tf-workspace.yaml` | `provider-terraform` `Workspace` | §5 Fase 1 | DynamoDB table real via módulo HCL encapsulado como recurso K8s |
| `06-observe-only.template.yaml` | Crossplane `managementPolicies: [Observe]` | §7.1 | Adoção segura de recurso legado, sem permitir deleção |
| `07-tf-workspace-gcp.yaml` | `provider-terraform` `Workspace` | §5, §6 | GCP Pub/Sub topic+subscription via Terraform no mesmo cluster |
| `08-multicloud-pipeline-claim.yaml` | Crossplane Composition + `provider-terraform` | §6, §10.1 | 1 Claim → AWS DynamoDB + GCP Pub/Sub (composição heterogênea) |

## Pré-requisitos (já instalados no cluster)

```bash
# Providers Crossplane
kubectl get provider.pkg.crossplane.io
# Esperado: provider-aws-s3, provider-aws-dynamodb, provider-terraform

# KRO
kubectl -n kro-system get deploy kro

# ESO ClusterSecretStore
kubectl get clustersecretstore aws-secretsmanager

# ProviderConfigs Terraform (AWS default + GCP)
kubectl get providerconfig.tf.upbound.io
# Esperado: default (AWS), gcp
```

## Como aplicar — modo demo (passo-a-passo)

```bash
export AWS_PROFILE=hubcnoe
export AWS_REGION=us-west-1
cd ~/cnoe-ref-impl/demo-artifacts

# 1. Defaults da plataforma
kubectl apply -f 01-environment-config.yaml

# 2. Crossplane: 1 Claim → 3 MRs AWS
kubectl apply -f 02-cgu-bucket-claim.yaml

# 3. KRO RGD + instância
kubectl apply -f 03-kro-webapp-rgd.yaml
sleep 3
kubectl apply -f 04-kro-webapp-instance.yaml

# 4. Terraform Workspace (módulo inline HCL)
kubectl apply -f 05-tf-workspace.yaml

# 5. Observe-only (adoção de bucket legado)
BUCKET_NAME="cgu-legacy-$(date +%s)"
aws s3api create-bucket --bucket "$BUCKET_NAME" --region us-west-1 \
  --create-bucket-configuration LocationConstraint=us-west-1 --profile hubcnoe
echo "$BUCKET_NAME" > /tmp/cgu-legacy.txt
sed -e "s/BUCKET_NAME_PLACEHOLDER/${BUCKET_NAME}/" 06-observe-only.template.yaml \
  | kubectl apply -f -
```

## Cleanup

```bash
kubectl delete -f 08-multicloud-pipeline-claim.yaml --ignore-not-found
kubectl delete -f 04-kro-webapp-instance.yaml --ignore-not-found
kubectl delete -f 03-kro-webapp-rgd.yaml --ignore-not-found
kubectl delete -f 07-tf-workspace-gcp.yaml --ignore-not-found
kubectl delete -f 05-tf-workspace.yaml --ignore-not-found
kubectl delete -f 02-cgu-bucket-claim.yaml --ignore-not-found
kubectl delete -f 01-environment-config.yaml --ignore-not-found
kubectl delete bucket cgu-legacy-adopted --ignore-not-found

# Bucket legado da demo Observe
[ -f /tmp/cgu-legacy.txt ] && \
  aws s3 rb "s3://$(cat /tmp/cgu-legacy.txt)" --force --profile hubcnoe --region us-west-1
```

## Observações técnicas

- `02-cgu-bucket-claim.yaml` usa a XRD `xobjectstorages.awsblueprints.io` já instalada. O schema aceita só `resourceConfig`, não tem `parameters` nesta versão.
- `05-tf-workspace.yaml` provisiona uma tabela DynamoDB real na AWS via `provider-terraform`. Requer Pod Identity association para o SA do provider-terraform (criada por `scripts/setup-tf-pod-identity.sh`).
- `06-observe-only.template.yaml` tem um placeholder `BUCKET_NAME_PLACEHOLDER` que precisa ser substituído pelo nome real do bucket antes de aplicar.
- `07-tf-workspace-gcp.yaml` provisiona Pub/Sub topic+subscription no GCP. Requer ProviderConfig `gcp` com credenciais GCP (criado por `scripts/setup-gcp-credentials.sh`).
- `08-multicloud-pipeline-claim.yaml` usa a XRD `xmulticloudpipelines.awsblueprints.io` que compõe AWS DynamoDB + GCP Pub/Sub em um único Claim. Demonstra composição heterogênea (§6 do anexo).
- O estado Terraform é salvo em Secrets Kubernetes (backend kubernetes) — sem S3+DynamoDB para state.
