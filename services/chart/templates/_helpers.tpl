{{- define "candle-service.labels" -}}
app.kubernetes.io/name: {{ .Values.name }}
app.kubernetes.io/part-of: candle
app.kubernetes.io/managed-by: argocd
{{- end -}}

{{- define "candle-service.selector" -}}
app: {{ .Values.name }}
{{- end -}}
