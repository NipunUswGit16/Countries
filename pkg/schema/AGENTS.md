# Message Schema Guidelines

This directory holds the component's public message contracts: commands (`*CommandV1`), events (`*EventV1`), command responses (`*CommandResponseV1`), and master data entities (under `masterdata/`).

**Master data (producer):** Invoke `kairos-create-masterdata-entity` when your component **owns** reference data replicated via CDC. Walkthrough: [`docs/cdc/debezium/ADDING-MASTERDATA-ENTITIES.md`](../../docs/cdc/debezium/ADDING-MASTERDATA-ENTITIES.md). Envelope contract: [`docs/cdc/debezium/MASTERDATA-CDC-MECHANISM.md`](../../docs/cdc/debezium/MASTERDATA-CDC-MECHANISM.md). Types live in `masterdata/`.

## Rules that apply to every schema

Every schema file: kebab-case name, `camelCase` JSON tags (matches the JSONB rule in the root `AGENTS.md`), compile-time `var _ messaging.X = ...` interface assertion, mandatory `Validate(ctx context.Context) error`, mandatory `ComponentName() string`. For templates and rationale, invoke the matching `kairos-create-{command,event,command-response,masterdata-entity}` skill.

## Versioning Policy

This package is a **public contract** — other Kairos components import it to consume our commands, events, command responses, and master data. Breaking it silently breaks them.

### The rule

- **Never make breaking changes to an existing `V{N}` schema.** Backward-compatible evolution of the same version is fine.
- **Breaking change** = any change that would cause an existing consumer on the published version to fail: removing a field, renaming a field, changing a field's type, tightening validation, changing semantics.
- **Non-breaking changes** are allowed in place: adding an optional field with `omitempty`, relaxing validation, documentation/comment edits.
- **When in doubt, ask the user.** Some changes look additive but shift semantics (e.g. adding a field that existing producers won't set, where consumers must guess the meaning of its absence). If you can't confidently place a change in the table below, stop and ask.

V1 is always the initial version. Don't over-engineer V1 trying to anticipate every future breaking change — just ship it. When a breaking change genuinely arises later, create V2 and run them in parallel as described below.

### When a breaking change is needed

1. **Add a new `V{N+1}` type** (new file: `{entity}-{action}-{kind}-v{n+1}.go`, new Go type `{...}V{N+1}`). Do **not** modify the existing one.
2. **Mark the previous version as deprecated** in its Go doc comment using the standard Go `// Deprecated:` convention so any downstream consumer sees a compiler/`staticcheck`/IDE warning:

   ```go
   // OrderCreatedEventV1 announces that an order has been created.
   //
   // Deprecated: use OrderCreatedEventV2 instead. V1 will be removed after
   // <date or release>. V1 and V2 are both being produced during the transition.
   type OrderCreatedEventV1 struct { ... }
   ```

3. **Produce both versions in parallel** for the transition period:
   - **Events**: publish both `V1` and `V2` side-by-side so subscribers on either version keep working. Emit them with the same partition key.
   - **Commands**: accept both `V1` and `V2` on the receiving side (register handlers for both types). The sender side can migrate at its own pace.
   - **Command responses**: reply in the same version as the incoming command so the original caller still understands the reply.
   - **Master data**: publish both; subscribers opt in by mapping the version they want.
4. **Communicate the deprecation** in `CHANGELOG.md` and in the commit message. Downstream consumers pick up the `// Deprecated:` tag automatically when they bump the module.
5. **Remove `V{N}` only after all consumers have migrated.** Deletion is itself a breaking change; coordinate it explicitly.

### What counts as a breaking change — quick reference

| Change | Breaking? |
|---|---|
| Add optional field with `omitempty` | ❌ no |
| Add required field | ✅ yes |
| Remove any field | ✅ yes |
| Rename any field | ✅ yes |
| Change field's Go type (including `int` → `int64`) | ✅ yes |
| Relax validation | ❌ no |
| Tighten validation | ✅ yes |
| Change semantic meaning of an existing field | ✅ yes |
| Change the `ComponentName()` return value | ✅ yes |
| Doc comment / `// Deprecated:` marker | ❌ no |
