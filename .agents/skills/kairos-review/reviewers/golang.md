# Go Reviewer Rules

Apply only to `.go` files. Report only demonstrably real bugs or production risks.

**Each bullet below is an anti-pattern. Flag any code in the diff that matches.** The section header is the category for the finding.

## ERROR_HANDLING

- Error returned from a function call is not checked
- Error return value discarded (assigned to `_` or implicitly dropped) without a comment explaining why the error is safe to ignore — applies to both `_ = fn()` and `x, _ := fn()` forms
- Error returned without context where the call chain is non-obvious to the caller — adds friction to debugging; wrap with `fmt.Errorf("operation: %w", err)` at non-trivial layers
- `errors.Is` / `errors.As` checked against a sentinel or type that is never wrapped into the returned error chain — always returns false
- Sentinel errors compared with `==` instead of `errors.Is`
- Panic used in library code (not `main` or test) without recovery — propagates to callers unexpectedly

## GOROUTINE_LEAK

- Goroutine launched with no clear exit path (no `ctx.Done()`, no done channel, no WaitGroup completion)
- Goroutine spawned inside a loop with no bound on concurrency — unbounded goroutine count
- Channel send or receive in a goroutine whose lifecycle is decoupled from the channel's other end (no shared cancel, context, or done channel) — leaks if the other end disappears
- `sync.WaitGroup.Add` called inside the goroutine instead of before launching it — race between Add and Wait
- Goroutine closes over a loop variable without capturing it — all goroutines share the final value (only flag in modules with `go 1.21` or earlier; Go ≥1.22 fixes loop-var semantics)

## POINTER_SEMANTICS

- `&v` taken inside `for _, v := range ...` — points to the per-iteration value copy, not the underlying element; only flag in modules with `go 1.21` or earlier (Go ≥1.22 fixes this)
- Pointer receiver on a type that is always copied (small value type with no mutation intent) — misleads callers
- Value receiver on a type with a mutex or large buffer — copies the lock / wastes memory on every call
- Returning `*T` for a small immutable struct where returning `T` would suffice — adds GC pressure with no benefit
- `new(T)` used where the type's zero value is invalid (the type requires a constructor for correct initialisation) — silently produces an unusable value

## HEAP_ESCAPE

- Large struct (>128 bytes) passed by value in a hot path — unnecessary copy per call
- Interface conversion of a concrete value in a tight loop — boxes to heap on every iteration
- Slice grown with `append` inside a loop where the final size is known — repeated reallocation; `make([]T, 0, n)` should be pre-allocated
- String concatenation with `+` inside a loop — allocates a new string per iteration; use `strings.Builder`
- `fmt.Sprintf` used purely for string conversion where `strconv` would avoid allocation

## CONTEXT_PROPAGATION

- Function accepts a `context.Context` but it is not the first parameter — violates Go convention, breaks linters
- `context.Background()` or `context.TODO()` created and used inside a non-main, non-test function — context from caller is not threaded through
- Context stored in a struct field — context is request-scoped, not object-scoped; should be passed as a parameter
- `context.WithCancel` created but cancel function never called — leaks resources until parent cancels
- Timeout or deadline set with `context.WithTimeout` but the cancel is not deferred — deadline applies but resources are not released promptly

## DEFER_IN_LOOP

- `defer` inside a `for` or `range` loop — defers accumulate until the enclosing function returns, not the end of each iteration
- Common impact: file handles, database rows, mutexes, HTTP response bodies held open for the lifetime of the function instead of each loop iteration
- Correct pattern: extract the loop body into a named function and defer inside that

## CONCURRENCY

- Shared variable accessed from multiple goroutines without synchronisation (no mutex, no atomic, no channel)
- `sync.Mutex` or `sync.RWMutex` copied after first use — lock state is not copied safely
- `sync/atomic` used on a non-aligned 64-bit value on 32-bit platforms
- `time.Sleep` used to synchronise goroutines — non-deterministic; use channels or WaitGroups
- `map` written from multiple goroutines without a lock — concurrent map writes panic at runtime

## RESOURCE_MANAGEMENT

- `http.Response.Body` not closed after use — leaks the underlying TCP connection
- `sql.Rows` not closed after iteration — leaks the database cursor
- `os.File` opened but not closed (or close not deferred)
- `io.Reader` / `io.Writer` passed to a function that may not drain it — causes blocked goroutines on pipe/network sources
- `ticker.Stop()` not called when a `time.Ticker` is no longer needed — goroutine and resources leak

## TEST_QUALITY (flag only in `_test.go` files)

- `t.Fatal` / `t.FailNow` / `t.SkipNow` called from a goroutine spawned inside the test — only exits the spawning goroutine; the test continues and may not fail correctly. Use `t.Errorf` with synchronisation back to the test goroutine
- Test relies on `time.Sleep` for synchronisation instead of channels or `sync.WaitGroup`
- Table-driven test captures loop variable in subtest closure — all subtests run with the final value (only flag in modules with `go 1.21` or earlier)
