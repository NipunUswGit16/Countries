---
name: kairos-topic-subscriptions
description: Reference for the Kairos topic-subscription generation pipeline — how `kairos-gen` (invoked via `make generate`) scans for references to foreign `pkg/schema` event types and `eh.Sync(MasterData[…])` registrations to produce `chart(s)/resources/topic-config.json` and `component-config.json` (the chart folder is named `chart/` in newer templates and `charts/` in older ones). Covers which packages are scanned, the JSON shapes (events grouped by component, master-data individual topics, the pure-producer scaffold), what commands and command responses produce (nothing in topic-config), and topic-related troubleshooting (topic not appearing, wrong component name, duplicates). Use when reasoning about Kafka topic subscriptions, configuring or debugging `topic-config.json`, registering master-data topics, or when the user says "regenerate topics", "fix topic-config", "topic not appearing", or "subscription is wrong".
---

# Topic-Subscription Lifecycle (kairos-gen)

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

Reference for the topic-subscription half of the Kairos code generator. `kairos-gen` keeps `chart(s)/resources/topic-config.json` in sync with the foreign schema types your Go code references and the master-data sync registrations. Run it on demand with `make generate`; it also runs as part of `make build-all`, the pre-commit hook (`make install-hooks`), and CI.

> **Chart folder name.** Newer templates use `chart/` (singular); older templates use `charts/` (plural). The skill writes `chart(s)/` throughout — substitute whichever folder exists in the repo you're working in. The contents and path under the folder (`resources/topic-config.json`) are identical.
> `make generate` runs `kairos-gen`, which also produces SQL migrations. This skill covers the topic half. For the SQL half (`sql/0.libs/`, `sql/1.gen/`, `+kairos:sql:` directives, generated tables), see `kairos-sql-lifecycle`.

Two versions decide what happens. Read them in the component root:

- **toolkit**: `go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/toolkit`.
- **kairos-gen**: if `go.mod` has a `cmd/kairos-gen` line, `go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/cmd/kairos-gen`. Otherwise the generator is the unpinned binary on `PATH`: run `kairos-gen --version` and treat `(devel)` or a failure as unknown.

## What kairos-gen produces for topics

`chart(s)/resources/topic-config.json` is built by scanning a set of packages for references to types from foreign `pkg/schema` packages, then emitting one entry per producing component (events) or per entity (master data).

- **Events** are detected **by reference**: any use of a foreign `*EventV{N}` type in a scanned package — a handler signature, but also a service or a helper — adds that component's topic.
- **Master data** depends on kairos-gen:
  - ≥ v0.1.0: a master-data topic comes **only** from an `eh.Sync(eventhandler.MasterData[*T]())` registration. A merely referenced type produces nothing.
  - < v0.1.0 or unknown: **any** referenced foreign `pkg/schema` type that is not an event, command or response becomes a master-data topic. Reference foreign helper types (enums, DTOs) only through the event, command or response that carries them.
- **Commands and command responses** produce nothing in `topic-config.json`. A command is consumed on its owner's own topic, and a reply arrives on the requester's own topic.

### Which packages get scanned

| toolkit | Scan set |
|---|---|
| ≥ v1.0.49 | Derived from the apps: `cmd/<app>/` for every `cmd/*/main.go` (excluding `db-script-runner`), plus **all of `internal/`**. A foreign reference anywhere under `internal/` counts. To list the prefixes: `bash "$(go list -m -f '{{.Dir}}' bitbucket.org/ifs-pd/kairos-component-common/toolkit)/scripts/module-prefixes.sh" topic`. |
| < v1.0.49 | Fixed list: `internal/event-handler`, `cmd/event-handler`, `cmd/client-api` (plus `internal/domain` and `pkg/schema`, which hold no foreign references in practice). A foreign type referenced only from `internal/api/` or `internal/services/` produces **no** topic, so keep the reference in an event-handler file. `module-prefixes.sh` does not exist. |

