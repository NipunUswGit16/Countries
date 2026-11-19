# Debezium — Master-data CDC setup

End-to-end recipe to capture master-data changes with **Debezium** and emit
**CloudEvents Pattern B** on Kafka, on a local cluster (k3d via Kairos CLI).

Architecture & rationale: [`MASTERDATA-CDC-ARCHITECTURE.md`](./MASTERDATA-CDC-ARCHITECTURE.md).

Step-by-step guide for adding entities (producer + consumer): [`ADDING-MASTERDATA-ENTITIES.md`](./ADDING-MASTERDATA-ENTITIES.md).

Envelope contract and transform chain: [`MASTERDATA-CDC-MECHANISM.md`](./MASTERDATA-CDC-MECHANISM.md).

**Single-tier pipeline:** one `KafkaConnector` on a shared Strimzi-managed Kafka
Connect cluster captures Postgres WAL changes and applies Debezium
`ExtractNewRecordState` plus the Kairos `MasterDataCdcTransform` custom SMT in
the connector — no downstream consumer.

A component contributes a `KafkaConnector` CR; Postgres credentials for the
connector live in `kairos-kafka-connect/<comp>-db`. How that secret appears:

| Environment | Provisioner |
|---|---|
| **Local k3d** | Kyverno `generate-debezium-db-secret` (`nga-local-dev`). Chart must **not** emit `ExternalSecret` (`debezium.dbSecret.enabled: false` in `values.dev.yaml`). Secret user/password is the dedicated local `debezium` role (FIPS-length password), not `postgres`/`postgres`. |
| **Nexus / GitOps** | Component chart `ExternalSecret` (`chart/templates/debezium/db-secret.yaml`) when `debezium.dbSecret.enabled: true` (default), syncing the same Key Vault keys as `postgres.usernameSecretName` / `postgres.passwordSecretName`. |

The toolkit no longer has a post-deploy hook that copied credentials;
provisioning is environment- or chart-owned. The `db-secret.yaml` template
ships in this template for new components — it is not a Nexus-only stopgap.

---

## 0. Prerequisites

- Kairos CLI **0.3.20+** (`kairos --version`). Older CLIs still run the
  pre-0.3.20 Strimzi CRD bootstrap and fail with
  `kafkaconnects.kafka.strimzi.io not found`.
- A running local cluster (`kairos cluster create`) with **postgres** and
  **redpanda** (defaults).
- `kubectl`, `helm`, `make`.

---

## 1. Install Kafka Connect locally (once per cluster)

This is the **supported** path. Do **not** run `make install-strimzi` from
`kairos-kafka-connect` — that script is deprecated and is what produces the
`kafkaconnects.kafka.strimzi.io not found` error.

```bash
kairos cluster services install kafka-connect
```

That:

1. Pre-pulls the Strimzi operator + Connect images and imports them into k3d
2. Installs the **kairos-kafka-connect** OCI chart (Strimzi operator + CRDs +
   `KafkaConnect/kairos-debezium` in one Helm release)
3. Applies Kyverno `generate-debezium-db-secret` **after** the KafkaConnector CRD exists

```bash
kubectl -n kairos-kafka-connect get kafkaconnect kairos-debezium
# Expect: READY True  (or wait a minute for the Connect pod)
```

If postgres was installed **before** the CLI started creating the local
`debezium` role, create it once (a fresh CLI postgres install does this
automatically):

```bash
kubectl exec -n postgres postgres-0 -- psql -U postgres -c "
  CREATE ROLE debezium LOGIN REPLICATION PASSWORD 'debezium-cdc-local';
  GRANT pg_read_all_data TO debezium;
"
```

(`IF NOT EXISTS` / `ALTER ROLE` is fine if it already exists.)

---

## 2. Prepare the component

### 2.1 Define master-data entities

Add structs embedding `entities.MasterDataEntityBase[T]` under `pkg/schema/masterdata/`,
then:

```bash
make generate     # writes chart/resources/masterdata-entities.json + sql/1.gen/*.sql
```

Do not author `masterdata-entities.json` or add a Makefile include. When
`pkg/schema` contains a `MasterDataEntityBase` embedder, `make generate` passes
`--masterdata-output` and writes the descriptor. See
[`ADDING-MASTERDATA-ENTITIES.md`](./ADDING-MASTERDATA-ENTITIES.md) §7.

`make generate` also emits `ALTER TABLE … REPLICA IDENTITY FULL`, which Debezium
needs for full before-images on UPDATE/DELETE.

The template ships with no master-data entities (`"entities": []`). With
`debezium.enabled=true` and an empty list, the chart fails fast and tells you
to run `make generate`.

### 2.2 Configure values (local)

