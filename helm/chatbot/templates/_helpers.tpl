{{- define "chatbot.labels" -}}
app.kubernetes.io/part-of: chatbot
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
chatbot.io/env: {{ .Values.env }}
{{- end }}

{{- define "chatbot.podSecurityContext" -}}
runAsNonRoot: true
seccompProfile:
  type: RuntimeDefault
appArmorProfile:          # loaded on the node by scripts/01a-apparmor.sh
  type: Localhost
  localhostProfile: k8s-chatbot
{{- end }}

{{- define "chatbot.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: [ALL]
{{- end }}
