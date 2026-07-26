#!/bin/bash
# =============================================================================
# install-monitoring.sh — Cài đặt Prometheus + Grafana + AlertManager lên K8s
# =============================================================================
# Sử dụng kube-prometheus-stack (Prometheus Operator) — cách chuẩn cloud-native.
# Thay thế ELK Stack bằng monitoring stack hiện đại:
#   - Prometheus: Thu thập metrics (thay Logstash/Elasticsearch)
#   - Grafana:    Dashboard visualization (thay Kibana)
#   - AlertManager: Cảnh báo qua Email/Slack/Telegram
#
# Usage:
#   chmod +x install-monitoring.sh
#   ./install-monitoring.sh
#
# Yêu cầu:
#   - kubectl đã được cấu hình
#   - Helm 3 đã được cài đặt
#   - StorageClass (GlusterFS) đã sẵn sàng cho PersistentVolumes
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MONITORING_NAMESPACE="monitoring"
HELM_RELEASE="kube-prometheus-stack"
HELM_REPO="prometheus-community"
HELM_CHART="kube-prometheus-stack"
HELM_VERSION="${HELM_VERSION:-61.0.0}"

echo "============================================"
echo " Installing Prometheus + Grafana Stack"
echo "============================================"

# Step 1: Tạo namespace monitoring
echo ""
echo "[1/8] Creating monitoring namespace..."
kubectl create namespace ${MONITORING_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# Step 2: Thêm Prometheus Community Helm repo
echo ""
echo "[2/8] Adding Prometheus Community Helm repo..."
helm repo add ${HELM_REPO} https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update

# Step 3: Tạo values file tùy chỉnh nếu chưa có
if [ ! -f "${SCRIPT_DIR}/monitoring-values.yaml" ]; then
  echo "[3/8] Generating default monitoring-values.yaml..."
  cat > "${SCRIPT_DIR}/monitoring-values.yaml" <<'EOF'
# ===== Prometheus =====
prometheus:
  prometheusSpec:
    # Giữ metrics 15 ngày
    retention: 15d
    retentionSize: 20GB
    # Scrape interval
    scrapeInterval: 30s
    evaluationInterval: 30s
    # ServiceMonitor selector (tự động discover ShopNow metrics)
    serviceMonitorSelectorNilUsesHelmValues: false
    serviceMonitorSelector: {}
    serviceMonitorNamespaceSelector: {}
    # Persistent storage (qua GlusterFS default StorageClass)
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 20Gi
    resources:
      requests:
        cpu: 500m
        memory: 2Gi
      limits:
        cpu: 2000m
        memory: 4Gi

# ===== AlertManager =====
alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 5Gi
  config:
    global:
      resolve_timeout: 5m
    route:
      group_by: ['alertname', 'namespace']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h
      receiver: 'null'
      routes:
        - match:
            severity: critical
          receiver: 'null'
          continue: true
    receivers:
      - name: 'null'
    # Cấu hình thêm Email/Slack receiver sau:
    # receivers:
    #   - name: 'slack-alerts'
    #     slack_configs:
    #       - api_url: 'https://hooks.slack.com/services/...'
    #         channel: '#alerts'
    #         title: '[{{ .Status | toUpper }}] {{ .GroupLabels.alertname }}'
    #         text: '{{ .CommonAnnotations.description }}'

# ===== Grafana =====
grafana:
  enabled: true
  adminPassword: "admin"  # ĐỔI NGAY SAU KHI CÀI ĐẶT!
  # Ingress configuration (dùng domain grafana.luo.io.vn)
  ingress:
    enabled: false  # Dùng custom Ingress riêng (xem monitoring-ingress.yaml)
  # Persistent storage cho dashboards & data
  persistence:
    enabled: true
    size: 10Gi
  # Cài đặt sẵn Kubernetes dashboards
  dashboards:
    defaultDashboardName: "Kubernetes Cluster"
  # Sidecar để auto-load dashboards từ ConfigMaps
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
      labelValue: "1"
      searchNamespace: ALL
    datasources:
      enabled: true
      defaultDatasourceEnabled: true
  # Plugins bổ sung
  plugins:
    - grafana-piechart-panel
    - grafana-clock-panel
  resources:
    requests:
      cpu: 200m
      memory: 256Mi
    limits:
      cpu: 1000m
      memory: 512Mi

# ===== kube-state-metrics =====
kube-state-metrics:
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 200m
      memory: 256Mi

# ===== Node Exporter =====
prometheus-node-exporter:
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 128Mi

# ===== Default rules =====
defaultRules:
  create: true
  rules:
    alertmanager: true
    etcd: false
    configReloaders: true
    general: true
    k8s: true
    kubeApiserverAvailability: true
    kubeApiserverBurnrate: true
    kubeApiserverHistogram: true
    kubeApiserverSlos: true
    kubelet: true
    kubeProxy: true
    kubePrometheusGeneral: true
    kubePrometheusNodeRecording: true
    kubernetesApps: true
    kubernetesResources: true
    kubernetesStorage: true
    kubernetesSystem: true
    network: true
    node: true
    nodeExporterAlerting: true
    nodeExporterRecording: true
    prometheus: true
    prometheusOperator: true
EOF
  echo "   Created monitoring-values.yaml with default configuration"
else
  echo "[3/8] Using existing monitoring-values.yaml..."
fi

# Step 4: Cài đặt kube-prometheus-stack qua Helm
echo ""
echo "[4/8] Installing kube-prometheus-stack via Helm..."
helm upgrade --install ${HELM_RELEASE} ${HELM_REPO}/${HELM_CHART} \
  --namespace ${MONITORING_NAMESPACE} \
  --version ${HELM_VERSION} \
  --values "${SCRIPT_DIR}/monitoring-values.yaml" \
  --wait \
  --timeout 10m

# Step 5: Deploy ServiceMonitors cho ShopNow (Spring Boot Actuator metrics)
echo ""
echo "[5/8] Deploying ServiceMonitors for ShopNow microservices..."
kubectl apply -f "${SCRIPT_DIR}/servicemonitor-shopnow.yaml"

# Step 6: Deploy custom Grafana dashboards
echo ""
echo "[6/8] Deploying Grafana dashboards for ShopNow..."
kubectl apply -f "${SCRIPT_DIR}/grafana-dashboards.yaml"

# Step 7: Deploy Ingress cho Grafana
echo ""
echo "[7/8] Deploying Grafana Ingress..."
kubectl apply -f "${SCRIPT_DIR}/monitoring-ingress.yaml"

# Step 8: Hiển thị trạng thái
echo ""
echo "[8/8] Monitoring Stack Status:"
echo "============================================"
kubectl get pods -n ${MONITORING_NAMESPACE}
echo ""
kubectl get svc -n ${MONITORING_NAMESPACE}
echo ""
echo "Access URLs:"
echo "  Grafana:        https://grafana.luo.io.vn   (via Nginx → Ingress)"
echo "  Grafana (NP):   http://<any-worker-ip>:30300 (NodePort)"
echo "  Prometheus:     http://<any-worker-ip>:30301 (NodePort)"
echo "  AlertManager:   http://<any-worker-ip>:30302 (NodePort)"
echo ""
echo "Default Grafana login:"
echo "  Username: admin"
echo "  Password: admin  (CHANGE IMMEDIATELY!)"
echo ""
echo "Get Grafana password:"
echo "  kubectl get secret -n monitoring kube-prometheus-stack-grafana \\"
echo "    -o jsonpath='{.data.admin-password}' | base64 -d"
echo ""
echo "Next steps:"
echo "  1. Login to Grafana and change the default password"
echo "  2. Configure AlertManager receivers (Email/Slack/Telegram)"
echo "  3. Add domain grafana.luo.io.vn to Nginx upstream config"
echo "============================================"
