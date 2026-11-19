---
name: kairos-use-cli
description: Discovers and uses the Kairos CLI by invoking its built-in help system (kairos --help, kairos <cmd> --help) rather than relying on hard-coded command syntax. Covers local cluster setup, installing platform services, scaffolding new components and facades, installing or promoting a component, updating the skills pack, token retrieval, and developer tool installation. Use when setting up a local Kairos environment, creating a new component or facade, installing a component onto the local cluster, promoting a schema repo or facade, updating skills, managing clusters, obtaining auth tokens for local testing, installing developer tooling, or when the user says "kairos cluster", "kairos component create", "kairos component facade", "kairos component promote", "kairos skills update", "kairos token", "kairos tools", or "how do I set up Kairos locally?".
---

# Kairos CLI

The Kairos CLI (`kairos`) is the primary developer tool for the platform. **Never rely on memorized command syntax** — the CLI ships comprehensive `--help` for every command and subcommand, and it evolves between releases. `--help` is the authoritative, in-sync source.

## Discovery workflow

```bash
kairos --help                          # top-level command groups
kairos <group> --help                  # subcommands in that group
kairos <group> <subcommand> --help     # flags, defaults, examples
```

Drill from general to specific until you have the exact flags and arguments. Never guess flag names or short forms — copy them directly from `--help` output.

## What the CLI does (task → command group)

| Task | Start with |
|---|---|
| Create / list / delete local clusters | `kairos cluster --help` |
| Install or list platform services (PostgreSQL, Redpanda, …) | `kairos cluster services --help` |
| Scaffold a brand-new component from this template | `kairos component --help` → `create` |
| Scaffold a master-data facade (schema + tenant jobs, no runtimes) | `kairos component facade --help` |
| Install an existing component onto the local cluster (optionally keeping its code) | `kairos component install --help` |
| Promote a schema repo to a facade, or a facade to a component | `kairos component promote --help` |
| Install or update the skills pack in a component (`.agents/skills/`) | `kairos skills --help` |
| Obtain an auth token for local API calls | `kairos token --help` |
| Install developer tools (`kafkactl`, `k9s`, `jq`, `yq`, …) | `kairos tools --help` |

If a task doesn't obviously match one of these groups, start with `kairos --help` to find the right one.

## Typical flows (discovered via `--help`)

These are high-level flows, not memorized commands. Fill in the exact syntax from `--help`.

### Fresh local environment

1. Create a cluster (`kairos cluster --help` → `create`).
2. Install `postgres` and `redpanda` (`kairos cluster services --help` → `install`). Every Kairos component needs both.
3. Verify (`kairos cluster services --help` → `list`).

### Scaffolding a new component

1. Run `kairos component --help` to see the `create` subcommand and its target-directory options.
2. After scaffolding:
   - [ ] No remaining placeholders (`<YOUR_COMPONENT_NAME>`, `<COMPONENT_NAME>`).
   - [ ] If the check in `../using-kairos-skills/reference/facade.md` says facade: there are no `+kairos:sql:lib:` directives, so skip the next item; once a master-data entity exists, `make generate` writes `chart/resources/masterdata-entities.json`. Otherwise (app component): do the next item.
   - [ ] Both `+kairos:sql:lib:` directives intact — `eventsender` in `cmd/client-api/main.go` and, if `cmd/integration-api/main.go` exists, there too (otherwise skip that file; do not create it); `event-handler` in `cmd/event-handler/main.go`.
   - [ ] `make generate && make build-all && make test` all succeed.

`jq` and `yq` are required by `make generate` only when `internal/integration-api/openapi.go` exists (OpenAPI generation; `kairos tools install jq yq`). Otherwise they are optional.

`make test` does not need the local cluster: unit tests use mocks, and functional tests start their own PostgreSQL in Docker. The cluster is for running and deploying the component.

### Obtaining a token for local API testing

1. `kairos token --help` → identify the `get` subcommand, then see `kairos token get --help` for how it selects audience/subject (flags or prompts).
2. Pass the returned token as `Authorization: Bearer <token>` when calling component APIs.

## Common mistakes (RED FLAGS)

- Guessing flag names (especially short forms like `-a`, `-s`) instead of reading `--help`.
- Creating a cluster just to run `make test` → tests don't use it; only running or installing the component does.
- Mismatched audience vs. target API when issuing tokens → 401/403 responses.
- Re-running a cluster-create command after a failure without checking `kairos cluster --help` for an idempotent update path.
