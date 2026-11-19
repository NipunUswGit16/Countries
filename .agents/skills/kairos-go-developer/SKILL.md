---
name: kairos-go-developer
description: Go idioms and house style for Kairos components — error wrapping, context discipline, concurrency lifecycle, struct/pointer choices, GC-aware allocation, testability, and imports. Use alongside (not instead of) the structural kairos-* skills when writing or refactoring Go inside this repo. Triggered by "write Go code", "refactor Go code", "clean up this Go", or general Go style questions in a Kairos component.
---

# Kairos Go Developer

A **style skill** for idiomatic Go inside a Kairos component. It covers the language-level conventions the structural skills assume but do not repeat: naming, error handling, context, concurrency, allocation, and testability.

## Interaction with other skills

This skill is **subordinate** to the `kairos-*` structural skills. On any conflict, the structural skill wins.

- For anything involving domain entities, repositories, services, API endpoints, commands, events, responses, handlers, master data, `AppConfig`, SQL, or topics, invoke the relevant `kairos-*` skill **first** (see `using-kairos-skills`). This skill only governs Go-language idioms *inside* the code those skills tell you to write.
- Do **not** use this skill as justification to skip `kairos-create-repository`, `kairos-create-service`, `kairos-create-api-endpoint`, etc. "I wrote clean Go" is not a substitute for the platform contract (JSONB camelCase, package-level `const tableName` per repository, `ServicesFactory` mirroring, double validation, ETag handling, etc.).
- When this skill's generic advice (e.g. "define interfaces at the consumer site") conflicts with a concrete Kairos pattern (e.g. repository interfaces live in `internal/repositories/` and are consumed via `ServicesFactory`), follow the Kairos pattern.

## Naming and shape

- Simplicity over cleverness. Straightforward, readable code beats clever abstractions.
- **Accept interfaces, return structs.** Accept small, standard interfaces (`io.Reader`, `context.Context`, the consumer-defined repository interface) and return concrete types.
- Short, descriptive locals: `req`, `res`, `err`, `ctx`, `id`, `tx`.
- MixedCaps (CamelCase) for both exported and unexported identifiers. No snake_case in Go identifiers.
- Package names: short, lowercase, single-word, no underscores, no plurals.
- Guard clauses and early returns to reduce nesting.
- Design structs so the zero value is useful where possible.

## Error handling (critical)

- Always check errors explicitly. Never `_ = err` without a comment justifying it.
- Wrap errors with context as they bubble up:

  ```go
  if err := repo.GetOrder(ctx, id); err != nil {
      return fmt.Errorf("get order %s: %w", id, err)
  }
  ```

- Never `panic` in library or request-handling code. Return errors. `panic` is acceptable only for truly unrecoverable initialization (e.g. failed config parse at startup).
- Prefer `errors.Is` / `errors.As` over string matching to inspect wrapped errors.

## Context discipline

- Always take `ctx context.Context` as the **first** parameter on any function that does I/O, network, DB, or long work.
- Respect `ctx.Done()` — honour cancellation and deadlines.
- **Never** store `context.Context` in a struct field.
- Derive contexts from the incoming one. Do not create `context.Background()` or `context.TODO()` mid-flow.
  - **Exception:** cleanup that must outlive a cancelled parent (e.g. graceful shutdown releasing connections) may derive a new context from `context.Background()` with its own deadline.
- Always `defer cancel()` immediately after `context.WithTimeout` / `WithCancel` / `WithDeadline`.

## Concurrency

- Share memory by communicating — prefer channels for synchronization and data transfer between goroutines. Use `sync.Mutex` / `sync.RWMutex` only for simple shared state.
- Never start a goroutine without knowing how it stops. Use `sync.WaitGroup` (or an `errgroup.Group`) so callers can wait.
- Goroutines launched from a request handler must observe `ctx.Done()` so they don't outlive the request.
- No fire-and-forget goroutines in handler code — they leak on shutdown and break at-least-once delivery semantics.