`chart/values.dev.yaml` keeps `debezium.enabled: false` (kafka-connect is not
installed by default) and `debezium.dbSecret.enabled: false`. After
`kairos cluster services install kafka-connect`, enable CDC for that deploy
without editing files:

```bash
make deploy HELM_EXTRA_ARGS='--set debezium.enabled=true'
```

Or set `debezium.enabled: true` in `values.dev.yaml` if you want it on every
local deploy. Leave `dbSecret.enabled: false` so Kyverno owns
`Secret/<comp>-db`.

Do **not** set `postgres.usernameSecretName` / `passwordSecretName` locally —
those are GitOps Key Vault keys. Rendering `db-secret.yaml` without them is
what used to fail `make deploy` at template time.

On Nexus / GitOps leave `debezium.dbSecret.enabled: true` (chart default) and
set the KV keys.

---

## 3. Deploy

```bash
make deploy
```

- **Local (k3d):** with `debezium.enabled: true` this renders
  `KafkaConnector/<comp>-cdc` into `kairos-kafka-connect`. Kyverno sees the
  connector label `debezium.kairos.dev/component` and generates
  `Secret/<comp>-db` for the local `debezium` role.
- **Nexus/GitOps:** the chart also renders `ExternalSecret/<comp>-db`, syncing
  `user`/`password` from the same Key Vault keys as
  `postgres.usernameSecretName` / `postgres.passwordSecretName`. Set
  `debezium.enabled: true` and ensure the AppProject
  allows destination `kairos-kafka-connect` plus `KafkaConnector` +
  `ExternalSecret` resources. See §3.1 — on Nexus the database side is owned by
  the platform, not by this chart.

### 3.1 Nexus (CNPG) prerequisites

On Nexus the CNPG cluster is the publisher and this connector is a consumer
governed by the platform's CDC contract, so three things must be requested from
the platform team before the connector can stream:

| Needed | Why |
|---|---|
| `wal_level: logical`, `hot_standby_feedback`, `sync_replication_slots`, a bounded `max_slot_wal_keep_size` | Logical decoding is opt-in; the CNPG chart refuses to render a publication without a WAL cap |
| A `publications[]` entry (`allTables: true`) | `FOR ALL TABLES` requires superuser, so the connector cannot create it itself — and only an all-tables publication captures new tenant schemas without a connector restart |
| `replication: true` and `inRoles: [pg_read_all_data]` on the component's existing app role | The connector authenticates as that role; without the replication attribute it cannot open a replication connection |

`allTables: true` is the right shape here: tenant schemas are UUID-named and
appear at runtime, so an all-tables publication picks up new tenants with no
redeploy, while `schema.include.list` and `table.include.list` keep decoding
narrowed to master-data tables. `pg_read_all_data` likewise covers schemas
created later.

The connector reuses the app role's Key Vault credentials, so no separate
secret is needed — but note this widens the app role, which now carries the
replication attribute and can read every schema in the database.

Separately, the FIPS provider in the Connect image rejects passwords shorter
than 112 bits, so the role's password must be **at least 14 characters**.
Rotating it also rotates the app's own credential: the ExternalSecret refresh
interval applies before pods pick up the new value.

Then point the chart at the publication that was provisioned:

```yaml
debezium:
  publicationName: cdc_pub          # must match the platform's publications[] entry
  publicationAutocreateMode: disabled
```

Three connector details are handled by the chart and are worth knowing:

- **The connector targets the CNPG primary** (`<postgres.cluster.name>-rw`), not
  `postgres.service`, which is the PgBouncer pooler. A pooler cannot carry a
  replication connection.
- **`slot.failover` is on by default.** A PG17 logical slot is silently dropped
  on failover unless created with this flag, and only the party creating the
  slot can set it. Debezium ignores the flag unless it is talking to a PG17+
  primary, so it is safe everywhere.

- **Failed tasks restart themselves.** `debezium.autoRestart.enabled` (default
  `true`) makes Strimzi restart a FAILED task with backoff instead of leaving it
  down until a manual restart. It cannot fix a persistent cause (see §6), so
  still alert on task state.

Master-data generation is part of `make generate`. The toolkit passes
`--masterdata-output` when `pkg/schema` contains a `MasterDataEntityBase`
embedder. There is no `masterdata-cdc.mk` include. See
[`ADDING-MASTERDATA-ENTITIES.md`](./ADDING-MASTERDATA-ENTITIES.md) §7.

---

## 4. Verify

