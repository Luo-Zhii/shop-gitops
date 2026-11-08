# Kiểm tra cục bộ & CI. Ghi đè đường dẫn công cụ: make validate BIN=/path/to/bin/
BIN ?=
HELM ?= $(BIN)helm
KUBECONFORM ?= $(BIN)kubeconform
KYVERNO ?= $(BIN)kyverno
KUSTOMIZE ?= kubectl kustomize
YAMLLINT ?= yamllint

CHART := charts/shopnow-service
ENVS := dev staging prod-onprem prod-aws
SERVICES := $(basename $(notdir $(wildcard apps/shopnow/services/*.yaml)))
OUT := .out
K8S_VERSION ?= 1.33.0
CRD_SCHEMA := https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json
KC_FLAGS := -strict -summary -kubernetes-version $(K8S_VERSION) -schema-location default -schema-location '$(CRD_SCHEMA)'
# CRD không có trong CRDs-catalog bị bỏ qua (đếm ở dòng "skipped" của summary)
KC_IGNORE ?= -ignore-missing-schemas

.PHONY: validate lint yamllint helm-lint template kustomize kubeconform kyverno-test json clean

validate: lint json template kustomize kubeconform kyverno-test

lint: yamllint helm-lint

yamllint:
	$(YAMLLINT) -s .

json:
	@for f in $$(find platform charts -name '*.json'); do python3 -m json.tool $$f >/dev/null || { echo "JSON lỗi: $$f"; exit 1; }; done; echo "JSON OK"

helm-lint:
	$(HELM) lint $(CHART) --strict -f $(CHART)/ci/default-values.yaml
	$(HELM) lint $(CHART) --strict -f $(CHART)/ci/rollout-keda-values.yaml
	@for env in $(ENVS); do for svc in $(SERVICES); do \
	  $(HELM) lint $(CHART) --strict --quiet $$(./scripts/values-args.sh $$env $$svc) >/dev/null || { echo "LINT FAIL $$env/$$svc"; exit 1; }; \
	done; done; echo "helm lint OK: $(words $(ENVS)) env x $(words $(SERVICES)) service"

template:
	@mkdir -p $(OUT)/apps
	@for env in $(ENVS); do mkdir -p $(OUT)/apps/$$env; for svc in $(SERVICES); do \
	  $(HELM) template $$svc $(CHART) -n shopnow $$(./scripts/values-args.sh $$env $$svc) > $(OUT)/apps/$$env/$$svc.yaml || { echo "TEMPLATE FAIL $$env/$$svc"; exit 1; }; \
	done; done; echo "helm template OK -> $(OUT)/apps"

kustomize:
	@mkdir -p $(OUT)/platform
	@for env in $(ENVS); do $(KUSTOMIZE) environments/$$env/platform > $(OUT)/platform/$$env.yaml || { echo "KUSTOMIZE FAIL $$env"; exit 1; }; done
	@echo "kustomize build OK -> $(OUT)/platform"

kubeconform: template kustomize
	$(KUBECONFORM) $(KC_FLAGS) $(KC_IGNORE) $(OUT)/apps $(OUT)/platform
	$(KUBECONFORM) $(KC_FLAGS) $(KC_IGNORE) -ignore-filename-pattern 'values\.yaml$$' argocd

kyverno-test:
	$(KYVERNO) test platform/kyverno/tests --remove-color

clean:
	rm -r -f ./$(OUT)
