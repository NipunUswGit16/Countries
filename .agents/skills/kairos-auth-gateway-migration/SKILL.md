---
name: kairos-auth-gateway-migration
description: Migrates an existing Kairos component to Nexus Auth Gateway for local development. Use when adding, porting, troubleshooting, or reviewing auth-gateway sidecar injection, Helm auth routing, local OAuth configuration, or memory-backed sessions.
---

# Nexus Auth Gateway Migration

Enable Nexus Auth Gateway in an existing Kairos component. Kyverno injects the
gateway into the `client-api` pod; never add an Auth Gateway container manually.

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

Run these in the component root. `<chart>` is `chart/` if it exists, else `charts/`.

1. **Chart version.** Read it with
   `yq -r '.dependencies[] | select(.name=="kairos-components-common") | .version' <chart>/Chart.yaml`.
   - **Below 0.6.0** (or no such dependency): stop. This skill needs 0.6.0 or
     later: older charts have no `subPath` and emit a full-URL `API_BASE_URL`, so
     following it breaks login. Tell the author to bump the chart first, as its
     own change: set the version to 0.6.0 or later and refresh `Chart.lock`
     (`helm dependency update <chart>`); delete every `include "kairos.env.kafka"`
     under `<chart>/templates/` (the helper is gone and Helm fails); set
     `defaults.systemPort` in `<chart>/values.yaml` (the auth-gateway
     NetworkPolicy fails the render without it). Then re-run these checks.
   - **0.6.0 or later:** continue. Treat the installed helper templates as
     authoritative.
