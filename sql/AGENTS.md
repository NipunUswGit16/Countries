# SQL Directory

This directory holds the component's PostgreSQL migrations. It is split into three sub-directories by **who owns the files**:

```
sql/
├── 0.libs/          # Copied from external libraries — DO NOT EDIT
├── 1.gen/           # Generated from Go entities — DO NOT EDIT
└── 3.custom/        # Hand-written migrations — you own these
```

## Ownership and editability

| Directory | Owner | Populated by | Editable? |
|---|---|---|---|
| `0.libs/` | `kairos-gen` | `+kairos:sql:lib:` directives in `cmd/*/main.go` (the two mandatory ones populate `event_outbox` and `idempotency` — see root `AGENTS.md`) | ❌ regenerated on every `make generate` |
| `1.gen/` | `kairos-gen` | Go structs in `internal/domain/` or `pkg/schema/` (incl. `pkg/schema/masterdata/`) embedding `entities.EntityBase[T]` / `MasterDataEntityBase[T]` — one `<table>.sql` per struct | ❌ regenerated on every `make generate` |
| `3.custom/` | You | Hand-written migrations for needs no `+kairos:sql:` directive can express | ✅ |

Edits to `0.libs/` or `1.gen/` are silently overwritten on the next `make generate`. To change the generated output, use a `+kairos:sql:` directive in the Go source — never edit the SQL file.

## Committing generated SQL

`sql/0.libs/*.sql` and `sql/1.gen/*.sql` are **committed to version control**. The pre-commit hook (installed via `make install-hooks`) and CI both run `make generate`, so an out-of-date generated tree fails the build.

## Related

- `kairos-sql-lifecycle` — full generation pipeline, the complete `+kairos:sql:` directive reference (including table-name override `+kairos:sql:table:<name>` and the default `OrderLineItem` → `order_line_items` mapping), and troubleshooting.
- `kairos-create-domain-entity` — adding entities that trigger `1.gen/` output.
