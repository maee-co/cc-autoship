#!/bin/bash
# SessionEnd Hook: セッション終了時のクリーンアップ・ログ集計
# Stop hook は「Claude が応答を返したとき」に動作するのに対し、
# SessionEnd は「セッション全体が終了したとき」に 1 回だけ動作する。
#
# 役割:
#   1. セッション終了サマリーを .sessions/ に保存（終了理由付き）
#
# 出力契約（#N）: SessionEnd は JSON を返さない。公式仕様上 SessionEnd hook は
#   "side effects only" で「Any JSON output is ignored」であり、実際に
#   hookSpecificOutput.additionalContext を返すと Claude Code が
#   「Hook JSON output validation failed — (root): Invalid input」で拒否する（実観測）。
#   同形式でも SessionStart は正常に通るため、これは SessionEnd 固有の制約。
#
#   以前ここには「マージ済み・close 済みの残存 worktree を検出して additionalContext で
#   通知する」ブロックがあったが、上記のとおり通知は一度も届いておらず（= 届かない通知）、
#   毎回の検証エラーだけを生んでいたため除去した。
#
#   除去後のカバレッジ（正確に）:
#     - MERGED 済み worktree → SessionStart（session-start.sh の cleanup_merged_worktrees）が
#       実際に削除まで行う。
#     - CLOSED（未マージ close）→ **自動経路は無い**。lib/cleanup-merged-worktrees.sh は
#       `gh pr list --state merged` 固定で CLOSED を拾わない。CLOSED を含む一括掃除は
#       standalone の cleanup-merged-worktrees.sh --all のみで、手動実行が必要（#N で追跡）。
#       旧ブロックは CLOSED も検出していたが、通知が届かないため実効カバレッジは元々ゼロだった。
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

# 残存 worktree の検出・通知は行わない（#N・上記「出力契約」のカバレッジ注記を参照）。
# MERGED は SessionStart が削除まで行う / CLOSED は自動経路が無く手動掃除（#N で追跡）。
#
# 副次的な効果: セッション終了ごとの `gh pr list` 呼び出し（worktree 数ぶん）が無くなる。
# 旧実装は `find -mindepth 1 -maxdepth 2` で worktree のサブディレクトリまで走査しており、
# サブディレクトリでも git rev-parse が同じブランチを返すため同一ブランチを重複列挙し、
# さらに `head -20` の上限と相まって大半の worktree に到達しないバグもあった
# （実測: depth1 = 29 件に対し depth1-2 = 225 件を走査）。

exit 0