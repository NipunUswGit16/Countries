# kairos-pr-review Reference

## Diff Fetching

### Option A — Bitbucket API

Parse the PR URL: `https://bitbucket.org/{workspace}/{repo_slug}/pull-requests/{pr_id}`

**Auth**: Always use HTTP Basic auth (`-u "$BITBUCKET_EMAIL:$BITBUCKET_TOKEN"`). Bearer auth (`Authorization: Bearer`) does NOT work with Bitbucket's API and returns 401.

```bash
# Get PR metadata (branch name, title, description)
curl -s \
  -u "$BITBUCKET_EMAIL:$BITBUCKET_TOKEN" \
  "https://api.bitbucket.org/2.0/repositories/{workspace}/{repo_slug}/pullrequests/{pr_id}"

# Get the full unified diff (-L follows redirects)
curl -s -L \
  -u "$BITBUCKET_EMAIL:$BITBUCKET_TOKEN" \
  "https://api.bitbucket.org/2.0/repositories/{workspace}/{repo_slug}/pullrequests/{pr_id}/diff"
```

### Option B — Local repo

```bash
git -C {repo_path} fetch origin
git -C {repo_path} diff origin/main...origin/{branch_name}
```

---

## Language & Tech Detection

Map diff file extensions to reviewer files. Read **only** the files relevant to what is present in the diff.

| Extension / Pattern | Reviewer file |
|---|---|
| `.go` | `reviewers/golang.md` |
| `.ts` | `reviewers/typescript.md` |
| `.tsx` | `reviewers/typescript.md` + `reviewers/react.md` |
| `.py` | `reviewers/python.md` |
| `.sh`, `.bash`, no extension + shebang | `reviewers/bash.md` |
| `Makefile`, `makefile`, `GNUmakefile` | `reviewers/make.md` |
| `Dockerfile`, `*.dockerfile` | `reviewers/docker.md` |
| `.yaml`/`.yml` in `chart/` or `charts/`, `templates/`, files named `Chart.yaml` | `reviewers/helm.md` |
| `.yaml`/`.yml` in `k8s/`, `deploy/`, `manifests/`, `config/` | `reviewers/kubernetes.md` |
| `.yaml`/`.yml` (all other) | `reviewers/yaml.md` |

---

## Code Agent

**Role**: Reviews code files for correctness, resource safety, and reliability.
**Receives**: Code-files-only diff slice + list of detected languages and their reviewer file paths.

**Prompt:**

You are an expert code reviewer. Use the Read tool to load each reviewer file listed below — these contain the exact rules to apply. Only load files for languages actually present in the diff. Then analyse the diff and apply only the rules from those files to the matching file types.

For every issue include: file path, line number, severity (CRITICAL/MAJOR/MINOR), category, and a precise explanation of the harm caused. Only report demonstrably real bugs or production risks — not style preferences.

Reviewer files to load (only those relevant):
{list of reviewer file paths detected, e.g. reviewers/golang.md, reviewers/typescript.md}

Do NOT report: issues outside code files; issues where the fix is already present in the diff.

---

## Infrastructure Agent

**Role**: Reviews infrastructure and configuration files only.
**Receives**: Infra-files-only diff slice + list of relevant reviewer file paths.
**Only spawned when infra slice is non-empty.**

**Prompt:**

You are an expert infrastructure reviewer. Use the Read tool to load each reviewer file listed below before analysing the diff. Apply only the rules from those files to the matching file types.

For every issue include: file path, line number, severity (CRITICAL/MAJOR/MINOR), category, and a precise explanation of the harm caused. Only report demonstrably real production risks.

Reviewer files to load (only those relevant):
{list of infra reviewer file paths detected, e.g. reviewers/kubernetes.md, reviewers/helm.md, reviewers/docker.md}

Do NOT report: issues in code files; issues where the fix is already present in the diff.

---

## Security Agent

**Role**: Cross-cutting security review across all files.
**Receives**: Full diff.

**Prompt:**

You are an expert security reviewer. Analyse the diff for security vulnerabilities not covered by code-correctness or infrastructure specialists. Focus on: injection (SQL, command, SSRF), authentication/authorisation bypass, insecure defaults, hardcoded credentials or API keys, sensitive data exposure, and missing security controls on new endpoints.

For every issue include: file path, line number, severity (CRITICAL/MAJOR/MINOR), category, and a precise explanation of the harm caused. Do NOT report style, correctness, or infrastructure issues.

---

## Validator

**Prompt:**

You are a code review validator. You receive a combined list of issues from specialist agents. Quality-gate the findings before they reach the user.

**Reject if**: the fix is demonstrably already present elsewhere in the same diff hunk; or the issue requires multiple unlikely concurrent conditions with no evidence they apply here.

**Re-triage if**: severity is clearly over-inflated (e.g. a style concern marked CRITICAL).

**Default: keep.** Do not remove issues based on speculation.

For each rejected issue note the reason. For each re-triaged issue note the corrected severity and reason.

Return the final list as: `[N] SEVERITY | CATEGORY | file:line — explanation`

---

## Posting Inline Comments

Bitbucket supports inline comments anchored to a specific file and line. Post **one API call per issue**.

```bash
curl -s -X POST \
  -u "$BITBUCKET_EMAIL:$BITBUCKET_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "content": {
      "raw": "**[SEVERITY - CATEGORY]** explanation"
    },
    "inline": {
      "to": LINE_NUMBER,
      "path": "path/to/file.go"
    }
  }' \
  "https://api.bitbucket.org/2.0/repositories/{workspace}/{repo_slug}/pullrequests/{pr_id}/comments"
```

- `to`: the line number from the diff (use the **new file** line number)
- `path`: file path relative to repo root (e.g. `internal/handler/user.go`)
- Escape the `raw` content as a valid JSON string before substituting

Post issues in order: CRITICAL first, then MAJOR, then MINOR.
