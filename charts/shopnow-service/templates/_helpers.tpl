{{- define "svc.name" -}}
{{- required "values.name là bắt buộc (tên service)" .Values.name | trunc 50 | trimSuffix "-" -}}
{{- end -}}

{{- define "svc.selectorLabels" -}}
app.kubernetes.io/name: {{ include "svc.name" . }}
app.kubernetes.io/instance: {{ include "svc.name" . }}
{{- end -}}

{{- define "svc.labels" -}}
{{ include "svc.selectorLabels" . }}
app.kubernetes.io/component: {{ .Values.component }}
app.kubernetes.io/part-of: {{ .Values.global.partOf }}
app.kubernetes.io/version: {{ include "svc.imageTag" . | trunc 63 | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
shopnow.io/env: {{ .Values.global.env }}
shopnow.io/provider: {{ .Values.global.provider }}
{{- end -}}

{{- define "svc.imageEntry" -}}
{{- $e := dict -}}
{{- if hasKey .Values.images .Values.name -}}{{- $e = index .Values.images .Values.name -}}{{- end -}}
{{- toJson $e -}}
{{- end -}}

{{- define "svc.imageTag" -}}
{{- $e := include "svc.imageEntry" . | fromJson -}}
{{- $tag := default .Values.image.tag $e.tag -}}
{{- required (printf "chưa có tag image cho %s (environments/<env>/images.yaml)" .Values.name) $tag -}}
{{- end -}}

{{- define "svc.image" -}}
{{- $e := include "svc.imageEntry" . | fromJson -}}
{{- $repo := default (printf "shopnow/%s" .Values.name) .Values.image.repository -}}
{{- $tag := include "svc.imageTag" . -}}
{{- if eq $tag "latest" -}}{{- fail "cấm tag latest — dùng tag bất biến (sha-<commit> / semver)" -}}{{- end -}}
{{- $digest := default .Values.image.digest $e.digest -}}
{{- if $digest -}}
{{- printf "%s/%s:%s@%s" .Values.image.registry $repo $tag $digest -}}
{{- else -}}
{{- printf "%s/%s:%s" .Values.image.registry $repo $tag -}}
{{- end -}}
{{- end -}}

{{- define "svc.workloadApiVersion" -}}
{{- if .Values.rollout.enabled }}argoproj.io/v1alpha1{{ else }}apps/v1{{ end -}}
{{- end -}}

{{- define "svc.workloadKind" -}}
{{- if .Values.rollout.enabled }}Rollout{{ else }}Deployment{{ end -}}
{{- end -}}

{{- define "svc.host" -}}
{{- printf "%s.%s" (required "ingress.hostPrefix" .Values.ingress.hostPrefix) .Values.global.domain -}}
{{- end -}}

{{/* Một peer NetworkPolicy theo dataServices.<x>: namespace và/hoặc cidrs */}}
{{- define "svc.npPeers" -}}
{{- if .namespace }}
- namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: {{ .namespace }}
{{- end }}
{{- range .cidrs }}
- ipBlock:
    cidr: {{ . }}
{{- end }}
{{- end -}}
