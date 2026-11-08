# ShopNow GitOps v2

Repo GitOps cho **ShopNow v2** (15 service + web + aiops, monorepo `Luo-Zhii/shop-microservice`), chạy trên
hạ tầng **hybrid**: các cụm on-prem và EKS `ap-southeast-1` do **một Argo CD hub** quản lý. Mọi thứ đều khai báo trong git:
không có `kubectl apply` tay (trừ bước bootstrap hub) và không có bí mật nào trong repo.

> Bản v1 (Kustomize cho app Java, ArgoCD poll GitLab) nằm ở `legacy/v1/`, giữ nguyên lịch sử git.
> v1 từng commit secret thật (`legacy/v1/base/02-secrets.yaml`), nên **phải đổi** mọi credential đó.

## Luồng GitOps hybrid

```
 shop-microservice (GitHub Actions)                         shop-gitops (repo này)
 ┌──────────────────────────────────┐   PR: bump tag     ┌─────────────────────────────────────┐
 │ test → build → cosign sign       │──(yq images.yaml)─▶│ environments/<env>/images.yaml       │
 │ (keyless, OIDC GitHub)           │                    │ + validate.yml: lint/template/       │
 └──────────────┬───────────────────┘                    │   kubeconform/kyverno test           │
                │ push image                             └──────────────────┬──────────────────┘
                ▼                                                           │ merge vào main
 ┌──────────────────────────────────────────────┐                           ▼
 │ ghcr.io/luo-zhii/shopnow/*        (dev)      │        ┌──────────────────────────────────────┐
 │ registry.luo.io.vn/shopnow/*      (Harbor)   │        │ Argo CD HUB (cụm quản trị on-prem)   │
 │ <acct>.dkr.ecr.ap-southeast-1…/shopnow/* (ECR)│        │ root app → AppProject + ApplicationSet│
 └──────────────────────────────────────────────┘        │ shopnow-apps / platform-addons /     │
                ▲ pull (Kyverno verifyImages)            │ platform-config (chọn cụm theo label) │
                │                                        └───────┬───────────────────┬──────────┘
                │                     LAN (token SA qua Vault)    │                   │ VPN/DX + IAM Roles Anywhere
        ┌───────┴────────────────────────────────────┐   ┌───────▼────────┐   ┌──────▼──────────────────┐
        │ on-prem: shopnow-dev, shopnow-staging,     │◀──┘                │   │ EKS shopnow-prod-aws     │
        │ shopnow-prod-onprem                        │                    │   │ gp3 · ALB · Secrets Mgr  │
        │ Longhorn · MetalLB · Vault · CNPG · Redis  │                    │   │ RDS · ElastiCache · S3   │
        │ MinIO · Strimzi · Mongo · OpenSearch       │                    │   │ Strimzi · Mongo · OS     │
        └────────────────────────────────────────────┘                    │   └──────────────────────────┘
                     Route53/DNS: shop.luo.io.vn, api.luo.io.vn → weighted/failover giữa prod-onprem ⇄ prod-aws
```

## Cấu trúc thư mục