2. **Gateway already present.** If `<chart>/templates/client-api/auth-gateway-config.yaml`
   exists and `grep -q 'kairos.authGatewayIngressAndService' <chart>/templates/client-api/ingress.yaml`
   matches, the gateway is in place. Do only the `subPath` item, the OAuth
   callback in the `values.dev.yaml` item, the SPA paths item and [Verify](#verify). Otherwise do the full checklist.
3. Confirm the component path/name and whether a web app exists.
4. Preserve `defaults.auth`: Auth Gateway does not replace client-api JWT
   validation. The backend defaults to the `principal_id` claim; configure a
   different deployed claim only when the environment's token contract requires it.
5. This skill covers local development only. Do not modify GitOps or
   shared-environment configuration.

## Component chart checklist

Apply these changes to the component chart.

- [ ] Refresh `Chart.lock` if `Chart.yaml` changed (`helm dependency update <chart>`).
- [ ] Add `templates/client-api/auth-gateway-config.yaml`:

  ```gotemplate
  {{- include "kairos.authGatewayConfigMap" (dict "root" . "app" "client-api") }}
  ```

- [ ] Add the injection annotation to the client-api Deployment metadata:

  ```yaml
  ifs.com/auth-gateway-inject: "true"
  ```

- [ ] Replace direct client-api ingress rendering with the Auth Gateway ingress +
  service. Pass a `subPath` so browser traffic is namespaced and does not
  collide with the component's integration-api ingress (which keeps `/<app>/api`):

  ```gotemplate
  {{ include "kairos.authGatewayIngressAndService" (dict "root" . "app" "client-api" "subPath" "/client") }}
  ```

  With `subPath "/client"` this routes `/<app>/client/auth*` and
  `/<app>/client/api*` through the sidecar on port 9082. The current template
  ships `/client`; omit `subPath` only for a component with no integration-api,
  which puts the gateway back on `/<app>/api`. Whatever you choose must match the
  SPA's `API_BASE_PATH` / `AUTH_BASE_PATH` (below).

- [ ] For web components, render ingress through `frontend.ingress` with the
  resolved web app config:

  ```gotemplate
  {{- $webConfig := include "bundle.getAppConfig" (dict "root" . "app" "web") | fromYaml }}
  {{ include "frontend.ingress" (dict
    "name" (printf "%s-web" .Release.Namespace)
    "appLabel" "web"
    "Values" $webConfig
    "Root" .
  ) }}
  ```

  The web ingress owns only `/<app>` and static assets. It must not capture
  `/api`, `/auth`, `/client/api`, or `/client/auth`. Pass `exclude` for any
  extra API prefixes. Set the frontend build base path to `/<app>/`.

- [ ] In `templates/config/external-secrets.yaml`, conditionally render the
  Redis ExternalSecret:

  ```gotemplate
  {{- if eq ((index .Values "client-api").authGateway.sessionStorageType | default "memory") "redis" }}
  {{ include "kairos.externalSecret.authGatewayRedis" (dict "Values" (index .Values "client-api").authGateway.redis "Root" .) }}
  {{- end }}
  ```

- [ ] In `values.yaml`, configure `client-api.authGateway.enabled`, the
  component `applicationId`. Preserve the backend default `principal_id` claim
  unless the deployed environment requires an override.
- [ ] In `values.dev.yaml`, use `ingress.tenantHost`, one client-api replica,
  disabled autoscaling, `deploymentType: single-tenant`, and
  `sessionStorageType: memory`. Do not override `principalIdClaim`. Set the OAuth
  callback to match the `subPath` — with the shipped `/client` it is
  `https://<local-host>/<app>/client/auth/v1/callback` (a callback without
  `/client` means the subPath was skipped) — plus the in-cluster OAuth token URL.

- [ ] Configure the browser-facing SPA paths (no web app: skip this item).
  Read which variable the chart emits for the web app: run
  `helm dependency build <chart>`, then
  `helm template <chart> -f <chart>/values.dev.yaml | grep -oE 'API_BASE_(PATH|URL)' | sort -u`.

  - **`API_BASE_PATH`:** the web Deployment renders `kairos.env.web`, which
    emits **path-only** `API_BASE_PATH` / `AUTH_BASE_PATH` from the
    `apiBasePath` / `authBasePath` values (defaults `client/api/v1` /
    `client/auth/v1`). Set them to match the `subPath`, remove any
    `web.apiBaseUrl` (chart 0.6.0 no longer reads it), and add a `web/.env` with
    the same path-only keys for local / image builds:

    ```text
    API_BASE_PATH=client/api/v1
    AUTH_BASE_PATH=client/auth/v1
    ```

  - **`API_BASE_URL`, or neither:** the web Deployment sets its env without
    `kairos.env.web`. Replace that with
    `{{- include "kairos.env.web" (dict "Values" $appConfig "Root" .) | nindent 12 }}`
    in the container `env`, then re-run the check and follow the
    `API_BASE_PATH` side.

## Verify

1. Render the chart with local values. Confirm:
   - `auth-gateway-config` exists;
   - client-api has `ifs.com/auth-gateway-inject: "true"`;
   - `/api` and `/auth` target the Auth Gateway Service;
   - Redis ExternalSecret is absent for memory sessions;
   - web ingress excludes `/api`, `/auth`, `/client/api`, and `/client/auth`.
2. Deploy to a local cluster. The gateway is a container in the client-api pod,
   not a separate pod; verify `auth-gateway` and `client-api` are both ready.
3. Verify login and an authenticated `/<app>/client/api/v1` call (or
   `/<app>/api/v1` if you omitted `subPath`) through the browser-facing HTTPS URL.

## Troubleshooting

- Gateway container absent: check the ConfigMap helper, Deployment annotation,
  and shared-chart version.
- Pod is `Pending`: inspect scheduling events. The injected sidecar adds a
  100m CPU request; free local cluster CPU or reduce nonessential local
  workloads.
- Login works but API calls fail: align the local OAuth client ID,
  `defaults.auth.tokenAudience`, and `authGateway.applicationId`; then inspect
  issuer and JWKS settings.
- Session persistence errors: local development requires memory sessions and
  one client-api replica.
- Assets 404 or gateway routes are captured by web: check `frontend.ingress`
  and the frontend base path.
