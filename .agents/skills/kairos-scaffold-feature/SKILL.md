---
name: kairos-scaffold-feature
description: Scaffolds an end-to-end Kairos feature — domain entity, repository, service, per-runtime ServicesFactory wiring, API endpoint with routes, event-handler command/event handlers with registration, plus tests — by orchestrating the individual Kairos skills in the correct order. Use for a full new feature slice or initial component build-out, when the user says "scaffold a new feature", "add end-to-end feature", "bootstrap component feature", or "big initial component scaffold".
---

# Scaffold a Full Kairos Feature

Meta-skill that orchestrates the other Kairos skills to build a complete vertical slice — domain → persistence → schemas → service → config → API → handlers → tests — in the correct order. For any smaller slice, jump directly to the specific skill instead.

## Before you start

If the check in `../using-kairos-skills/reference/facade.md` says this component is a facade, stop: this skill does not apply to a facade, and that file says which skills do.

## Workflow

Copy this checklist into your working notes and tick items as you go. Each numbered step delegates to a dedicated skill — read that skill before executing the step. Steps marked *(integration API)* apply only if `test -f cmd/integration-api/main.go` succeeds; otherwise skip them.

```text
Scaffold Progress:
- [ ] 1. Domain entity        → skill: kairos-create-domain-entity
- [ ] 2. Repository           → skill: kairos-create-repository
- [ ] 3. Message schemas the service will publish or send
     - [ ] Event              → skill: kairos-create-event
     - [ ] Command            → skill: kairos-create-command (schema now; its handler in step 8)
     - [ ] Command response (if request-reply) → skill: kairos-create-command-response
- [ ] 4. Service              → skill: kairos-create-service
- [ ] 5. ServicesFactory wiring in every runtime that calls the service: internal/api,
       internal/event-handler, internal/integration-api (integration API) → in service skill
- [ ] 6. Config updates (AppConfig: timeouts, feature flags, external endpoints)
       → skill: kairos-configure-appconfig
- [ ] 7. API endpoint(s) + route registration → skill: kairos-create-api-endpoint
       (paginated list → kairos-create-paginated-endpoint)
       routes in internal/api/routes.go, or internal/integration-api/routes.go (integration API)
- [ ] 8. Event-handler handlers + registration in internal/event-handler/handlers.go
     - [ ] Command handler    → skill: kairos-create-command
     - [ ] Event handler      → skill: kairos-create-event-handler
     - [ ] Command response handler (if request-reply) → skill: kairos-create-command-response-handler
- [ ] 9. Run `make generate`  → skills: kairos-sql-lifecycle (SQL half) + kairos-topic-subscriptions (topic half)
- [ ] 10. Commit the generated files (see § Generated files)
- [ ] 11. Tests
     - [ ] Service tests      → skill: kairos-test-service
     - [ ] Endpoint tests     → skill: kairos-test-api-endpoint
     - [ ] Handler tests      → skill: kairos-test-event-handler
     - [ ] Functional scenarios for the new endpoints and messages
           → skills: kairos-test-functional-client-api, kairos-test-functional-event-handler
- [ ] 12. Run `make lint ARGS=--all` and `make test ARGS=--all` and fix issues
       (off `main`, without `ARGS=--all` they check committed changes only)
```

## Dependencies between steps

```text
1. Domain entity ─► 2. Repository ─┐
3. Schemas ────────────────────────┴─► 4. Service ─► 5. ServicesFactory ─┐
6. Config ───────────────────────────────────────────────────────────────┴─► 7. Endpoints
                                                                            8. Handlers ─► 9. make generate ─► 11. Tests
```

Steps 1 and 3 can run in parallel; everything from step 4 on depends on both. Config comes before the entry points because endpoint and handler code reads the new fields.

## Generated files

`make generate` writes these; commit each one that the component has. `<chart>` is `charts/` if that directory exists, otherwise `chart/`.

| Output | Written when |
|---|---|
| `sql/0.libs/`, `sql/1.gen/`, and the SQL SHA in `<chart>/templates/db-script-runner.yaml` | always |
| `<chart>/resources/topic-config.json` | always |
| `pkg/json-schema/` | always |
| `<chart>/resources/component-config.json`, `pkg/asyncapi/asyncapi.yaml` | `go list -m -f '{{.Version}}' bitbucket.org/ifs-pd/kairos-component-common/toolkit` ≥ v1.0.49 |
| `internal/integration-api/loaders/generated/` | `test -d internal/integration-api/loaders/generated` |
| `pkg/openapi/openapi.{json,yaml}` | `test -f internal/integration-api/openapi.go` |
| `<chart>/resources/masterdata-entities.json` | the feature adds owned master data (see `kairos-create-masterdata-entity` for when the descriptor is written) |

Commit nothing else that `make generate` happens to touch without checking why it changed.

## Final quality gate

Before considering the feature done, verify:

- [ ] No remaining template placeholders (`<YOUR_COMPONENT_NAME>`, `<COMPONENT_NAME>`)
- [ ] All PostgreSQL queries go through tenant-scoped sessions
- [ ] No hardcoded secrets or tokens
- [ ] Structured logging on every significant branch
- [ ] Test coverage ≥ 80% (enforced by CI)
- [ ] `make generate` run and output committed
- [ ] `make lint ARGS=--all` passes
- [ ] `make test ARGS=--all` passes (it includes `make test-functional`)