```
charts/shopnow-service/        Helm chart dùng chung: Deployment | Argo Rollout (canary + AnalysisTemplate),
                               Service, SA (IRSA), HPA | KEDA, PDB, NetworkPolicy, ServiceMonitor, PrometheusRule,
                               ExternalSecret, ConfigMap env, Ingress; values.schema.json; ci/ (values để lint)
apps/shopnow/
  values-common.yaml           giá trị chung (JWKS, URL nội bộ, autoscaling mặc định)
  services/<svc>.yaml          17 file: cổng, DB/Redis/Kafka/Mongo/S3, topic cho KEDA, secret keys, rollout
environments/<env>/            dev · staging · prod-onprem · prod-aws
  values.yaml                  registry, domain *.luo.io.vn, ingress class, secret store, endpoint dữ liệu
  services/<svc>.yaml          ghi đè riêng service × env (vd prod-aws ai-service dùng Bedrock)
  images.yaml                  tag/digest image — CI ghi
  platform/kustomization.yaml  ghép platform/* cho cụm đó (+ patch replicas, storageClass, vault path)
  addons/<addon>.yaml          ghi đè values addon theo env
argocd/
  bootstrap/                   values cài Argo CD hub + root app-of-apps
  apps/                        AppProject, ApplicationSet shopnow-apps / platform-addons / platform-config,
                               clusters/ (đăng ký cụm on-prem qua ExternalSecret, EKS qua awsAuthConfig)
platform/
  addons/<addon>/              values Helm của addon (values.yaml + values-<provider>.yaml)
  namespaces/ kafka/ postgres/ data/{redis,mongodb,opensearch,onprem-objectstore}/
  secrets/{vault,aws,examples}/  ClusterSecretStore + ExternalSecret mẫu
  kyverno/{policies,tests}/    ClusterPolicy + kyverno test (resource đúng/sai, kết quả mong đợi)
  observability/               otel-collector/ (values gateway), alertmanager/ (route + secret),
                               grafana/ (datasource + 4 dashboard JSON)
  slo/                         Sloth PrometheusServiceLevel (multi-window multi-burn-rate)
  chaos/{experiments,schedules}/ Chaos Mesh (annotation aiops.shopnow.io/expected-root-cause)
  storage/gp3  network/{metallb,cert-manager}
scripts/                       values-args.sh (thứ tự values như Argo CD), promote.sh
Makefile  .github/workflows/validate.yml  .yamllint.yaml
```

## Môi trường & nhãn cụm

| Cụm Argo CD (`name`) | `shopnow.io/env` | `shopnow.io/provider` | Registry | Secret store | Dữ liệu |
|---|---|---|---|---|---|
| shopnow-dev | dev | onprem | ghcr.io/luo-zhii | vault (`kv-dev`) | trong cụm, 1 bản sao, search = Postgres FTS |
| shopnow-staging | staging | onprem | registry.luo.io.vn | vault (`kv-staging`) | trong cụm, HA, có lịch chaos |
| shopnow-prod-onprem | prod-onprem | onprem | registry.luo.io.vn | vault (`kv-prod`) | trong cụm, backup PG → S3 (DR) |
| shopnow-prod-aws | prod-aws | aws | ECR | aws-secrets-manager | RDS, ElastiCache, S3; Kafka/Mongo/OpenSearch trong cụm |

Addon chọn theo nhãn: mọi cụm; `provider=onprem` (longhorn, metallb, vault, ingress-nginx, cnpg, barman, redis-operator,
minio); `provider=aws` (aws-load-balancer-controller); `env∈{dev,staging}` (chaos-mesh); `env≠dev` (opensearch).

### Version addon đã pin (`argocd/apps/platform-addons.yaml`)

| Addon | Chart | Version |
|---|---|---|
| cert-manager | jetstack/cert-manager | v1.21.3 |
| external-secrets | external-secrets/external-secrets | 2.14.0 |
| kyverno | kyverno/kyverno | 3.9.2 |
| argo-rollouts | argo/argo-rollouts | 2.43.10 |
| keda | kedacore/keda | 2.21.0 |
| kube-prometheus-stack | prometheus-community | 93.0.0 |
| loki | grafana/loki | 7.5.0 |
| tempo | grafana-community/tempo | 3.2.1 |
| otel-collector / otel-agent | opentelemetry-collector | 0.178.2 |
| strimzi-kafka-operator | strimzi | 1.3.1 |
| cloudnative-pg / plugin-barman-cloud | cnpg | 0.29.1 / 0.8.1 |
| redis-operator | ot-container-kit | 0.27.0 |
| mongodb community-operator | mongodb | 0.13.0 |
| opensearch | opensearch-project | 3.9.0 |
| minio operator / tenant | minio-operator | 7.1.1 / 7.1.1 |
| longhorn / metallb | longhorn / metallb | 1.13.0 / 0.16.2 |
| vault | hashicorp/vault | 0.34.1 |
| aws-load-balancer-controller | aws/eks-charts | 3.6.2 |
| chaos-mesh | chaos-mesh | 2.8.8 |
| sloth | slok/sloth | 0.16.0 |
| (hub) argo-cd | argo/argo-cd | 10.15.0 |

