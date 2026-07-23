#!/bin/bash
# /auto-merge の実行部を 1 スクリプトに集約したラッパー（#N / session-retro 2026-07-07）
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

# Pure: CI / マージ結果コメントの文言（{ISSUE-ID} Phase 3）。lc_am_step があれば言語に追随し、
#   無ければ第 2 引数（= 従来の日本語文言）をそのまま返す。auto-merge-criteria.sh の
#   _amc_* ヘルパーと同じフォールバック規約で、language-config.sh 未同梱の環境でも
#   出力が従来どおりに保たれる。
#   Args: $1 = ステップキー, $2 = 従来の日本語文言
#   Stdout: コメント全文（ci_fail / merge_fail は %s を含む printf フォーマット）
_amr_step() {
  if declare -f lc_am_step >/dev/null 2>&1; then
    local _s; _s="$(lc_am_step "$1" "$(_amc_lang)")"
    # 未知キーで空が返ったらフォールバックする（空コメントを投稿しない）
    if [ -n "$_s" ]; then printf '%s' "$_s"; return 0; fi
  fi
  printf '%s' "$2"
}

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
  # 記録用の最新レビュー本文取得も判定ゲートと同じ SSoT（extract_latest_review_from_pr_data）に
  # 統一する。言語不変マーカー（#N・{ISSUE-ID}）付きの英語レビューも記録でき、作者フィルタ・
  # fix/codex 除外も一貫する（旧: 日本語見出し固定 jq で英語本文を取りこぼしていた）。
  _AM_REVIEW="$(extract_latest_review_from_pr_data "$(gh pr view "$PR" --json comments 2>/dev/null || echo '{}')")"
  io_record_pr_outcome "${CLAUDE_PROJECT_DIR:-.}/.sessions" "$PR" "$_AM_VERDICT" "$_AM_REVIEW" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || true
fi

if [ "$JUDGE_EXIT" != "0" ]; then
  echo "HANDOFF: 判定 NG（判定結果コメントを投稿済み）。PR #$PR" >&2
  exit 2
fi

# --- ステップ 2: CI 待ち（CI 未設定はスキップ） ---
ROLLUP_LEN="$(gh pr view "$PR" --json statusCheckRollup --jq '.statusCheckRollup | length' 2>/dev/null || echo "0")"
if [ "${ROLLUP_LEN:-0}" = "0" ]; then
  gh pr comment "$PR" --body "$(_amr_step ci_skip "## 🤖 /auto-merge CI: ⏭️ CI 未設定

statusCheckRollup が空のため CI チェックをスキップします。squash merge を実行します。")" >/dev/null || true
else
  TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
  if [ -n "$TIMEOUT_BIN" ]; then
    CI_WATCH=("$TIMEOUT_BIN" 600 gh pr checks "$PR" --watch --fail-fast)
  else
    CI_WATCH=(gh pr checks "$PR" --watch --fail-fast)
  fi
  if ! "${CI_WATCH[@]}" >/dev/null 2>&1; then
    # shellcheck disable=SC2059  # フォーマットは lc_am_step 由来（%s のみ）。checks 出力は引数で渡す
    gh pr comment "$PR" --body "$(printf "$(_amr_step ci_fail "## 🤖 /auto-merge CI: ❌ 失敗 / タイムアウト

\`\`\`
%s
\`\`\`

CI 不発（Actions 枠枯渇等）の場合は auto-merge.md ステップ 2.5（ローカル検証フォールバック）を手動で実施すること。メンテナの対応待ちです。")" "$(gh pr checks "$PR" 2>&1 | tail -20)")" >/dev/null || true
    echo "CI_FAIL: CI 失敗 / タイムアウト。PR #$PR" >&2
    exit 3
  fi
  gh pr comment "$PR" --body "$(_amr_step ci_pass "## 🤖 /auto-merge CI: ✅ 全 check 成功

CI が pass したため、squash merge を実行します。")" >/dev/null || true
fi

# --- ステップ 3: squash merge（成否は state 再確認で判定・#{ISSUE-ID}） ---
MERGE_OUT="$(gh pr merge "$PR" --squash 2>&1)" || true
sleep 3
MERGE_STATE="$(gh pr view "$PR" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")"
if [ "$MERGE_STATE" != "MERGED" ]; then
  # shellcheck disable=SC2059  # フォーマットは lc_am_step 由来（%s のみ）。マージ出力は引数で渡す
  gh pr comment "$PR" --body "$(printf "$(_amr_step merge_fail "## 🤖 /auto-merge マージ失敗: ❌

\`\`\`
%s
\`\`\`

コンフリクト等の可能性があります。メンテナの対応待ちです。")" "$MERGE_OUT")" >/dev/null || true
  echo "MERGE_FAIL: state=${MERGE_STATE}。PR #${PR}" >&2
  exit 4
fi
gh pr comment "$PR" --body "$(_amr_step merge_ok "## 🤖 /auto-merge マージ完了: ✅

\`squash merge\` でマージしました。worktree は自動クリーンアップされます。")" >/dev/null || true

# --- ステップ 3.5: cleanup + Issue クローズ確認 ---
bash "$SCRIPT_DIR/cleanup-merged-worktrees.sh" "$PR" || true
auto_merge_warn_unclosed_issues "$PR" || true

echo "MERGED: PR #${PR}（cleanup / Issue 確認まで完了）。次は /pr-context-summary --mode post-merge --pr ${PR}"
exit 0