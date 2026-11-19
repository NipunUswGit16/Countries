# Python Reviewer Rules

Apply only to `.py` files. Report only demonstrably real bugs or production risks.

**Each bullet below is an anti-pattern. Flag any code in the diff that matches.** The section header is the category for the finding.

## ERROR_HANDLING

- `except:` or `except Exception:` with no re-raise and no logging — silently swallows all errors including `KeyboardInterrupt` and `SystemExit`
- `except Exception as e: pass` — exception is captured but discarded entirely
- Catching a broad exception when only a specific one is expected — hides unexpected failures
- `finally` block that can raise — masks the original exception
- Exception message logged but the exception itself not re-raised or handled — caller has no way to know the operation failed

## MUTABLE_DEFAULTS

- Mutable default argument: `def f(x=[])`, `def f(x={})`, `def f(x=set())` — the default object is shared across all calls; mutations persist between invocations
- Default argument that is a mutable object constructed at definition time (e.g. `def f(cfg=Config())`) — same issue

## RESOURCE_MANAGEMENT

- File opened with `open()` without a `with` statement — file handle not closed if an exception occurs
- Database connection or cursor not closed in a `finally` block or `with` statement
- `subprocess.Popen` used without `.wait()` or a context manager — zombie process
- `threading.Lock` acquired without a `with` statement — not released if an exception is raised inside the critical section
- Generator or iterator not fully consumed and not explicitly closed — `GeneratorExit` not raised, `finally` in generator may not run

## ASYNC_MISUSE

- `await` used inside a synchronous (non-`async`) function — `SyntaxError` at parse time; the module won't even load
- Blocking call (`time.sleep`, `requests.get`, file I/O) inside an `async` function — blocks the event loop, starves other coroutines
- `asyncio.run()` called from inside a running event loop — raises `RuntimeError`
- Coroutine created but never awaited or scheduled (`asyncio.ensure_future` / `asyncio.create_task`) — runs but its result and exceptions are silently dropped
- `async for` or `async with` used on a non-async iterator/context manager — `TypeError` at runtime

## TYPE_SAFETY

- `# type: ignore` without an explanatory comment — hides real type errors
- `cast()` from `typing` used without a runtime check — tells the type checker a lie; runtime behaviour unchanged
- `Any` used as a parameter or return type in a typed codebase — infects callers
- Optional value used without a `None` check (e.g. `dict.get(key).method()`) — `AttributeError` at runtime

## CONCURRENCY

- Shared mutable state accessed from multiple threads without a lock — data race
- `threading.Thread` target function that raises an exception — exception is silently swallowed; thread dies without notification
- `multiprocessing` used to share state via global variables — state is not shared across processes; changes are silently lost
- `concurrent.futures.Future` result accessed without checking for exceptions (`.result()` not called, or called without try/except) — exceptions in worker threads are swallowed

## INJECTION_AND_SECURITY

- `subprocess` called with `shell=True` and user-controlled input — command injection
- `eval()` or `exec()` called on external or user-provided input — arbitrary code execution
- `pickle.loads()` on untrusted data — arbitrary code execution
- `yaml.load()` without `Loader=yaml.SafeLoader` — arbitrary code execution via YAML tags
- String formatting used to build SQL queries — SQL injection
