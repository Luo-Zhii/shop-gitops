{{- define "svc.podTemplate" -}}
metadata:
  labels:
    {{- include "svc.labels" . | nindent 4 }}
    {{- with .Values.podLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  annotations:
    checksum/env: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
    {{- with .Values.podAnnotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  serviceAccountName: {{ include "svc.name" . }}
  automountServiceAccountToken: {{ .Values.serviceAccount.automountToken }}
  enableServiceLinks: false
  terminationGracePeriodSeconds: {{ .Values.terminationGracePeriodSeconds }}
  {{- with .Values.priorityClassName }}
  priorityClassName: {{ . }}
  {{- end }}
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  securityContext:
    {{- toYaml .Values.podSecurityContext | nindent 4 }}
  {{- if .Values.topologySpread.enabled }}
  topologySpreadConstraints:
    - maxSkew: {{ .Values.topologySpread.maxSkew }}
      topologyKey: topology.kubernetes.io/zone
      whenUnsatisfiable: ScheduleAnyway
      labelSelector:
        matchLabels:
          {{- include "svc.selectorLabels" . | nindent 10 }}
      matchLabelKeys: [{{ ternary "rollouts-pod-template-hash" "pod-template-hash" .Values.rollout.enabled }}]
    - maxSkew: {{ .Values.topologySpread.maxSkew }}
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: ScheduleAnyway
      labelSelector:
        matchLabels:
          {{- include "svc.selectorLabels" . | nindent 10 }}
      matchLabelKeys: [{{ ternary "rollouts-pod-template-hash" "pod-template-hash" .Values.rollout.enabled }}]
  {{- end }}
  {{- with .Values.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.affinity }}
  affinity:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  containers:
    - name: {{ include "svc.name" . }}
      image: {{ include "svc.image" . }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      ports:
        - name: http
          containerPort: {{ .Values.port }}
          protocol: TCP
      envFrom:
        - configMapRef:
            name: {{ include "svc.name" . }}-env
        {{- if .Values.externalSecret.enabled }}
        - secretRef:
            name: {{ include "svc.name" . }}-secrets
        {{- end }}
      env:
        - name: K8S_POD_NAME
          valueFrom: {fieldRef: {fieldPath: metadata.name}}
        - name: K8S_NAMESPACE
          valueFrom: {fieldRef: {fieldPath: metadata.namespace}}
        - name: K8S_NODE_NAME
          valueFrom: {fieldRef: {fieldPath: spec.nodeName}}
        {{- with .Values.extraEnv }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      startupProbe:
        httpGet: {path: {{ .Values.probes.startup.path }}, port: http}
        periodSeconds: {{ .Values.probes.startup.periodSeconds }}
        timeoutSeconds: {{ .Values.probes.startup.timeoutSeconds }}
        failureThreshold: {{ .Values.probes.startup.failureThreshold }}
      livenessProbe:
        httpGet: {path: {{ .Values.probes.liveness.path }}, port: http}
        initialDelaySeconds: {{ .Values.probes.liveness.initialDelaySeconds }}
        periodSeconds: {{ .Values.probes.liveness.periodSeconds }}
        timeoutSeconds: {{ .Values.probes.liveness.timeoutSeconds }}
        failureThreshold: {{ .Values.probes.liveness.failureThreshold }}
      readinessProbe:
        httpGet: {path: {{ .Values.probes.readiness.path }}, port: http}
        periodSeconds: {{ .Values.probes.readiness.periodSeconds }}
        timeoutSeconds: {{ .Values.probes.readiness.timeoutSeconds }}
        failureThreshold: {{ .Values.probes.readiness.failureThreshold }}
      {{- if gt (int .Values.preStopSleepSeconds) 0 }}
      lifecycle:
        preStop:
          sleep: {seconds: {{ .Values.preStopSleepSeconds }}}
      {{- end }}
      resources:
        {{- toYaml .Values.resources | nindent 8 }}
      securityContext:
        {{- toYaml .Values.securityContext | nindent 8 }}
      volumeMounts:
        - name: tmp
          mountPath: /tmp
        {{- range .Values.extraWritableDirs }}
        - name: {{ .name }}
          mountPath: {{ .mountPath }}
        {{- end }}
  volumes:
    - name: tmp
      emptyDir:
        sizeLimit: {{ .Values.tmpDir.sizeLimit }}
    {{- range .Values.extraWritableDirs }}
    - name: {{ .name }}
      emptyDir:
        sizeLimit: {{ .sizeLimit | default "256Mi" }}
    {{- end }}
{{- end -}}
