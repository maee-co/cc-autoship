# Project-Side Setup

cc-autoship bundles everything needed to run the Issue → PR → auto-merge loop. After installing, configure the two data files below to match your repository layout. Everything else works out of the box.

> **Where the bundled files live (plugin install).** If you installed via `/plugin install` (the usual path), the bundled `scripts/claude-hooks/…` files live in the **plugin cache** (`~/.claude/plugins/cache/<marketplace>/cc-autoship/<version>/`), **not in your repo** — and a `/plugin update` replaces that directory, so edits to the cached copies do not survive. The two config files resolve differently, so configure each as noted in its step below:
> - **`public-content-paths.txt`** defaults to the bundled (cache) copy. To customize durably, set `PUBLIC_CONTENT_PATHS_FILE` to a file **in your repo** rather than editing the cached copy.
> - **`frontend-apps.txt`** defaults to **your repo** (`<repo-root>/scripts/claude-hooks/data/frontend-apps.txt`), which a plugin install does not create — so the e2e gate stays off until you create that file in your repo or set `FRONTEND_APPS_FILE`.
>
> If you vendored cc-autoship into your repo (drop-in copy), both files are in your repo and you can edit them in place as written.

## 1. Declare public content paths

`scripts/claude-hooks/data/public-content-paths.txt` tells `/auto-merge` which paths must never be auto-merged (e.g. your landing page, public README).

Edit the file and add one entry per line (plugin install: point `PUBLIC_CONTENT_PATHS_FILE` at a repo-local copy instead — see the note above):

```
# README.md       ← exact filename match
# apps/site/      ← anything under apps/site/
```

Leave the file empty (comments only) if you have no public-content restrictions — auto-merge will skip the check and always pass.

## 2. Declare UI apps that require e2e gating

`scripts/claude-hooks/data/frontend-apps.txt` lists the apps whose UI changes must pass a Playwright L1 golden-path test before auto-merging.

Add one `apps/<name>` path per line (plugin install: this file's default location is **your repo**, which the install does not create — create it at `scripts/claude-hooks/data/frontend-apps.txt` in your repo, or set `FRONTEND_APPS_FILE`; see the note above):

```
# apps/web
# apps/admin
```

Leave the file empty (comments only) to disable the e2e gate — all PRs will pass condition 8 regardless of UI changes.

## 3. Use the worktree path convention

`cleanup-merged-worktrees.sh` (called by `/auto-merge` after merge) removes worktrees by inspecting `git worktree list`. It works with **any** worktree path, so no fixed path is required.

The recommended convention (used in the bundled hooks and rules) is:

```
.claude/worktrees/<branch-name>
```

Example:

```bash
git worktree add .claude/worktrees/feat/99-web-dark-mode -b feat/99-web-dark-mode
```

Add `.claude/worktrees/` to your `.gitignore` to keep worktree directories out of version control.

## 4. (Optional) Let `/auto-merge` run without a prompt each time

By default, Claude Code asks you to confirm before running `gh pr merge`, even for PRs that already passed every gate above. cc-autoship never edits your permission settings for you — if you want to skip that prompt, you grant the permission yourself, once, per repo.

Add `gh pr merge` to the allow list in your `.claude/settings.local.json` (create the file if it does not exist):

```json
{
  "permissions": {
    "allow": ["Bash(gh pr merge:*)"]
  }
}
```

If you already have a `permissions.allow` array, add the string to it rather than replacing it. This only changes whether you are prompted — the gates (`/review`, size, scope, CI, public-content guard) still decide what is eligible to merge. Remove the line at any time to go back to being prompted on every merge.

> **Already covered?** If your user-level `~/.claude/settings.json` already allows `gh` broadly (e.g. `Bash(gh:*)`), or a repo you cloned ships this grant in its committed `.claude/settings.json`, then `gh pr merge` is already permitted — this step is a no-op. Check with `/permissions` before adding it.

## What is already bundled

The following are **included in cc-autoship** — no copying required:

| File | Role |
| --- | --- |
| `scripts/claude-hooks/lib/auto-merge-criteria.sh` | Auto-merge gate logic (8 conditions, pure-function bash) |
| `scripts/claude-hooks/cleanup-merged-worktrees.sh` | Removes merged worktrees and branches after PR close |
| `scripts/claude-hooks/data/public-content-paths.txt` | Template — edit in place (see step 1) |
| `scripts/claude-hooks/data/frontend-apps.txt` | Template — edit in place (see step 2) |

## Verification

Run the bundled test suite to confirm the gate logic works in your environment:

```bash
bash scripts/claude-hooks/__tests__/test-runner.sh
```

All tests should pass (`FAIL=0`) before using `/auto-merge` in production.
