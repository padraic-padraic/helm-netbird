<p align="center">
  <img width="234" src="https://github.com/netbirdio/netbird/raw/main/docs/media/logo-full.png" style="vertical-align: middle; margin: 0 1.5rem" />
  <img src="https://github.com/kubernetes/kubernetes/raw/master/logo/logo.png" width="60" style="vertical-align: middle;" />
</p>

# Netbird Helm Chart

This chart provides a means of deploying Netbird to kubernetes.


---

# Minimal Setup

To use the minimal setup, you will require

- A working kubernetes cluster with Gateway API enabled (UDPRoute uses the GA `v1` API on Gateway API 1.6+, e.g. Envoy Gateway 1.9+, and falls back to `v1alpha2` on older installs)
- A default storage class with space to provision a PVC (default 4Gi)
- A valid hostname and the ability to access it via https and UDP 3478 through the Gateway

1. Fill out the required config
   ```yaml
   global:
     domain: 
       global: netbird.example.com
       vpn: myvpn.example.com  # The domain to be used for VPN clients.  Will default to global domain if not set.
     secrets:
       authSecret: ''          # `openssl rand -base64 32`
       storeEncryptionKey: ''  # `openssl rand -base64 32`
     route:
       enabled: true
       vendor: 'envoy'  # Will automatically set timeoutes.  If not using envoy, you may have to adjust timeouts manually.
       parentRefs:
         - name: eg
           namespace: eg
           sectionName: https
       stunParentRefs:
         - name: eg
           namespace: eg
           sectionName: netbird-stun
   # If upgrading from pre v0.66.0, you may need to adjust your persistence subPath, as the default was changed to `server`.
   # server:
   #   persistence:
   #     subPath: 'management'
   ```
2. Ensure your chosen ports are accessible to the gateway (default 443 TCP/3478 UDP).
3. Run helm install (recommend pinning a specific chart version instead of latest)
   ```shell
   helm install netbird oci://ghcr.io/padraic-padraic/helm-netbird/netbird --version 0.0.0-latest -n netbird -f path/to/values.yaml
   ```
4. Once it's done setting itself, up, access it at your external URL. Once you go through the setup, you can enable
   additional auth options.

---

# Server Configuration and Secrets

The server's `config.yaml` is built from `server.config` in your values file. The chart adds the domain-derived
fields (`listenAddress`, `exposedAddress`, `stunPorts`, `dataDir`, `auth.issuer`, `auth.dashboardRedirectURIs`) and
stores the result in a ConfigMap. Anything you set under `server.config` is deep-merged over the chart defaults by
Helm, and wins over the derived fields. Lists replace rather than append, so restate a whole list to change it.

```yaml
server:
  config:
    server:
      logLevel: debug
      reverseProxy:
        trustedHTTPProxies:
          - '10.0.0.0/8'
```

Sensitive values never appear in the ConfigMap. The rendered config contains `${NB_AUTH_SECRET}` and
`${NB_STORE_ENCRYPTION_KEY}` placeholders, and an init container substitutes them from a Secret into an in-memory
volume before the server starts.

# Secrets

Both services read from one Secret, named by `global.existingSecret`. Each service declares a map from env var name
to a key in that Secret:

```yaml
global:
  existingSecret: netbird-secrets
server:
  secretEnv:                                  # defaults shown
    NB_AUTH_SECRET: authSecret
    NB_STORE_ENCRYPTION_KEY: storeEncryptionKey
dashboard:
  secretEnv: {}   # leave empty with the embedded IdP, see the warning below
```

> **Do not set `AUTH_CLIENT_SECRET` when using the embedded identity provider.** The `netbird-dashboard` OAuth client
> is registered as a *public* client with no secret. If the dashboard sends any `client_secret`, the token exchange
> fails with `invalid_client: Invalid client credentials.` and the dashboard shows "Unauthenticated" after login.
> Only map it (e.g. `AUTH_CLIENT_SECRET: dashboardClientSecret`) when you point `AUTH_AUTHORITY` at an external IdP
> that issued a confidential client.

