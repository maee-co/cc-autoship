#!/bin/bash
# SessionStart hook: open な maintenance Issue があれば Claude に 1 行 nudge（additionalContext）。
# 自動適用はしない（merge 規律）。gh 未導入 / 失敗時は静かに無音終了。
# stdout: additionalContext JSON（あれば） / stderr: なし
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/maintenance-reminder.sh"

command -v gh >/dev/null 2>&1 || exit 0
LINES=$(gh issue list --label maintenance --state open --json number,title \
  --jq '.[] | "\(.number)\t\(.title)"' 2>/dev/null) || exit 0

MSG=$(printf '%s' "$LINES" | maintenance_reminder_message)
[ -n "$MSG" ] || exit 0

jq -n --arg ctx "$MSG" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
exit 0