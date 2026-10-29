{{/*
Common labels
*/}}
{{- define "mssql.labels" -}}
app: {{ .Chart.Name }}
version: {{ .Values.mssql.tag | quote }}
chart: {{ .Chart.Name }}-{{ .Chart.Version }}
release: {{ .Release.Name }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "mssql.selectorLabels" -}}
app: {{ .Chart.Name }}
release: {{ .Release.Name }}
{{- end }}

{{/*
Full name
*/}}
{{- define "mssql.fullname" -}}
{{ .Release.Name }}-{{ .Chart.Name }}
{{- end }}