```bash
# Connector AND task state — the connector can report RUNNING while its only
# task is FAILED (autoRestart retrying), so check both.
kubectl -n kairos-kafka-connect get kafkaconnector <comp>-cdc \
  -o jsonpath='{.status.connectorStatus.connector.state}{" / "}{.status.connectorStatus.tasks[0].state}{"\n"}'

# Secret generated by Kyverno (local)
kubectl -n kairos-kafka-connect get secret <comp>-db -o jsonpath='{.data.user}' | base64 -d; echo

# ONE slot for the component. Healthy on Nexus: active and failover both true,
# wal_status reserved. failover=false means the slot will not survive a failover.
psql "$DSN" -c "select slot_name, active, failover, wal_status from pg_replication_slots where slot_name like 'kairos_dbz_%';"

# Per-entity topics (tenant-scoped CloudEvents Pattern B contract):
kubectl -n redpanda exec redpanda-0 -- \
  rpk topic consume '<comp>.<entity>.1.<tenantUuid>' --offset start --num 1 -f '%h\n%v\n'
```

Expect `content-type`, `ce_ifstenantid`, `ce_type` (`<comp>.<entity>.<version>`),
`ce_source` (`<comp>`), `ce_subject`, `ce_id`, `ce_time`, `ce_specversion`,
`ce_datacontenttype`, and `ce_ifsmessagetype` (`master-data`) headers; the Kafka
**key** is the row `id` UUID string; the **value** is the **parsed JSONB entity
document** (not a `{id,data}` wrapper). `ce_operation` and **`ce_ifsmasterdata`**
are **not** emitted. Full contract:
[`MASTERDATA-CDC-MECHANISM.md`](./MASTERDATA-CDC-MECHANISM.md).

---

## 5. Add a tenant / entity later

- **New entity:** add the Go struct, `make generate`, `make deploy`. The
  `table.include.list` regenerates automatically.
- **New tenant:** with `tenants: []` (UUID regex mode), a new tenant schema is
  picked up on connector restart. With an explicit `tenants` list, add the schema
  UUID and redeploy. The same single slot covers all tenants; no new slot is
  created.

---

## 6. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `kafkaconnects.kafka.strimzi.io not found` during `kairos cluster services install kafka-connect` | CLI **&lt; 0.3.20**. Update (`kairos update`) and retry. Do not hack `install-strimzi.sh`. |
| Helm fail: `debezium.dbSecret.enabled requires postgres.usernameSecretName` | Local chart still rendering ExternalSecret. Set `debezium.dbSecret.enabled: false` in `values.dev.yaml`. |
| Connector `NotReady`, secret not found | Strimzi cannot resolve `${secrets:kairos-kafka-connect/<comp>-db:…}`. Local: confirm `ClusterPolicy/generate-debezium-db-secret` exists and ClusterRole `kyverno:generate-debezium-db-secret` is aggregated; delete/recreate the KafkaConnector to retrigger generate. Nexus: check the `ExternalSecret/<comp>-db` sync status. |
| `FipsUnapprovedOperationError` / password must be at least 112 bits (local) | Secret still has `postgres`/`postgres` (8 chars). Re-apply the kafka-connect policy and create the `debezium` role (see §1). |
| Connector `FAILED`, auth error | Local: the `debezium` role is missing (§1). Nexus: the app role cannot log in or lacks `replication` (§3.1). |
| Task `FAILED` every ~30 min with `Unable to obtain valid replication slot`; connector `RUNNING` | autoRestart is retrying a slot it can never acquire. Check `pg_replication_slots` for the slot: if another session holds it (`active`), terminate that `active_pid`; if `wal_status` is `lost` or `confirmed_flush_lsn` is null, stop the connector, drop the slot, and resume (with `snapshot.mode: no_data` it streams from now). |
| No Debezium topics | Check `KafkaConnect` cluster Ready; check connector `state`; ensure publication/slot created (locally via `publication.autocreate.mode: filtered`, on Nexus by the platform — see §3.1). |
| `publication "cdc_pub" does not exist` | `publicationAutocreateMode: disabled` but the platform has not declared the publication on this cluster yet, or `publicationName` does not match their `publications[]` entry. |
| Connection validation fails, `password must be at least 112 bits` | FIPS provider in the Connect image; the role's password is under 14 characters. Rotate it — see §3.1. This rotates the app credential too. |
| Replication connection refused / not supported | Connector pointed at the pooler instead of the CNPG primary. Confirm `postgres.cluster.name` is set so the host resolves to `<cluster>-rw`. |
| `failover = false` on the slot | Slot pre-dates `slot.failover`, or the target is not a PG17+ primary. Drop the slot and let the connector recreate it (forces a re-snapshot). |
| Task failed on heartbeat/schema topic | SMT chain uses an `isData` predicate — data topics only. If tasks still fail, check connector logs for transform errors on non-data records. |
| Missing `ce_*` headers | Stale Connect image missing `kairos-connect-smt.jar`; reinstall `kafka-connect` so the OCI image is current, and confirm the connector uses `com.kairos.connect.transforms.MasterDataCdcTransform$Value`. |
| Value is `{id,data}` string wrapper | Same — old SMT chain; reinstall the Connect image and force-reconcile the connector. |
