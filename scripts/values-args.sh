#!/usr/bin/env bash
# In ra cờ -f theo đúng thứ tự Argo CD dùng (argocd/apps/shopnow-apps.yaml). Dùng: values-args.sh <env> <svc>
set -euo pipefail
env="$1"; svc="$2"
files=(
  apps/shopnow/values-common.yaml
  "apps/shopnow/services/${svc}.yaml"
  "environments/${env}/values.yaml"
  "environments/${env}/services/${svc}.yaml"
  "environments/${env}/images.yaml"
)
for f in "${files[@]}"; do [[ -f "$f" ]] && printf -- '-f %s ' "$f"; done
exit 0
