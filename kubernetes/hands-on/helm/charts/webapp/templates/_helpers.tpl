{{/*
============================================================================
Named templates (helpers) reused across the chart's manifests.
Defined here once, included where needed with `{{ include "name" . }}`.
============================================================================
*/}}

{{/*
Full name used as the prefix for every object created by this chart.
Combines the release name and the chart name so multiple releases of the
same chart coexist without collisions.
*/}}
{{- define "webapp.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Standard Kubernetes labels recommended by the official guidelines.
See https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/
*/}}
{{- define "webapp.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/*
The subset of labels used as selectors. They MUST be immutable once the
Deployment is created, so they exclude version-related labels.
*/}}
{{- define "webapp.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
