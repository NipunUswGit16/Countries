# YAML Reviewer Rules

Apply to general `.yaml` / `.yml` files not covered by kubernetes.md or helm.md (e.g. CI/CD pipelines, config files, GitHub Actions, GitLab CI). Report only demonstrably real bugs or production risks.

**Each bullet below is an anti-pattern. Flag any code in the diff that matches.** The section header is the category for the finding.

## TYPE_COERCION

- Unquoted boolean-like strings: `yes`, `no`, `on`, `off`, `true`, `false` used as values where a string is expected — YAML 1.1 parsers coerce these to booleans silently (e.g. country code `NO` becomes `false`)
- Unquoted numeric string: a value like `001` or `08` that is intended as a string but parsed as an integer — leading zeros are lost (`SKU: 0001` becomes `1`)
- Unquoted version string: `version: 1.10` parsed as float `1.1` — use `version: "1.10"`
- Null coercion: bare `~` or empty value used where a specific type is required — parsed as `null`

## DUPLICATE_KEYS

- Duplicate key at the same mapping level — behaviour is parser-defined; most parsers silently use the last value, but the first definition is lost

## ANCHORS_AND_ALIASES

- Anchor (`&name`) defined but the alias (`*name`) is never used — dead anchor, misleads readers
- Alias (`*name`) used on a mapping that is then overridden with `<<:` merge — if the alias value changes, the merge result changes silently
- Deep anchor nesting that makes the effective value non-obvious — not a bug but flag if it hides a production value

## CI_CD_SPECIFIC (GitHub Actions / GitLab CI / Bitbucket Pipelines)

- `uses: owner/action@main` or `uses: owner/action@master` — mutable ref; action can be changed without notice; pin to a commit SHA
- `uses: owner/action` with no version at all — defaults to latest
- Secret passed as an environment variable to a step that runs untrusted code or a third-party action — secret exfiltration risk
- `run:` step that interpolates `${{ github.event.*.body }}` or similar user-controlled input directly into a shell command — command injection
- `permissions: write-all` or no `permissions` block (defaults to write on older repos) — over-permissioned workflow token
- `pull_request_target` trigger combined with checkout of the PR branch and code execution — allows fork PRs to run with repo secrets
- Self-hosted runner used for a public repo — untrusted PRs can execute code on your infrastructure
- `continue-on-error: true` on a critical step — failures are silently ignored; pipeline reports success on broken state

## INDENTATION_AND_STRUCTURE

- Mixed tabs and spaces — YAML forbids tabs; some parsers accept them silently, others fail
