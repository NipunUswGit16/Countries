# Helm Reviewer Rules

Apply only to Helm chart files (`Chart.yaml`, `values.yaml`, `templates/*.yaml`, `templates/*.tpl`). Report only demonstrably real production risks.

**Each bullet below is an anti-pattern. Flag any code in the diff that matches.** The section header is the category for the finding.

## HARDCODED_VALUES

- Image tag hardcoded in a template instead of referenced from `values.yaml` — makes the chart non-reusable and blocks image promotion workflows
- Namespace hardcoded in a template — prevents deploying to multiple namespaces without editing the chart
- Replica count hardcoded — prevents scaling without modifying the chart
- Resource limits/requests hardcoded instead of parameterised — different environments (dev/prod) cannot have different resource profiles

## MISSING_DEFAULTS

- Template variable used without `| default` or `required` and no corresponding entry in `values.yaml` — renders as empty string silently, producing invalid YAML or unexpected behaviour
- `required` used without a meaningful error message — gives the user no indication of what to set
- Boolean flag set via `--set foo=false` is parsed as the string `"false"` rather than the bool `false`; `if .Values.foo` then evaluates to true because `"false"` is a non-empty string. Coerce explicitly with `eq .Values.foo true` or normalise via `| default false`

## NINDENT_MISUSE

- `toYaml | nindent N` used with incorrect indentation level — produces malformed YAML that passes `helm template` but fails at `kubectl apply`
- `toYaml` used without `nindent` or `indent` on a block scalar — leading whitespace is absent, breaking YAML structure
- `tpl` called on a value that itself contains `{{ }}` without sanitising user input — allows chart users to inject arbitrary template directives

## HOOK_ORDERING

- Multiple Helm hooks at the same lifecycle stage (e.g. `pre-install`) without explicit `helm.sh/hook-weight` annotations — execution order is non-deterministic; migrations may run after schema creation hooks
- Hook pod not annotated with `helm.sh/hook-delete-policy: before-hook-creation` — failed hook pod from a previous release blocks re-deployment
- Hook job missing a `ttlSecondsAfterFinished` — completed hook jobs accumulate indefinitely in the cluster

## NAMING_AND_LABELS

- Template not using `include "chart.fullname" .` or equivalent helper for resource names — hard-coded names cause collisions when multiple releases are deployed to the same namespace
- Labels missing `helm.sh/chart`, `app.kubernetes.io/managed-by`, or `app.kubernetes.io/instance` — resources cannot be tracked or cleaned up by Helm
- `Release.Name` used directly in resource names without truncation to 63 chars — names exceeding DNS label limits cause apply failures

## SCHEMA_AND_VERSIONING

- `Chart.yaml` missing `type: application` or `type: library` — defaults to application but intent is unclear; library charts should be explicit
- Dependency declared in `Chart.yaml` without a pinned version (`version: "*"` or absent) — breaking changes in sub-charts are pulled in silently on `helm dependency update`
- `values.yaml` has no `values.schema.json` for a chart intended for external use — no validation of user-provided values; invalid inputs produce cryptic errors

## TEMPLATE_CORRECTNESS

- Inside a `range` loop, `.` is rebound to the current iteration item; using `.Values...` or `.Release...` inside the loop accesses the item, not the chart root — use `$.` (e.g. `$.Values.foo`) to reach the root
- `define` block name clashing with a built-in or dependency template name — silently overrides the upstream helper
