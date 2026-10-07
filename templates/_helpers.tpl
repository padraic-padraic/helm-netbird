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
Relay helpers. Each renders "true" or nothing so callers can use `if include "..." .`.

NetBird's combined server runs STUN as part of its embedded relay: as soon as server.relays is set, both the
embedded relay and the embedded STUN listener are disabled. So whenever relay.enabled, STUN has to be served by
the in-cluster relay (relay.inCluster.stun.enabled) or supplied via relay.external.stuns, and the UDPRoute moves
away from the server Service.
*/}}
{{- define "netbird.relay.enabled" -}}
{{- if .Values.relay.enabled -}}
{{- if or .Values.relay.inCluster.enabled .Values.relay.external.addresses -}}
true
{{- else -}}
{{- fail "relay.enabled is true but no relay is configured: set relay.inCluster.enabled or add relay.external.addresses" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "netbird.relay.inCluster" -}}
{{- if and (include "netbird.relay.enabled" .) .Values.relay.inCluster.enabled -}}true{{- end -}}
{{- end }}

{{- define "netbird.relay.inClusterStun" -}}
{{- if and (include "netbird.relay.inCluster" .) .Values.relay.inCluster.stun.enabled -}}true{{- end -}}
{{- end }}

{{/* Hostname used for the in-cluster relay's HTTPRoute, advertised relay address and STUN URI */}}
{{- define "netbird.relay.domain" -}}
{{- .Values.global.domain.relay | default (required "global.domain.global is required" .Values.global.domain.global) -}}
{{- end }}

{{- define "netbird.relay.exposedAddress" -}}
{{- .Values.relay.inCluster.exposedAddress | default (printf "rels://%s:443" (include "netbird.relay.domain" .)) -}}
{{- end }}

{{/* Relay addresses advertised to peers: in-cluster first, then external */}}
{{- define "netbird.relay.addresses" -}}
{{- $addresses := list -}}
{{- if include "netbird.relay.inCluster" . -}}
{{- $addresses = append $addresses (include "netbird.relay.exposedAddress" .) -}}
{{- end -}}
{{- toJson (concat $addresses (.Values.relay.external.addresses | default list)) -}}
{{- end }}

{{/* STUN hosts advertised to peers (server.stuns) when the embedded STUN is disabled */}}
{{- define "netbird.relay.stuns" -}}
{{- $stuns := .Values.relay.external.stuns | default list -}}
{{- if include "netbird.relay.inClusterStun" . -}}
{{- $stuns = prepend $stuns (dict "uri" (printf "stun:%s:%v" (include "netbird.relay.domain" .) .Values.global.relay.stun_port)) -}}
{{- end -}}
{{- if not $stuns -}}
{{- fail "relay.enabled disables the server's embedded STUN: enable relay.inCluster.stun or set relay.external.stuns" -}}
{{- end -}}
{{- toJson $stuns -}}
{{- end }}

{{/*
Rendered server config.yaml: domain-derived defaults, then user config on top.
Secret fields are emitted as ${KEY} placeholders that the config-init container substitutes.
With relays enabled, server.relays/server.stuns replace stunPorts so the server neither runs nor advertises
its own relay and STUN.
*/}}
{{- define "netbird.serverConfig" -}}
{{- $domain := required "global.domain.global is required" .Values.global.domain.global -}}
{{- $server := dict
      "listenAddress" (printf ":%v" .Values.global.server.port)
      "exposedAddress" (printf "https://%s:443" $domain)
      "dataDir" .Values.server.persistence.dataDir
      "authSecret" "${NB_AUTH_SECRET}"
      "auth" (dict
        "issuer" (printf "https://%s/oauth2" $domain)
        "dashboardRedirectURIs" (list
          (printf "https://%s/nb-auth" $domain)
          (printf "https://%s/nb-silent-auth" $domain)))
      "store" (dict "encryptionKey" "${NB_STORE_ENCRYPTION_KEY}") -}}
{{- if include "netbird.relay.enabled" . -}}
{{- $_ := set $server "relays" (dict
      "addresses" (include "netbird.relay.addresses" . | fromJsonArray)
      "secret" "${NB_AUTH_SECRET}"
      "credentialsTTL" .Values.relay.credentialsTTL) -}}
{{- $_ := set $server "stuns" (include "netbird.relay.stuns" . | fromJsonArray) -}}
{{- else -}}
{{- $_ := set $server "stunPorts" (list .Values.global.server.stun_port) -}}
{{- end -}}
{{- $merged := mergeOverwrite (dict "server" $server) (deepCopy (.Values.server.config | default dict)) -}}
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
