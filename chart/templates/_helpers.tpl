{{/*
Merge defaults with app-specific configuration
Usage: {{ include "bundle.appConfig" (dict "root" . "app" "client-api") }}
*/}}
{{- define "bundle.appConfig" -}}
{{- $root := .root -}}
{{- $app := .app -}}
{{- $appConfig := mergeOverwrite (deepCopy $root.Values.defaults) (index $root.Values $app | default dict) -}}
{{- $appConfig | toYaml -}}
{{- end -}}

{{/*
Get merged app configuration as object
Usage: {{ $appConfig := include "bundle.getAppConfig" (dict "root" . "app" "client-api") | fromYaml }}
*/}}
{{- define "bundle.getAppConfig" -}}
{{- $root := .root -}}
{{- $app := .app -}}
{{- $appConfig := mergeOverwrite (deepCopy $root.Values.defaults) (index $root.Values $app | default dict) -}}
{{- $appConfig | toYaml -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "bundle.labels" -}}
helm.sh/chart: {{ include "bundle.chart" . }}
{{ include "bundle.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "bundle.selectorLabels" -}}
app.kubernetes.io/name: {{ include "bundle.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "bundle.fullname" -}}
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
Create chart name and version as used by the chart label.
*/}}
{{- define "bundle.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Expand the name of the chart.
*/}}
{{- define "bundle.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }} 

{{/*
Transform from values yaml alike properties to key dotchained based ones.
*/}}
{{- define "flattenToDotNotation" -}}
{{- $prefix := index . 0 -}}
{{- $obj := index . 1 -}}
{{- if hasKey $obj $prefix }}
{{- $prefixedObj := index $obj $prefix }}
{{- range $key, $value := $prefixedObj }}
{{- $newKey := printf "%s.%s" $prefix $key }}
{{- if kindIs "map" $value }}
{{- include "flattenToDotNotationRecursive" (list $newKey $value) }}
{{- else }}
{{ $newKey }}: {{ $value | quote }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Recursive helper for flattenToDotNotation
*/}}
{{- define "flattenToDotNotationRecursive" -}}
{{- $prefix := index . 0 -}}
{{- $obj := index . 1 -}}
{{- range $key, $value := $obj }}
{{- $newKey := printf "%s.%s" $prefix $key }}
{{- if kindIs "map" $value }}
{{- include "flattenToDotNotationRecursive" (list $newKey $value) }}
{{- else }}
{{ $newKey }}: {{ $value | quote }}
{{- end }}
{{- end }}
{{- end }}