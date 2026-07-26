# ShopNow GitOps — Kubernetes Manifests

Repo GitOps chứa Kubernetes manifests cho ứng dụng ShopNow.
Được **ArgoCD** watch để auto-deploy lên K8s cluster.

## Cấu trúc

```
shopnow-gitops/
├── base/                      # K8s resources chung (Kustomize base)
│   ├── kustomization.yaml        # Kustomize base definition
│   ├── 01-namespace.yaml         # Namespace "shopnow"
│   ├── 02-secrets.yaml           # Credentials (DB, Keycloak)
│   ├── 03-configmaps.yaml        # Spring Cloud Config
│   ├── 04-glusterfs-storage.yaml # PVs + PVCs (GlusterFS)
│   ├── 05-16-*.yaml              # 12 app components + Ingress
│   └── ...
├── overlays/production/       # Override cho môi trường production
│   └── kustomization.yaml        # Image tags (CI tự cập nhật)
├── argocd/                    # ArgoCD GitOps Controller
│   ├── install-argocd.sh         # Cài ArgoCD lên K8s
│   ├── setup-gitlab-repo.sh      # Kết nối ArgoCD → GitLab
│   ├── argocd-application.yaml   # Application CRDs
│   └── argocd-ingress.yaml       # Ingress route cho UI
├── monitoring/                # Prometheus + Grafana + AlertManager
│   ├── install-monitoring.sh     # Cài đặt kube-prometheus-stack
│   ├── servicemonitor-shopnow.yaml # ServiceMonitors cho Spring Boot
│   ├── grafana-dashboards.yaml   # Custom dashboards
│   └── monitoring-ingress.yaml   # Ingress routes
└── deploy.sh                  # Script deploy thủ công (tham khảo)
```

## Luồng GitOps

```
shopnow-app CI/CD                     shopnow-gitops
┌───────────────────┐                ┌──────────────────────┐
│ Build images      │                │ overlays/production/ │
│ Push Harbor       │   git clone    │   kustomization.yaml │
│                   │─── sed replace─▶│   newTag: "abc123"   │
│ CI job cuối       │   git push     │                      │
└───────────────────┘                └─────────┬────────────┘
                                               │
                                        ┌──────▼──────┐
                                        │   ArgoCD    │  watch repo
                                        │  auto sync  │  mỗi 3 phút
                                        └──────┬──────┘
                                               │ kubectl apply
                                        ┌──────▼──────┐
                                        │  Kubernetes │
                                        │   Cluster   │
                                        └─────────────┘
```

## Cài đặt

```bash
# 1. Cài ArgoCD
cd argocd && ./install-argocd.sh

# 2. Kết nối GitLab repo (chạy 1 lần)
GITLAB_USERNAME=root GITLAB_TOKEN=glpat-xxx ./setup-gitlab-repo.sh

# 3. Cài Prometheus + Grafana (không dùng Helm tự động)
cd ../monitoring && ./install-monitoring.sh

# --- Từ đây trở đi, ArgoCD tự động sync ---
# Mỗi khi CI/CD cập nhật image tag trong overlays/production/kustomization.yaml
# ArgoCD sẽ detect và auto-deploy lên K8s

# Deploy thủ công nếu cần (không cần khi dùng ArgoCD):
# cd base && kubectl apply -k ../overlays/production
```