### Events grouped by component

```json
{
  "tenantInputTopics": [
    {
      "inputTopic": "order-service",
      "types": [
        "order-service.order-created.1",
        "order-service.order-updated.1"
      ]
    }
  ],
  "outputTopic": "my-component"
}
```

### Master data entities (individual topics)

Each master-data entity gets its own dedicated topic — they are **not** grouped under the producing component.

```json
{
  "tenantInputTopics": [
    {
      "inputTopic": "product-service.product.1",
      "types": ["product-service.product.1"]
    }
  ],
  "outputTopic": "my-component"
}
```

### Pure producer (no external subscriptions)

The file keeps one empty scaffold entry so the event relay accepts it:

```json
{
  "tenantInputTopics": [
    {
      "inputTopic": "",
      "types": []
    }
  ],
  "outputTopic": "my-component"
}
```

### component-config.json

If `chart(s)/resources/component-config.json` exists, `make generate` rewrites it (the `component-config` generate module, toolkit ≥ v1.0.49). It is the component's Kafka footprint in one file:

- `ownedTopics` — topics to create for this component: its own topic (`--component-name`, the same value as `outputTopic`) plus one `<component>.<entity-kebab>.<version>` topic per owned master-data type, including entities marked `+kairos:masterdata:no-cdc`. That list is the contract, not a statement that CDC is currently publishing the topic.
- `commandTargetComponents` — foreign components this component sends commands to. Each is a topic it writes without owning. When component A lists B here, B replies onto A's topic; the reply direction is derived from the requesters' files, not listed on the responder.
- `inputTopics` — the topics this component reads. The same `inputTopic` values as `topic-config.json`.
- `referencedComponents` — foreign components this component reads events or master data from, or sends commands to (the union of `inputTopics` owners and `commandTargetComponents`).

If the file is missing, this toolkit does not generate it: skip this section and don't create the file by hand.

## Detection patterns

```go
// Event handler — any reference to the foreign event type adds the producer's inputTopic
func HandlerName(event *externalschema.EventTypeV1, ctx request.Context) error

// Master data sync — registers an individual topic
eh.Sync(eventhandler.MasterData[*externalschema.ProductEntityV1]())

// Command and command-response types — nothing in topic-config.json
// (a foreign command lands in component-config.json commandTargetComponents)
```

The component name in the generated topic comes from each external schema's `ComponentName()` method.

## Troubleshooting

### Topic not appearing in `topic-config.json`

1. Is it an event or a registered master-data type? Commands and responses never appear.
2. Is the foreign type actually referenced (not only imported for a constant), and not hidden behind a local alias type?
3. For master data on kairos-gen ≥ v0.1.0: is it registered with `eh.Sync(eventhandler.MasterData[*T]())`?
4. On toolkit < v1.0.49 only: is the referencing file in the fixed scan list (see § *Which packages get scanned*)? On ≥ v1.0.49 every file under `internal/` is scanned, so don't move references around.
5. Did you run `make generate`?

### Wrong component name in the generated topic

The component name comes from the external schema's `ComponentName()` method. If it looks wrong, you're probably on the wrong version of that component's package — bump it with `go get ...@latest` and re-run `make generate`.

### Duplicate topics

If several places reference the same external event type, `kairos-gen` deduplicates automatically. Expect exactly one subscription per event type. On kairos-gen ≥ v0.1.0, registering two versions of the same master-data entity fails generation; register only the version you consume.

## Rules

- Commit `chart(s)/resources/topic-config.json`, and `chart(s)/resources/component-config.json` if it exists, to version control.
- Never hand-edit `topic-config.json` or `component-config.json` — `make generate` will overwrite them. Change the references, sync registrations or schema instead.
- Re-run `make generate` whenever a handler or a foreign-schema reference is added, removed, renamed, or changes its imported type — even when SQL looks unchanged.
