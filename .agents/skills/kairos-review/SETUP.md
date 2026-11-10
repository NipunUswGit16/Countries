# Bitbucket Token Setup

The skill uses an **Atlassian API Token** with Basic auth (`email:token`) to fetch diffs and post inline comments.

> **Critical**: Bitbucket's REST API requires Basic auth, NOT Bearer auth. Using `Authorization: Bearer <token>` returns `401 Token is invalid, expired, or not supported for this endpoint` even for a valid token. Always use `-u "$BITBUCKET_EMAIL:$BITBUCKET_TOKEN"`.

## Step 1 — Create the token in Atlassian

1. Go to **https://id.atlassian.com/manage-profile/security/api-tokens**
2. Click **Create API token with scopes**
3. Give it a name (e.g. `kairos-pr-review`)
4. Select product: **Bitbucket**
5. Select these scopes:
   - **View your repositories** (`read:repository:bitbucket`) — required to fetch diffs
   - **View your pull requests** (`read:pullrequest:bitbucket`)
   - **Write your pull requests** (`write:pullrequest:bitbucket`) — required to post comments
6. Click **Create** and **copy the token immediately** — shown only once

> **Not** Repository settings → Access tokens. Those are Repository Access Tokens and only have `read:pullrequest` / `write:pullrequest` scopes — they cannot fetch diffs (`read:repository` is missing).

## Step 2 — Saved automatically by the skill

When you paste your token and email into the skill, it writes them to `~/.config/kairos-review/credentials` with file mode `0600` (your user only):

```bash
export BITBUCKET_TOKEN='your-token-here'
export BITBUCKET_EMAIL='you@company.com'
```

This file is **host-agnostic** — it works identically in Claude Code, Cursor, Codex, and WSL on Windows because the skill `source`s it at the start of every run. No host-specific settings file is involved.

> **Security**:
>
> - Never commit `~/.config/kairos-review/` to any repository.
> - Avoid syncing `~/.config/` to Dropbox, iCloud Drive, or similar — the file is plaintext.
> - The Atlassian token is scoped (read repository + read/write pull request comments). If you suspect a leak, rotate it at https://id.atlassian.com/manage-profile/security/api-tokens.

---

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `401 Unauthorized` | Using Bearer auth instead of Basic auth | Switch to `-u "$BITBUCKET_EMAIL:$BITBUCKET_TOKEN"` |
| `401 Token is invalid, expired, or not supported` | Bearer auth used, or token expired | Use Basic auth; regenerate token at id.atlassian.com if expired |
| `403 Your credentials lack one or more required privilege scopes` | Token missing `read:repository:bitbucket` | Regenerate at id.atlassian.com with all three scopes (see Step 1) |
| `403 Forbidden` | Token missing Write permission | Recreate with `write:pullrequest:bitbucket` |
| `404 Not Found` | Wrong workspace or repo slug in URL | Double-check the PR URL format |
