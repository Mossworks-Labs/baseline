{{/*
Chart fullname — uses release-chart pattern for subchart compatibility.
Standalone: "baseline". As subchart of craft: "craft-baseline".
*/}}
{{- define "baseline.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "baseline.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: {{ include "baseline.fullname" . }}
{{- end }}

{{/*
Annotation block to drop on any ingress whose hostname is routed via the
Cloudflare tunnel (i.e. listed in cloudflareTunnel.ingress). Without it,
external-dns sees the ingress's loadBalancer ClusterIP and writes an A
record to the unreachable internal address — overriding the proxied
CNAME the tunnel-dns Job created.

Usage in a sibling chart's ingress.yaml:

  metadata:
    annotations:
      {{- include "baseline.tunnelIngressAnnotations" . | nindent 4 }}

(Or paste verbatim if the chart isn't a baseline subchart and can't
include this helper.)
*/}}
{{- define "baseline.tunnelIngressAnnotations" -}}
external-dns.alpha.kubernetes.io/exclude: "true"
{{- end }}
