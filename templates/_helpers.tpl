{{/*
Expand the name of the chart.
*/}}
{{- define "netbird.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "netbird.fullname" -}}
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
{{- define "netbird.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "netbird.labels" -}}
helm.sh/chart: {{ include "netbird.chart" . }}
{{ include "netbird.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "netbird.selectorLabels" -}}
app.kubernetes.io/name: {{ include "netbird.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "netbird.serviceAccountName" -}}
{{- if .Values.global.serviceAccount.create }}
{{- default (include "netbird.fullname" .) .Values.global.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.global.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Name of the single Secret shared by server and dashboard.
*/}}
{{- define "netbird.secretName" -}}
{{- default (printf "%s-secrets" (include "netbird.fullname" .)) .Values.global.existingSecret }}
{{- end }}

{{/*
Render a container env list from a map of ENV_VAR -> secret key, all read from the shared Secret.
Usage: include "netbird.secretEnv" (dict "root" $ "map" .Values.server.secretEnv)
*/}}
{{- define "netbird.secretEnv" -}}
{{- range $env, $key := .map }}
- name: {{ $env }}
  valueFrom:
    secretKeyRef:
      name: {{ include "netbird.secretName" $.root }}
      key: {{ $key }}
{{- end }}
{{- end }}

{{/*
Rendered server config.yaml: domain-derived defaults, then user config on top.
Secret fields are emitted as ${KEY} placeholders that the config-init container substitutes.
*/}}
{{- define "netbird.serverConfig" -}}
{{- $domain := required "global.domain.global is required" .Values.global.domain.global -}}
{{- $derived := dict "server" (dict
      "listenAddress" (printf ":%v" .Values.global.server.port)
      "exposedAddress" (printf "https://%s:443" $domain)
      "stunPorts" (list .Values.global.server.stun_port)
      "dataDir" .Values.server.persistence.dataDir
      "authSecret" "${NB_AUTH_SECRET}"
      "auth" (dict
        "issuer" (printf "https://%s/oauth2" $domain)
        "dashboardRedirectURIs" (list
          (printf "https://%s/nb-auth" $domain)
          (printf "https://%s/nb-silent-auth" $domain)))
      "store" (dict "encryptionKey" "${NB_STORE_ENCRYPTION_KEY}")) -}}
{{- $merged := mergeOverwrite $derived (deepCopy (.Values.server.config | default dict)) -}}
{{- toYaml $merged -}}
{{- end }}

{{/*
Shell script run by the config-init container: verify secret env vars are set, then substitute
${KEY} placeholders in the ConfigMap template and write the final config.yaml.
*/}}
{{- define "netbird.serverConfigInitScript" -}}
set -eu
{{- range $env, $_ := .Values.server.secretEnv }}
{{ printf ": \"${%s:?%s must be set in the shared secret}\"" $env $env }}
{{- end }}
sed \
{{- range $env, $_ := .Values.server.secretEnv }}
{{ printf "  -e \"s|\\${%s}|${%s}|g\" \\" $env $env }}
{{- end }}
  /netbird-config-template/config.yaml > {{ .Values.server.persistence.configMountPath | quote }}
{{- end }}
