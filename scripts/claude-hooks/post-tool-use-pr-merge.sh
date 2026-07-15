#!/bin/bash
# PostToolUse Hook: gh pr merge 検知 → マージ済み worktree を自動クリーンアップ
#
# PostToolUse フックの stdin JSON 仕様（本番は .tool_response.stdout・{ISSUE-ID}）:
#   { "tool_name": "Bash", "tool_input": { "command": "..." }, "tool_response": { "stdout": "...", "stderr": "..." } }
# 本 hook は検知に .tool_input.command のみを使い stdout は参照しないため、この乖離による
# 機能影響はない（コメントの正確化のみ）。stdout を読む必要が出たら lib/hook-input.sh の
# hook_stdout_from_input を使うこと。

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/command-match.sh
source "$HOOK_DIR/lib/command-match.sh"

if ! command -v jq &>/dev/null; then
  exit 0
fi

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

if [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# gh pr merge コマンドを検知（{ISSUE-ID}: 引用符内・echo/grep 引数での出現は除外する純関数を使用）
if ! is_gh_pr_merge_command "$COMMAND"; then
  exit 0
fi

# shellcheck disable=SC1091
source "$HOOK_DIR/lib/cleanup-merged-worktrees.sh"

cleanup_merged_worktrees stderr

exit 0