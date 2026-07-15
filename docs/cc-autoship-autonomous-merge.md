# Autonomous merge: granting the merge permission

cc-autoship can carry a change all the way to `main` on its own — but the final
`gh pr merge` step needs your permission first. This is a one-time setup you do
yourself, in your own repo. cc-autoship never edits your permission settings for
you; you decide whether to grant this.

## Why this step exists

By default, Claude Code pauses and asks you to confirm before it merges a pull
request. That default is a good thing — it keeps a human in the loop on the last,
hardest-to-undo step. cc-autoship already runs its own gates before it ever gets
there (`/review` with zero Critical/Major findings, size/scope checks, and your
CI), so for many users the confirmation prompt is the one manual tap left in an
otherwise automated loop. Even with it granted, the model stays *auto plus a
human final gate*, not full automation — you keep the last word.

If you want cc-autoship to complete that last step without prompting, you grant it
permission to run `gh pr merge`. You are opting your own tool into merging changes
that have already passed its review — a deliberate choice, made by you, for the
repos where you want it.

## How to grant it

Add `gh pr merge` to the allow list in your `.claude/settings.local.json`
(create the file if it does not exist):

```json
{
  "permissions": {
    "allow": ["Bash(gh pr merge:*)"]
  }
}
```

If you already have a `permissions.allow` array, add the string to it rather than
replacing it.

> **Already covered?** If your settings already allow `gh` broadly (e.g.
> `Bash(gh:*)` in your user-level `~/.claude/settings.json`), or a repo you cloned
> ships this grant in its committed `.claude/settings.json`, then `gh pr merge` is
> already permitted — this step is a no-op and adding the line again is harmless.
> Check with `claude` → `/permissions`, or look for an existing `gh` allow entry.

## What it does and does not do

- **Scope**: it lets cc-autoship run `gh pr merge` without a per-merge prompt. It
  does not change what cc-autoship merges — the gates (`/review`, size, scope, CI,
  public-content guard) still decide whether a PR is eligible.
- **Reversible**: remove the line to go back to being prompted on every merge.
- **Per-project**: it lives in that repo's local settings, so it applies only
  where you added it.

## If you would rather keep the prompt

Leave this unset. cc-autoship will run all its gates, post its decision, and hand
off — you make the final merge yourself when you are ready. The rest of the loop
(Issue → worktree → PR → review → gates) is unchanged.