## Resource cleanup

- Use `defer` to release resources: files, rows, connections, locks, response bodies, goroutine wait groups.
- Close `pgx.Rows` and HTTP response bodies before returning, even on error paths.
- For cleanup that needs to run after the parent context is cancelled, derive a new `context.Background()`-rooted context with a short deadline (the valid exception to "derive, don't create").

## Structs and pointers

- **Pointer receivers** when the method mutates the receiver or the struct is large. Be consistent within a single type — don't mix value and pointer receivers on the same struct.
- Pass by value by default. Use pointers only to mutate or to avoid copying large structs.
- Do not take pointers to slices or maps — they are already reference types.

## Performance and GC awareness

- When the output slice has the same length as a source slice (one-to-one transform), use `out := make([]T, len(src))` and assign `out[i] = ...` in the loop.
- Use `make([]T, 0, cap)` with `append` only when the final length is unknown or may be shorter than the input.
- Use `sync.Pool` for frequently-allocated short-lived objects in hot paths (serialization buffers, scratch byte slices).
- Prefer value types and stack allocation for small, short-lived structs. Unnecessary pointer indirection forces heap escape.
- Avoid closures that capture variables from a large enclosing scope — captured variables escape to the heap.
- Reuse buffers (`bytes.Buffer`, `[]byte`) across calls in hot paths instead of allocating new ones.
- Use `strings.Builder` or `bytes.Buffer` for string building in loops; avoid repeated `+` concatenation.
- `fmt.Sprintf` is fine for one-off formatting; in tight loops prefer `strconv` or direct `[]byte` manipulation.

Treat all of the above as situational — optimize only with a benchmark or profile in hand. Correctness and readability first.

## Design for testability

- Define **consumer-side** interfaces (the caller declares what it needs) for non-Kairos dependencies. Keep them small, 1–3 methods.
  - **Kairos exception:** repository interfaces in this repo live with the repository in `internal/repositories/` and are wired into services via `ServicesFactory`. Follow the `kairos-create-repository` / `kairos-create-service` pattern, not the consumer-site rule.
- Accept dependencies through constructor parameters or an options struct. Avoid package-level globals that can't be substituted in tests.
- Keep functions pure (side-effect-free) where possible — pure functions are trivially testable.
- Use the functional options pattern (`func WithX(v T) Option`) for constructors that need flexible, extensible configuration.

## Standard library and dependencies

- Prefer the Kairos common libraries (`nga-common`, the platform's logger, messaging, and persistence abstractions) and the Go standard library before reaching for new third-party packages.
- Check `AGENTS.md` and the relevant `kairos-*` skill before adding a dependency — HTTP, logging, messaging, and persistence are already opinionated.
- A little copying is better than a little dependency. Don't pull in a transitive tree for trivial functionality.

## Code structure and formatting

- Group imports in three blocks separated by blank lines:
  1. standard library
  2. external packages
  3. internal / project packages

  `goimports` arranges this automatically — run it.
- Avoid `init()` functions unless strictly necessary (e.g. driver registration). Prefer explicit initialization from `main` or a constructor.
- Apply `gofmt` / `goimports` formatting (tabs for indentation, standard import grouping).

## Validation — after writing or modifying Go

Run the repo-standard incantation from `AGENTS.md` § "After Completing Work":

```bash
make generate   # only if schemas, handlers, SQL, or topic subscriptions changed
make lint
make test
```

`make generate` is also due after a change to a struct that embeds `entities.EntityBase` or `entities.MasterDataEntityBase`, to a `+kairos:` directive, or — if `internal/integration-api/openapi.go` exists — to the swag annotations on an integration-API endpoint (they produce `pkg/openapi/`).

`make lint` invokes the project's linter suite (which includes `go vet` and more). Do not declare work complete until all three succeed. If a `kairos-*` skill you invoked has its own checklist, every item on that checklist must also be ticked before `make lint` / `make test` are trusted as sufficient.
