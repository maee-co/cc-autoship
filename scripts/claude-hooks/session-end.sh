#!/bin/bash
# SessionEnd Hook: セッション終了時のクリーンアップ・ログ集計
# Stop hook は「Claude が応答を返したとき」に動作するのに対し、
# SessionEnd は「セッション全体が終了したとき」に 1 回だけ動作する。
#
# 役割:
#   1. セッション終了サマリーを .sessions/ に保存（終了理由付き）
#   2. マージ済み・close 済みの残存 worktree を検出して additionalContext で通知
#
# 失敗時も Claude を止めないため、常に exit 0

set -uo pipefail

# jq が無ければ最小処理のみ
if ! command -v jq &>/dev/null; then
  exit 0
fi

INPUT=$(cat)
END_REASON=$(echo "$INPUT" | jq -r '.matcher // .reason // "unknown"')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# --- セッション終了サマリーをローカルに記録 ---
SESSIONS_DIR="${CLAUDE_PROJECT_DIR:-.}/.sessions"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
COMMIT_COUNT=$(git log --oneline --since="6 hours ago" 2>/dev/null | wc -l | tr -d ' ')

mkdir -p "$SESSIONS_DIR"
jq -nc \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg reason "$END_REASON" \
  --arg sid "$SESSION_ID" \
  --arg cwd "$CWD" \
  --arg branch "$BRANCH" \
  --argjson commits "$COMMIT_COUNT" \
  '{
    timestamp: $ts,
    end_reason: $reason,
    session_id: $sid,
    cwd: $cwd,
    branch: $branch,
    commits_in_session: $commits
  }' > "$SESSIONS_DIR/session_end_${TIMESTAMP}.json" 2>/dev/null || true

# --- 残存マージ済み worktree を検出 ---
# CLAUDE_PROJECT_DIR 起点で .claude/worktrees/ をスキャン
STALE_HINT=""
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
WT_BASE="$PROJECT_DIR/.claude/worktrees"

if [ -d "$WT_BASE" ] && command -v gh &>/dev/null; then
  STALE_LIST=""
  while IFS= read -r wt_path; do
    [ -z "$wt_path" ] && continue
    [ ! -d "$wt_path" ] && continue

    # worktree のブランチ名を取得
    wt_branch=$(cd "$wt_path" 2>/dev/null && git rev-parse --abbrev-ref HEAD 2>/dev/null) || continue
    [ -z "$wt_branch" ] && continue
    [ "$wt_branch" = "main" ] && continue

    # PR 状態を取得（gh 認証無 / PR 未作成は静かにスキップ）
    pr_state=$(gh pr list --head "$wt_branch" --state all --json state --jq '.[0].state' 2>/dev/null) || continue
    if [ "$pr_state" = "MERGED" ] || [ "$pr_state" = "CLOSED" ]; then
      STALE_LIST="${STALE_LIST}- $wt_branch (PR: $pr_state)\n"
    fi
  done < <(find "$WT_BASE" -mindepth 1 -maxdepth 2 -type d 2>/dev/null | head -20)

  if [ -n "$STALE_LIST" ]; then
    STALE_HINT="残存する MERGED/CLOSED 済み worktree:\n${STALE_LIST}\`scripts/claude-hooks/cleanup-merged-worktrees.sh --all\` で一括削除できます。"
  fi
fi

# --- additionalContext で通知 ---
if [ -n "$STALE_HINT" ]; then
  jq -nc --arg ctx "$STALE_HINT" '{
    hookSpecificOutput: {
      hookEventName: "SessionEnd",
      additionalContext: $ctx
    }
  }'
fi

exit 0
