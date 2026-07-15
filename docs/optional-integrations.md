# Optional Integrations

cc-autoship works standalone with GitHub and local git. The integration below is **opt-in** — the core workflow (Issue → worktree → PR → review → auto-merge) runs without it.

## Codex Secondary Review

The `codex-secondary-review` skill runs a second-pass review that complements the primary `/review`. It delegates to Codex through the **[openai/codex-plugin-cc](https://github.com/openai/codex-plugin-cc)** plugin — that plugin provides the `codex:codex-rescue` agent this skill invokes, and it runs through your local Codex CLI.

**Without it**: secondary review is skipped. Primary `/review` is sufficient for most PRs.

**To enable it:**

1. Install and configure the Codex plugin — inside a Claude Code session:

   ```bash
   /plugin marketplace add openai/codex-plugin-cc
   /plugin install codex@openai-codex
   /reload-plugins
   /codex:setup
   ```

   `codex-plugin-cc` delegates to your local Codex CLI, so you also need the `codex` CLI installed and authenticated (a ChatGPT subscription or an OpenAI API key). See its README for details.

2. Then add `[codex-review]` to a PR body — or let the trigger conditions in `codex-secondary-review` fire it automatically — to run the secondary review.

## CLAUDE_CONFIG_DIR (Project Isolation)

To prevent memory bleed between projects or clients, set a per-project config directory:

```bash
export CLAUDE_CONFIG_DIR=~/.claude-project-x
```

This isolates Claude's memory, settings, and permissions per project. Recommended when working on multiple unrelated codebases with cc-autoship installed.
