{{/* Standard name/label helpers, same shape Helm's own chart scaffold generates. */}}

{{- define "conduit-backend.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "conduit-backend.fullname" -}}
{{- .Release.Name -}}
{{- end -}}

{{- define "conduit-backend.labels" -}}
app.kubernetes.io/name: {{ include "conduit-backend.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "conduit-backend.selectorLabels" -}}
app.kubernetes.io/name: {{ include "conduit-backend.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "conduit-backend.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{ .Values.serviceAccount.name | default (include "conduit-backend.fullname" .) }}
{{- else -}}
{{ .Values.serviceAccount.name | default "default" }}
{{- end -}}
{{- end -}}