Muốn nâng version thì sửa một dòng trong `platform-addons.yaml` qua PR, chạy thử trên dev/staging (nhãn env) rồi mới tới prod.

## Quy trình phát hành & promote

1. **CI (shop-microservice)**: build image `…/shopnow/<svc>:sha-<commit>`, ký Cosign keyless, rồi mở PR vào repo này:
   `yq -i '.images["order"] = {"tag":"sha-abc1234","digest":"sha256:…"}' environments/dev/images.yaml`.
2. **validate.yml** chạy trên PR: yamllint → helm lint → helm template (4 env × 17 service) → kustomize → kubeconform → kyverno test.
3. Merge xong, Argo CD sync `dev-<svc>`. Service có `rollout.enabled` (api-gateway, catalog, order, payment) chạy canary
   10% → 30% → 60% → 100%, có pause giữa các bước. AnalysisTemplate đo **5xx ratio** và **p95** của riêng pod canary
   (`rollouts_pod_template_hash`). Quá ngưỡng thì Rollout tự abort và quay về bản stable.
4. **Promote** bằng PR, không push thẳng lên main:
   ```bash
   git switch -c promote/staging-$(date +%Y%m%d)
   scripts/promote.sh dev staging                 # hoặc liệt kê service: scripts/promote.sh dev staging order payment
   git commit -am "chore(promote): dev → staging" && gh pr create
   ```
   Thứ tự: dev → staging → prod-onprem → prod-aws, hoặc cả hai prod trong cùng một PR. Thư mục `environments/prod-*` nằm trong CODEOWNERS,
   nên PR prod bắt buộc platform team duyệt.

## Bootstrap

```bash
# 1. Cụm hub (on-prem): Argo CD + External Secrets (để đọc token cụm từ Vault hub)
helm upgrade --install argocd argo-cd --repo https://argoproj.github.io/argo-helm --version 10.15.0 \
  -n argocd --create-namespace -f argocd/bootstrap/argocd-values.yaml
helm upgrade --install external-secrets external-secrets --repo https://charts.external-secrets.io \
  --version 2.14.0 -n external-secrets --create-namespace --set installCRDs=true
#    + ClusterSecretStore "vault-hub" trỏ tới Vault của hub; repo credentials (GitHub App) cho Argo CD

# 2. Root app-of-apps: từ đây mọi thứ đi qua git
kubectl apply -f argocd/bootstrap/root-app.yaml
```

**Đăng ký cụm (hub-spoke)**. Mỗi cụm là một Secret `argocd.argoproj.io/secret-type: cluster` mang nhãn
`shopnow.io/env` và `shopnow.io/provider`. ApplicationSet chọn cụm theo hai nhãn này.
- **On-prem** (`argocd/apps/clusters/onprem-clusters.yaml`): trên mỗi cụm tạo SA `argocd-manager` (ClusterRole cần thiết) và một token.
  Cất `server`, `caData`, `bearerToken` vào Vault hub tại `argocd/clusters/<name>`. ExternalSecret sẽ sinh Secret cụm, không có token nào trong git.
- **EKS** (`argocd/apps/clusters/eks-cluster.yaml`): dùng `awsAuthConfig` (clusterName + roleARN). Pod Argo CD trên hub lấy
  credential AWS qua **IAM Roles Anywhere**. Role `argocd-hub-deployer` được map vào cụm bằng **EKS Access Entry**.
  Để hub thấy API EKS, dùng private endpoint qua Site-to-Site VPN/Direct Connect, hoặc public endpoint giới hạn CIDR egress của DC.
  Hub cũng cần đường mạng tới API server của các cụm on-prem.

Khi mở cụm mới, chỉ cần thêm Secret cụm có nhãn đúng: addon, platform-config và 17 app sẽ tự sinh.

**Bí mật (Vault KV v2 mount theo env / AWS Secrets Manager, cùng tên khoá):**

