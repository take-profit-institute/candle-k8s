{{- define "candle-batch.labels" -}}
app.kubernetes.io/name: {{ .Values.name }}
app.kubernetes.io/part-of: candle
app.kubernetes.io/component: batch
app.kubernetes.io/managed-by: argocd
{{- end -}}
