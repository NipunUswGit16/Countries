# Facade check

A **facade** is a component created with `kairos component facade create` (or `kairos component promote` from a schema repo). It ships only:

- a master-data schema module, `pkg/schema/` (owned `*EntityV1` types under `pkg/schema/masterdata/`), and
- the `command-publisher` job: `cmd/command-publisher/Dockerfile` plus the chart's `TenantJobConfiguration` (`chart/`).

It has no `internal/`, no `cmd/*/main.go`, no `sql/` and no `web/`.

## The check

Run in the component root:

```bash
grep -E '^[[:space:]]+(kind:[[:space:]]*facade|repo:.*facade)' .kairos/manifest.yaml
```

| Result | Meaning |
|---|---|
| matches | Facade. `.kairos/manifest.yaml` has `template.kind: facade` (the Kairos CLI stamps it from 0.3.35), or its `template.repo` names a facade template (manifests written by older CLIs). |
| no match, or no manifest | Not a facade. Route as normal. |

The manifest is the only input. `.init.mk` settings (`GENERATE_MODULES`, `MASTERDATA_INCLUDE_NO_CDC`) and the file tree are not kind markers: they are valid in any component.

## Skills that apply in a facade

- `using-kairos-skills` (the router)
- `kairos-create-masterdata-entity`
- `kairos-go-developer`
- `kairos-review`
- `kairos-use-cli`
- `kairos-component-update`
- `explain-diff-html` and `using-explain-diff` (not Kairos-specific)

Every other skill stops at its `## Before you start` and tells the author: this skill does not apply to a facade; master data goes through `kairos-create-masterdata-entity`; an application runtime belongs in a component (`kairos component promote --help`).

`kairos-component-update` keeps its own scripted detection (`scripts/lib/component-kind.sh`) because it must also classify a tree that has no manifest yet (bootstrap).