| Khoá | Thuộc tính |
|---|---|
| `shopnow/shared` | `INTERNAL_TOKEN`, `redis_password`, `s3_access_key`, `s3_secret_key` (on-prem) |
| `shopnow/<service>` | `db_username` (= tên role/DB, vd `orders`), `db_password`, `mongo_username`, `mongo_password`, các khoá riêng (vd `JWT_PRIVATE_KEY`, `VNPAY_HASH_SECRET`, `AIOPS_WEBHOOK_TOKEN`) |
| `shopnow/alerting`, `shopnow/grafana`, `shopnow/minio`, `shopnow/loki`, `shopnow/pg-backup`, `shopnow/harbor-robot`, `shopnow/opensearch`, `shopnow/cloudflare`, `shopnow/longhorn-backup` | bí mật của nền tảng |

Thứ tự sync được đảm bảo bằng sync-wave và retry. Root dựng AppProject (-20), rồi `platform-addons` (wave âm theo phụ thuộc:
storage → vault → CRD/operator → quan sát), rồi `platform-config` (namespace, SecretStore, Kafka/CNPG/…, dùng
`SkipDryRunOnMissingResource`), cuối cùng `shopnow-apps` (aiops 0 → identity 1 → domain 2 → order 3 → gateway 4 → web 5).

## Rollback

- **Chuẩn GitOps**: `git revert <commit bump tag>`, mở PR rồi merge. Argo CD sẽ đưa cụm về đúng trạng thái trong git.
  Đây là cách duy nhất làm git và cụm không lệch nhau.
- **Đang canary**: bản lỗi sẽ tự abort nhờ AnalysisTemplate. Muốn chủ động thì chạy
  `kubectl argo rollouts abort <svc> -n shopnow` (traffic về stable ngay), sau đó vẫn revert PR. Nếu không revert, lần sync sau
  Argo CD sẽ thử lại bản lỗi.
- **Khẩn cấp**: rollback trên giao diện Argo CD (History → Rollback) sẽ tắt auto-sync của app đó. Revert git xong thì bật lại.
- **Dữ liệu**: CNPG restore PITR từ ObjectStore (`platform/postgres/backup.yaml`). Trên AWS dùng RDS snapshot hoặc PITR.

## Quan sát, SLO, AIOps, chaos

- App gửi OTLP HTTP tới `otel-collector.observability.svc:4318`. Trace đi Tempo, kèm connector spanmetrics + servicegraph
  ghi vào Prometheus (`source=otel`). Tempo metrics-generator (`service-graphs`, `span-metrics`) cũng bật. Log stdout được otel-agent
  (DaemonSet) gom về Loki, có `trace_id` để nhảy qua lại với Tempo.
- Alertmanager: alert `severity=critical|warning` được gửi tới **AIOps** (`http://aiops.shopnow.svc:8120/webhooks/alertmanager`,
  có cả resolved, Bearer token) và **Telegram**. SLO viết bằng Sloth (gateway availability 99.5% / 30 ngày, checkout p95 < 1.5s,
  saga đặt hàng 99%). Sloth sinh cảnh báo burn-rate: page → critical, ticket → warning.
- Dashboard: RED theo service, saga checkout, Kafka DLQ & outbox, AIOps (anomaly score, incident, MTTD/MTTR, độ chính xác RCA).
- Chaos: `platform/chaos/experiments/` chạy tay hoặc từ aiops/eval (không auto-sync). `schedules/` chỉ chạy trên staging.
  Mỗi thí nghiệm có annotation `aiops.shopnow.io/expected-root-cause` để chấm RCA.

## Kiểm tra cục bộ

```bash
make validate                 # yamllint, json, helm lint, helm template, kustomize, kubeconform, kyverno test
make template && ls .out/apps # manifest đã render theo env/service
make kubeconform KC_IGNORE=   # bắt buộc mọi CRD phải có schema (sẽ báo Chaos Mesh Schedule thiếu)
```

Trước khi chạy thật, thay các giá trị `REPLACE-ME` và `111122223333`: ARN ACM/IAM, endpoint RDS/ElastiCache, vpcId, CA của EKS,
dải MetalLB, chat id Telegram.
