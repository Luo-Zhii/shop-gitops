#!/bin/bash
# =============================================================================
# install-argocd.sh — Cài đặt ArgoCD lên Kubernetes Cluster
# =============================================================================
# Usage:
#   chmod +x install-argocd.sh
#   ./install-argocd.sh
#
# Yêu cầu:
#   - kubectl đã được cấu hình trỏ đến K8s cluster
#   - GitLab self-hosted đã có repository DevOps_Scripts
#   - GitLab personal access token đã được tạo (nếu dùng HTTPS)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARGOCD_NAMESPACE="argocd"
ARGOCD_VERSION="v2.12.0"

echo "============================================"
echo " Installing ArgoCD on Kubernetes"
echo "============================================"

# Step 1: Tạo namespace argocd
echo ""
echo "[1/6] Creating argocd namespace..."
kubectl create namespace ${ARGOCD_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# Step 2: Cài đặt ArgoCD từ official manifests
echo ""
echo "[2/6] Installing ArgoCD ${ARGOCD_VERSION}..."
kubectl apply -n ${ARGOCD_NAMESPACE} -f https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml

# Step 3: Đợi tất cả ArgoCD pods sẵn sàng
echo ""
echo "[3/6] Waiting for ArgoCD pods to be ready..."
kubectl wait --for=condition=Ready pods --all -n ${ARGOCD_NAMESPACE} --timeout=300s

# Step 4: Expose ArgoCD Server qua NodePort (để truy cập UI)
echo ""
echo "[4/6] Patching ArgoCD server to NodePort..."
kubectl patch svc argocd-server -n ${ARGOCD_NAMESPACE} \
  -p '{"spec": {"type": "NodePort", "ports": [{"port": 80, "targetPort": 8080, "nodePort": 30081}, {"port": 443, "targetPort": 8080, "nodePort": 30082}]}}' \
  || echo "NodePort already configured, skipping..."

# Step 5: Lấy initial admin password
echo ""
echo "[5/6] Retrieving initial admin password..."
ARGO_PASSWORD=$(kubectl -n ${ARGOCD_NAMESPACE} get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "")

if [ -z "$ARGO_PASSWORD" ]; then
  echo "⚠️  Could not retrieve initial password. The secret may have been rotated."
  echo "   Reset password with: argocd account update-password"
else
  echo "   Initial admin password: ${ARGO_PASSWORD}"
fi

# Step 6: Hiển thị trạng thái
echo ""
echo "[6/6] ArgoCD Installation Status:"
echo "============================================"
kubectl get pods -n ${ARGOCD_NAMESPACE}
echo ""
kubectl get svc -n ${ARGOCD_NAMESPACE}
echo ""
echo "ArgoCD URLs:"
echo "  UI (NodePort):    https://<any-worker-ip>:30082"
echo "  UI (via Nginx):   https://argocd.luo.io.vn"
echo "  API:              https://<any-worker-ip>:30082"
echo "  Username:         admin"
echo "  Password:         ${ARGO_PASSWORD:-see above}"
echo ""
echo "Next steps:"
echo "  1. Add GitLab repo to ArgoCD:"
echo "     argocd repo add http://gitlab.luo.io.vn/root/DevOps_Scripts.git \\"
echo "       --username <gitlab-username> --password <gitlab-token>"
echo ""
echo "  2. Create ArgoCD Application:"
echo "     kubectl apply -f ${SCRIPT_DIR}/argocd-application.yaml"
echo ""
echo "  3. Or use the auto-setup script:"
echo "     ./setup-gitlab-repo.sh"
echo "============================================"
