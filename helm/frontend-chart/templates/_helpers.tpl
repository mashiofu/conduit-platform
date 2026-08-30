{{/* Standard name/label helpers, same shape Helm's own chart scaffold generates. */}}

{{- define "conduit-frontend.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "conduit-frontend.fullname" -}}
{{- .Release.Name -}}
{{- end -}}

{{- define "conduit-frontend.labels" -}}
app.kubernetes.io/name: {{ include "conduit-frontend.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "conduit-frontend.selectorLabels" -}}
app.kubernetes.io/name: {{ include "conduit-frontend.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "conduit-frontend.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{ .Values.serviceAccount.name | default (include "conduit-frontend.fullname" .) }}
{{- else -}}
{{ .Values.serviceAccount.name | default "default" }}
{{- end -}}
{{- end -}}
