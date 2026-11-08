#!/bin/bash
# =============================================================================
# setup-gitlab-repo.sh — Cấu hình ArgoCD kết nối đến GitLab self-hosted
# =============================================================================
# Usage:
#   export GITLAB_USERNAME="root"
#   export GITLAB_TOKEN="glpat-xxxxxxxxxxxx"
#   ./setup-gitlab-repo.sh
#
# Hoặc truyền trực tiếp:
#   GITLAB_USERNAME=root GITLAB_TOKEN=glpat-xxx ./setup-gitlab-repo.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARGOCD_NAMESPACE="argocd"
GITLAB_URL="${GITLAB_URL:-http://gitlab.luo.io.vn}"
GITLAB_REPO="${GITLAB_REPO:-root/shopnow-gitops}"
GITLAB_USERNAME="${GITLAB_USERNAME:-}"
GITLAB_TOKEN="${GITLAB_TOKEN:-}"

if [ -z "$GITLAB_USERNAME" ] || [ -z "$GITLAB_TOKEN" ]; then
  echo "ERROR: GITLAB_USERNAME and GITLAB_TOKEN must be set."
  echo ""
  echo "Usage:"
  echo "  GITLAB_USERNAME=root GITLAB_TOKEN=glpat-xxx $0"
  echo ""
  echo "How to create a GitLab Personal Access Token:"
  echo "  1. Login to GitLab: ${GITLAB_URL}"
  echo "  2. Go to Settings → Access Tokens"
  echo "  3. Create token with scopes: read_repository, api"
  echo "  4. Copy the token and set GITLAB_TOKEN"
  exit 1
fi

echo "============================================"
echo " Setting up ArgoCD → GitLab Connection"
echo "============================================"

# Step 1: Tạo Kubernetes Secret cho GitLab credentials
echo ""
echo "[1/4] Creating GitLab repo credentials secret..."
kubectl create secret generic gitlab-repo-creds \
  -n ${ARGOCD_NAMESPACE} \
  --from-literal=username="${GITLAB_USERNAME}" \
  --from-literal=password="${GITLAB_TOKEN}" \
  --from-literal=url="${GITLAB_URL}/${GITLAB_REPO}.git" \
  --dry-run=client -o yaml | kubectl apply -f -

# Step 2: Đăng ký GitLab repository với ArgoCD
echo ""
echo "[2/4] Registering GitLab repository with ArgoCD..."
REPO_URL="${GITLAB_URL}/${GITLAB_REPO}.git"

# Dùng argocd CLI nếu có, nếu không thì tạo Secret thủ công
if command -v argocd &> /dev/null; then
  echo "   Using argocd CLI..."
  argocd repo add "${REPO_URL}" \
    --username "${GITLAB_USERNAME}" \
    --password "${GITLAB_TOKEN}" \
    --insecure-skip-server-verification \
    || echo "   ⚠️  Repo may already be registered, continuing..."
else
  echo "   argocd CLI not found. Creating repo secret manually..."
  # Tạo Secret cho ArgoCD repository
  kubectl apply -n ${ARGOCD_NAMESPACE} -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-${GITLAB_REPO//\//-}
  namespace: ${ARGOCD_NAMESPACE}
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: ${REPO_URL}
  username: ${GITLAB_USERNAME}
  password: ${GITLAB_TOKEN}
EOF
fi

# Step 3: Create ArgoCD Application
echo ""
echo "[3/4] Creating ArgoCD Application (ShopNow)..."
kubectl apply -f "${SCRIPT_DIR}/argocd-application.yaml"

# Step 4: Verify
echo ""
echo "[4/4] Verifying ArgoCD Application status..."
sleep 5
kubectl get application -n ${ARGOCD_NAMESPACE}
echo ""
echo "============================================"
echo " Setup Complete!"
echo "============================================"
echo ""
echo "ArgoCD will now auto-sync K8s manifests from:"
echo "  Repo:     ${REPO_URL}"
echo "  Branch:   main"
echo "  Path:     Shopnow_k8s/k8s-manifests"
echo "  Target:   K8s cluster → namespace: shopnow"
echo ""
echo "Check sync status:"
echo "  kubectl get application -n argocd shopnow"
echo ""
echo "Access ArgoCD UI:"
echo "  https://argocd.luo.io.vn  (via Nginx)"
echo "  https://<worker-ip>:30082  (NodePort)"
echo "============================================"
