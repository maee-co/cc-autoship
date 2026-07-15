#!/bin/bash
# /auto-merge の実行部を 1 スクリプトに集約したラッパー（#1323 / session-retro 2026-07-07）
#
# 目的: SKILL.md（.claude/commands/auto-merge.md）の「判定 → コメント → CI 待ち →
#   squash merge → cleanup → Issue クローズ確認」を毎回手書きの複合 Bash で再実行して
#   いた（1 セッションで 4 回・うち 1 回は lib 二重 source で readonly 再定義 exit 126）。
#   本スクリプトに集約し、転記ミス・source 事故を構造的に排除する。
#
# 使い方:
#   scripts/claude-hooks/auto-merge-run.sh <PR番号>
#   引数省略時は現在ブランチに紐づく PR を自動検出。
#
# exit code 規約（呼び出し側スキルはこれで分岐する）:
#   0 = MERGED（squash merge 成功・cleanup / Issue 確認まで完了）
#   2 = HANDOFF（判定 NG。判定結果コメントを投稿済み・マージせず停止）
#   3 = CI_FAIL（CI 失敗 / タイムアウト。CI 不発フォールバックは対象外・別途手動）
#   4 = MERGE_FAIL（マージ実行が MERGED にならなかった。コンフリクト等）
#   64 = 使用方法エラー（PR 番号が数値でない等）
#
# 注: マージゲートの判定ロジックそのものは lib/auto-merge-criteria.sh が SSoT。
#     本スクリプトはそれを呼ぶオーケストレーションに徹する（判定基準を再実装しない）。
#     CI 不発時のローカル検証フォールバック（auto-merge.md ステップ 2.5）は副作用が
#     大きく自動化に不向きなため本スクリプトの対象外とし、CI_FAIL で停止して手順に委ねる。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/auto-merge-criteria.sh"

PR="${1:-}"
if [ -z "$PR" ]; then
  PR="$(gh pr view --json number -q .number 2>/dev/null || true)"
fi
if ! printf '%s' "$PR" | grep -qE '^[0-9]+$'; then
  echo "usage: auto-merge-run.sh <PR番号>（現在ブランチに PR が無い場合は番号を明示）" >&2
  exit 64
fi

# --- ステップ 1: 判定 ---
RESULT="$(auto_merge_evaluate "$PR")"
JUDGE_EXIT=$?
gh pr comment "$PR" --body "$RESULT" >/dev/null || true

# --- pr-outcome 観測記録（自己改善ループ Phase 1a / {ISSUE-ID}・非ブロッキング・outbox 経由） ---
# 判定の pass/blocked + レビューの status/指摘数を outbox に 1 行追記する（週次で repo-maintenance が
# pr-outcomes.jsonl へ合流 = Phase 1b）。checkout 依存せず常に成功する追記のみ（main 保護と両立・§5.2）。
if [ -f "$SCRIPT_DIR/lib/improvement-outbox.sh" ]; then
  # shellcheck source=lib/improvement-outbox.sh
  source "$SCRIPT_DIR/lib/improvement-outbox.sh"
  _AM_VERDICT=$([ "$JUDGE_EXIT" = "0" ] && echo "pass" || echo "blocked")
  # .body // "" で null body（bot コメント等）による jq エラー（null cannot be matched）を回避する
  _AM_REVIEW="$(gh pr view "$PR" --json comments --jq '[.comments[] | (.body // "") | select(test("## レビュー結果"))] | last // ""' 2>/dev/null || true)"
  io_record_pr_outcome "${CLAUDE_PROJECT_DIR:-.}/.sessions" "$PR" "$_AM_VERDICT" "$_AM_REVIEW" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || true
fi

if [ "$JUDGE_EXIT" != "0" ]; then
  echo "HANDOFF: 判定 NG（判定結果コメントを投稿済み）。PR #$PR" >&2
  exit 2
fi

# --- ステップ 2: CI 待ち（CI 未設定はスキップ） ---
ROLLUP_LEN="$(gh pr view "$PR" --json statusCheckRollup --jq '.statusCheckRollup | length' 2>/dev/null || echo "0")"
if [ "${ROLLUP_LEN:-0}" = "0" ]; then
  gh pr comment "$PR" --body "## 🤖 /auto-merge CI: ⏭️ CI 未設定

statusCheckRollup が空のため CI チェックをスキップします。squash merge を実行します。" >/dev/null || true
else
  TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
  if [ -n "$TIMEOUT_BIN" ]; then
    CI_WATCH=("$TIMEOUT_BIN" 600 gh pr checks "$PR" --watch --fail-fast)
  else
    CI_WATCH=(gh pr checks "$PR" --watch --fail-fast)
  fi
  if ! "${CI_WATCH[@]}" >/dev/null 2>&1; then
    gh pr comment "$PR" --body "## 🤖 /auto-merge CI: ❌ 失敗 / タイムアウト

\`\`\`
$(gh pr checks "$PR" 2>&1 | tail -20)
\`\`\`

CI 不発（Actions 枠枯渇等）の場合は auto-merge.md ステップ 2.5（ローカル検証フォールバック）を手動で実施すること。CEO の対応待ちです。" >/dev/null || true
    echo "CI_FAIL: CI 失敗 / タイムアウト。PR #$PR" >&2
    exit 3
  fi
  gh pr comment "$PR" --body "## 🤖 /auto-merge CI: ✅ 全 check 成功

CI が pass したため、squash merge を実行します。" >/dev/null || true
fi

# --- ステップ 3: squash merge（成否は state 再確認で判定・#{ISSUE-ID}） ---
MERGE_OUT="$(gh pr merge "$PR" --squash 2>&1)" || true
sleep 3
MERGE_STATE="$(gh pr view "$PR" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")"
if [ "$MERGE_STATE" != "MERGED" ]; then
  gh pr comment "$PR" --body "## 🤖 /auto-merge マージ失敗: ❌

\`\`\`
$MERGE_OUT
\`\`\`

コンフリクト等の可能性があります。CEO の対応待ちです。" >/dev/null || true
  echo "MERGE_FAIL: state=${MERGE_STATE}。PR #${PR}" >&2
  exit 4
fi
gh pr comment "$PR" --body "## 🤖 /auto-merge マージ完了: ✅

\`squash merge\` でマージしました。worktree は自動クリーンアップされます。" >/dev/null || true

# --- ステップ 3.5: cleanup + Issue クローズ確認 ---
bash "$SCRIPT_DIR/cleanup-merged-worktrees.sh" "$PR" || true
auto_merge_warn_unclosed_issues "$PR" || true

echo "MERGED: PR #${PR}（cleanup / Issue 確認まで完了）。次は /pr-context-summary --mode post-merge --pr ${PR}"
exit 0