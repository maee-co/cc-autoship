#!/bin/bash
# Stop Hook: 作業完了時に未コミット変更がある場合に警告
# 情報提供のみ（ブロックしない）

set -uo pipefail

# 変数を先頭で初期化（セッションバックアップで参照するため）
STAGED=0
UNSTAGED=0
UNTRACKED=0

CHANGES=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')

# additionalContext を積み上げてまとめて出力する
ADDITIONAL_CONTEXT=""

# --- 未コミット変更の警告 ---
if [ "$CHANGES" -gt 0 ]; then
  STAGED=$(git diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
  UNSTAGED=$(git diff --name-only 2>/dev/null | wc -l | tr -d ' ')
  UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
  ADDITIONAL_CONTEXT="未コミット変更: staged=${STAGED}, unstaged=${UNSTAGED}, untracked=${UNTRACKED}"
fi

# --- additionalContext を出力（jq で安全にエスケープ） ---
if [ -n "$ADDITIONAL_CONTEXT" ]; then
  jq -n --arg ctx "$ADDITIONAL_CONTEXT" '{"additionalContext": $ctx}'
fi

# --- セッションサマリーをローカルバックアップ ---
SESSIONS_DIR="${CLAUDE_PROJECT_DIR:-.}/.sessions"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

if [ "$CHANGES" -gt 0 ] || [ -n "$(git log --oneline -1 2>/dev/null)" ]; then
  mkdir -p "$SESSIONS_DIR"
  cat > "$SESSIONS_DIR/session_${TIMESTAMP}.json" << SESSIONEOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "branch": "$BRANCH",
  "staged": $STAGED,
  "unstaged": $UNSTAGED,
  "untracked": $UNTRACKED,
  "last_commit": "$(git log -1 --format='%H %s' 2>/dev/null || echo 'none')"
}
SESSIONEOF
fi

exit 0
