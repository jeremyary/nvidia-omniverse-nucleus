{{- define "nucleus.fullname" -}}
nucleus
{{- end -}}

{{/*
Standard Kubernetes recommended labels
https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/
*/}}
{{- define "nucleus.labels" -}}
app.kubernetes.io/part-of: omniverse-nucleus
app.kubernetes.io/managed-by: helm
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/*
Selector labels - subset of labels safe for matchLabels (immutable after creation)
*/}}
{{- define "nucleus.selectorLabels" -}}
app.kubernetes.io/part-of: omniverse-nucleus
{{- end -}}

{{- define "nucleus.image" -}}
{{ .root.Values.registry }}/{{ .image }}
{{- end -}}
