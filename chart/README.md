# Kairos Component Helm Chart

This Helm chart deploys a Kairos component with client-api, integration-api, event-handler, and web services, plus two per-tenant jobs (db-script-runner and the dataloader).

## Library Chart Dependency

This chart depends on the `kairos-components-common` library chart, which provides shared Helm helpers for consistent Kairos component deployments.

### Available Helpers

#### Health Probes

**kairos.livenessProbe**
```yaml
{{- include "kairos.livenessProbe" (dict "port" 8080 "path" "/healthz" "initialDelaySeconds" 30 "periodSeconds" 10 "timeoutSeconds" 5 "failureThreshold" 3) | nindent 10 }}
```

**kairos.readinessProbe**
```yaml
{{- include "kairos.readinessProbe" (dict "port" 8080 "path" "/readyz" "initialDelaySeconds" 30 "periodSeconds" 10 "timeoutSeconds" 5 "failureThreshold" 3) | nindent 10 }}
```

#### Autoscaling

**kairos.horizontalPodAutoscaler**
```yaml
{{ include "kairos.horizontalPodAutoscaler" (dict "name" "my-app" "targetRef" "my-app-deployment" "Values" $appConfig) }}
```

Generates a complete HPA resource when `autoscaling.enabled` is true in values.

#### High Availability

**kairos.podDisruptionBudget**
```yaml
{{- include "kairos.podDisruptionBudget" (dict "name" "client-api" "appLabel" "client-api" "Values" $appConfig "Root" .) }}
```

Generates a PodDisruptionBudget when `podDisruptionBudget.enabled` is true.

#### Monitoring

**kairos.serviceMonitor**
```yaml
{{- include "kairos.serviceMonitor" (dict "name" "client-api" "appLabel" "client-api" "port" "http" "interval" "5s" "Values" $appConfig "Capabilities" .Capabilities "Root" .) }}
```

Generates a ServiceMonitor for Prometheus when the CRD is available.

#### Security

**kairos.containerSecurityContext**
```yaml
{{- include "kairos.containerSecurityContext" . | nindent 10 }}
```

Applies secure defaults:
- readOnlyRootFilesystem: true
- allowPrivilegeEscalation: false
- drops all capabilities

**kairos.podSecurityContext**
```yaml
{{- include "kairos.podSecurityContext" (dict "runAsUser" 1001 "runAsGroup" 1001 "fsGroup" 1001) | nindent 6 }}
```

Applies pod-level security:
- runAsNonRoot: true
- runAsUser, runAsGroup, fsGroup configuration

#### Volumes

App Deployments (client-api, integration-api, event-handler) include these wrappers. They mount postgres credentials when `Values.postgres` is set.

**kairos.volumeMounts**
```yaml
{{- include "kairos.volumeMounts" (dict "Root" .) | nindent 12 }}
```

**kairos.volumes**
```yaml
{{- include "kairos.volumes" (dict "Root" .) | nindent 8 }}
```

## Usage Example

See the templates in this chart for real-world examples of using these helpers:
- `templates/client-api/deployment.yaml` - probes and security contexts
- `templates/client-api/hpa.yaml` - horizontal pod autoscaler
- `templates/client-api/pod-disruption-budget.yaml` - PDB configuration
- `templates/client-api/service-monitor.yaml` - Prometheus monitoring

## Installing the Chart

```bash
helm install my-component . -f values.yaml
```

## Updating Dependencies

After modifying Chart.yaml dependencies, from this `chart/` directory:

```bash
helm dependency update
```

This downloads the library chart to `charts/*.tgz` (repo path `chart/charts/*.tgz`) and updates `Chart.lock`.

## Values Configuration

See `values.yaml` for complete configuration options. Key sections:
- `defaults.podDisruptionBudget` - PDB settings
- `defaults.serviceMonitor` - Prometheus monitoring
- `client-api.autoscaling` - HPA configuration
- `client-api.authGateway` - Auth-gateway sidecar config (OAuth, sessions, Redis)
- `event-handler.autoscaling` - HPA configuration
- `ingress.tenantHost` - Hostname for tenant-facing ingress rules (web + client-api)
- `ingress.host` - Non-tenant / platform hostname (integration-api, in addition to tenantHost)
- `debezium` - master-data CDC (optional; off in `values.yaml` and `values.dev.yaml` until kafka-connect is installed)

## Master-data CDC (Debezium)

Capture master-data changes from PostgreSQL into Kafka as CloudEvents Pattern B (flat JSON value + `ce_*` headers on per-entity topics).

**Prerequisites (once per cluster):**

1. Install `kairos-kafka-connect` (Strimzi + Connect image with `MasterDataCdcTransform`): `kairos cluster services install kafka-connect` (Kairos CLI 0.3.20+)

**Per component:**

1. Define master-data entities in `pkg/schema/masterdata/` (embed `MasterDataEntityBase`)
2. Set `COMPONENT_NAME` and replace `countries` in `chart/values.yaml` / `values.dev.yaml`
3. `make generate` — writes `chart/resources/masterdata-entities.json` and CDC SQL under `sql/1.gen/` automatically.
4. `make deploy` — renders `KafkaConnector/<comp>-cdc` and `ExternalSecret/<comp>-db` in `kairos-kafka-connect`

**Verify:** insert/update a master-data row, then consume `<component>.<entity>.<version>.<tenantId>`.

See `docs/cdc/debezium/SETUP.md` and `docs/cdc/debezium/ADDING-MASTERDATA-ENTITIES.md`.

## Auth Gateway

The client-api Deployment is annotated for Kyverno to inject an **auth-gateway sidecar**. Your chart must provide:

1. **`templates/client-api/auth-gateway-config.yaml`** — ConfigMap read by the sidecar (`kairos.authGatewayConfigMap`)
2. **`templates/client-api/ingress.yaml`** — Routes `/<namespace>/client/(auth|api…)` to the sidecar (`kairos.authGatewayIngressAndService`)
3. **`client-api.authGateway` in values** — OAuth URLs, session storage, and `applicationId`

Local dev (`values.dev.yaml`) typically uses `deploymentType: single-tenant` and `sessionStorageType: memory`. Production/GitOps uses `multitenant` + `redis` with ExternalSecrets for Redis credentials.

Requires cluster policy `inject-auth-gateway-sidecar` (auth-gateway-policy chart). See [.kairos-updates/20260811T140819-adopt-auth-gateway-sidecar.md](../.kairos-updates/20260811T140819-adopt-auth-gateway-sidecar.md) for migration steps from kairos-components-common 0.2.2.
