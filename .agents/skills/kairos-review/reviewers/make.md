# Makefile Reviewer Rules

Apply only to `Makefile`, `makefile`, and `GNUmakefile` files. Report only demonstrably real bugs or production risks.

**Each bullet below is an anti-pattern. Flag any code in the diff that matches.** The section header is the category for the finding.

## PHONY

- Target that does not produce a file (e.g. `build`, `test`, `clean`, `run`, `lint`) missing `.PHONY` declaration — if a file with that name exists in the directory, Make silently skips the target, treating the file as up-to-date
- `.PHONY` declared for a target that actually produces an output file — defeats Make's dependency tracking; target always runs regardless of whether the output is fresh

## SHELL_SAFETY

- Multi-command recipe where a failure in an early command does not abort the recipe — each line runs in a separate shell; `cmd1 && cmd2` or `.SHELLFLAGS = -ec` needed if subsequent lines depend on earlier success
- Unquoted variable used in a shell context inside a recipe — same word-splitting and injection risks as in bash scripts
- `$(shell ...)` function used in a recipe instead of just running the command — runs at parse time, not recipe time; result is baked in before any targets are evaluated
- Recursive `$(MAKE)` call without `-C` or explicit target — may re-enter the same Makefile and loop or produce unexpected results

## VARIABLE_EXPANSION

- `=` (recursively expanded) variable that references itself — infinite recursion at expansion time; use `:=` (simply expanded) for variables built from other variables
- `:=` used for a variable whose value must be deferred until recipe execution (e.g. depending on a generated file) — value is computed too early
- `?=` default overridden unintentionally by an environment variable of the same name — `?=` sets only if the variable is not already set, including from the environment
- Variable referencing an undefined variable — expands to empty string silently; can cause `rm -rf` of the wrong path

## DEPENDENCY_CORRECTNESS

- Target depends on a file that is produced by another target but that target is not listed as a prerequisite — parallel builds (`-j`) can run targets out of order and fail non-deterministically
- Circular dependency between targets — Make detects this and errors, but flag it early
- Wildcard prerequisite (`%.o: %.c`) with no pattern rule body — Make silently ignores the target
- `FORCE` or empty prerequisite used to always rebuild a target that has a real output file — defeats incremental builds; every run rebuilds everything

## PARALLELISM

- Global state written to a shared file without a lock in a recipe that runs under `make -j` — concurrent writes corrupt the file
- `$(MAKE) -j` called recursively with no job server flag (`+$(MAKE)`) — child make does not participate in the parent's job limit; oversubscribes CPUs

## PORTABILITY

- GNU Make-specific features (`$$`, `$(eval ...)`, `$(call ...)`, pattern-specific variables) used in a project that targets BSD Make or POSIX make — fails on macOS `make` without Homebrew's `gmake`
- Tabs replaced with spaces in a recipe line — Make requires tabs; some editors silently convert them
- Absolute path hardcoded in a recipe — breaks when the project is cloned to a different location