```shell
kubectl -n netbird create secret generic netbird-secrets \
  --from-literal=authSecret="$(openssl rand -base64 32)" \
  --from-literal=storeEncryptionKey="$(openssl rand -base64 32)"
```

Each mapping becomes an explicit `env` entry with a `secretKeyRef`, so a mapped dashboard variable always overrides
the same-named default from `dashboard.env`. For the server, each env var is substituted into the matching
`${ENV_VAR}` placeholder in `config.yaml`; to inject another secret (for example a Postgres DSN), add a mapping under
`server.secretEnv` and reference `${ENV_VAR}` anywhere under `server.config`. Secret values must not contain `|`,
`&` or `\`, and should be safe as unquoted YAML scalars (base64 output is).

If `global.existingSecret` is empty, the chart creates `<release>-secrets` from `global.secrets` and fails rendering
if any mapped key is missing there.

The `netbird-server` image includes `sh` and `sed` and is used for the init container by default; override
`server.configInit.image` if you use a custom image without a shell.

# Dashboard Environment

Dashboard environment variables default from `dashboard.env` plus the domain-derived `NETBIRD_MGMT_API_ENDPOINT`,
`NETBIRD_MGMT_GRPC_API_ENDPOINT` and `AUTH_AUTHORITY`, rendered into a ConfigMap. Override any of them under
`dashboard.env`, or source them from the shared Secret via `dashboard.secretEnv` as shown above.

# Upgrading from 1.x

Chart 2.0.0 removes the `<release>-config` Secret. `authSecret` is no longer hardcoded; you must provide it via
`global.existingSecret` or `global.secrets.authSecret`, and `global.server.encryption_key` moved to
`global.secrets.storeEncryptionKey`. Peers authenticate to the relay with this value, so if you
were relying on the old built-in value, set `global.secrets.authSecret` to `taSJiSBCFkyeEqYv7iuV9neScSOCHmN0MvW4efR3lPE` to keep
existing peers connected, then rotate it when convenient. Anything you previously changed by forking the secret
template now belongs under `server.config`. PVC settings moved from `global.persistence` to `server.persistence`;
the PVC name and contents are unchanged, so existing claims are reused as long as you move any overrides
(`size`, `storageClass`, `existingClaim`, ...) to the new location.

---

# Full Configuration

## Global Settings

| config                            | description                                                                                          | default                  |
|-----------------------------------|------------------------------------------------------------------------------------------------------|--------------------------|
| global.namespace                  | Namespace for Netbird                                                                                | `'netbird'`              |
| global.domain.global              | Domain name used for access (e.g. netbird.example.com)                                               | `''`                     |
| global.domain.vpn                 | Domain name used for peer overlay network (eg peer1.netbird-vpn.example.com)                         | `<global.domain.global>` |
| global.dashboard.port             | Dashboard HTTP port                                                                                  | `80`                     |
| global.server.port                | Server HTTP port                                                                                     | `80`                     |
| global.server.stun_port           | Server STUN port                                                                                     | `3478`                   |
| global.existingSecret             | Pre-existing Secret shared by server and dashboard                                                   | `''`                     |
| global.secrets                    | Key/value map used to create the Secret when `global.existingSecret` is empty                        | see values.yaml          |
| global.route.enabled              | Enable GatewayAPI access                                                                             | `false`                  |
| global.route.vendor               | Type of GatewayAPI installed, eg. `envoy`.  Automatically installs traffic policies to fix timeouts. | `''`                     |
| global.route.parentRefs           | The gateway parentRefs                                                                               | `[]`                     |
| global.route.stunParentRefs       | STUN likely uses a different port in the gateway, so you can specify a different parent ref here     | `[]`                     |
| global.route.udpRouteApiVersion   | UDPRoute apiVersion; empty auto-detects `v1` (Gateway API >= 1.6) else `v1alpha2`                    | `''`                     |
| global.route.annotations          | Annotations to apply to GatewayAPI resources                                                         | `{}`                     |
| global.serviceAccount.create      | Create service account                                                                               | `true`                   |
| global.serviceAccount.automount   | Auto-mount service account                                                                           | `true`                   |
| global.serviceAccount.annotations | Service account annotations                                                                          | `{}`                     |
| global.serviceAccount.name        | Service account name                                                                                 | `""`                     |

## Component Specific Settings

| config                             | description                | default                      |
|------------------------------------|----------------------------|------------------------------|
| dashboard.image.repository         | Dashboard image repository | `'netbirdio/dashboard'`      |
| dashboard.image.tag                | Dashboard image tag        | `'v2.92.0'`                  |
| dashboard.image.pullPolicy         | Image pull policy          | `'IfNotPresent'`             |
| dashboard.annotations              | Pod annotations            | `{}`                         |
| dashboard.labels                   | Pod labels                 | `{}`                         |
| dashboard.nodeSelector             | Node selector              | `{}`                         |
| dashboard.tolerations              | Tolerations array          | `[]`                         |
| dashboard.affinity                 | Affinity rules             | `{}`                         |
| dashboard.replicaCount             | Replica count              | `1`                          |
| dashboard.resources                | Resource limits/requests   | `{}`                         |
| dashboard.livenessProbe            | Liveness probe settings    |                              |
| dashboard.readinessProbe           | Readiness probe settings   |                              |
| dashboard.service.type             | Dashboard service type     | `'ClusterIP'`                |
| dashboard.extra_volumes            | Additional volumes         | `[]`                         |
| dashboard.extra_volumeMounts       | Additional volume mounts   | `[]`                         |
| dashboard.env                      | Default env vars (map)     | see values.yaml              |
| dashboard.secretEnv                | Env var -> Secret key map  | `{}`                         |
| **Server**                         |                            |                              |
| server.image.repository            | Server image repository    | `'netbirdio/netbird-server'` |
| server.image.tag                   | Server image tag           | `'0.78.1'`                   |
| server.image.pullPolicy            | Image pull policy          | `'IfNotPresent'`             |
| server.annotations                 | Pod annotations            | `{}`                         |
| server.labels                      | Pod labels                 | `{}`                         |
| server.nodeSelector                | Node selector              | `{}`                         |
| server.tolerations                 | Tolerations                | `[]`                         |
| server.affinity                    | Affinity rules             | `{}`                         |
| server.replicaCount                | Replica count              | `1`                          |
| server.resources                   | Resource limits/requests   | `{}`                         |
| server.livenessProbe               | Liveness probe settings    |                              |
| server.readinessProbe              | Readiness probe settings   |                              |
| server.service.type                | Service type               | `'ClusterIP'`                |
| server.extra_volumes               | Additional volumes         | `[]`                         |
| server.extra_volumeMounts          | Additional volume mounts   | `[]`                         |
| server.extra_args                  | Additional CLI arguments   | `[]`                         |
| server.config                      | config.yaml tree (merged)  | see values.yaml              |
| server.secretEnv                   | Env var -> Secret key map  | see values.yaml              |
| server.configInit.image            | Init container image       | server image                 |
| server.configInit.resources        | Init container resources   | `{}`                         |
| server.persistence.enabled         | Create/use a PVC (false = emptyDir) | `true`              |
| server.persistence.existingClaim   | Use an existing PVC        | `''`                         |
| server.persistence.volumeName      | Volume name; PVC is `<release>-<volumeName>` | `'data'`   |
| server.persistence.storageClass    | Storage class (empty = default) |                         |
| server.persistence.accessModes     | AccessModes list           | `[ReadWriteOnce]`            |
| server.persistence.size            | Requested disk size        | `'4Gi'`                      |
| server.persistence.volumeMode      | Volume mode                |                              |
| server.persistence.annotations     | PVC annotations            | `{}`                         |
| server.persistence.labels          | PVC labels                 | `{}`                         |
| server.persistence.selector        | PVC selector               | `{}`                         |
| server.persistence.dataSource      | PVC data source            | `{}`                         |
| server.persistence.dataDir         | `server.dataDir` in config | `'/var/lib/netbird'`         |
| server.persistence.mountPath       | Where to mount storage     | `'/var/lib/netbird'`         |
| server.persistence.subPath         | SubPath within the volume  | `'server'`                   |
| server.persistence.configMountPath | Where the rendered config is written | `'/etc/netbird/config.yaml'` |

