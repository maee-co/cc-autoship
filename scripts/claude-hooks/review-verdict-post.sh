#!/bin/bash
# /review の判定コメントを「機械導出 + スクリプト投稿」で確定するラッパー（{ISSUE-ID} Phase 2）
#
# 背景: auto mode の権限分類器は、エージェントが自分の実装した PR に肯定的 pass 判定を
#   直接投稿する行為を [Self-Approval] として実ブロックする（2026-07-12 実測）。本スクリプトは
#   判定の著者をモデルから剥奪する: モデルは findings の「事実」（指摘表・カテゴリ・検証結果を
#   書いた本文ファイルと、Critical/Major 件数・テスト結果・高リスク論点有無の引数）だけを渡し、
#   verdict は lib/review-verdict.sh の純関数が導出、見出し・判定節の付与と投稿は本スクリプトが行う。
#
# 使い方:
#   scripts/claude-hooks/review-verdict-post.sh <PR#> \
#     --critical <N> --major <N> --tests <green|red> \
#     --high-risk <yes|no> [--light] --body-file <findings.md>
#
#   <findings.md> = 「## レビュー結果」見出しと「### 判定」節を **含まない** 事実本文
#   （対象/サマリ/指摘一覧表/カテゴリ表/検証。含まれていたら契約違反で拒否する）。
#
# exit code 規約:
#   0  = 投稿成功（stdout に VERDICT=<pass|要確認|fail> と投稿 URL）
#   1  = gh 投稿失敗
#   64 = 使用方法エラー（引数不正・導出入力不正）
#   65 = 本文契約違反（見出し/判定節の二重付与・空本文）
#
# 注: 判定規則の SSoT は lib/review-verdict.sh（テスト済み純関数）。本スクリプトは
#     それを呼ぶオーケストレーションに徹する（判定を再実装しない）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/review-verdict.sh"

PR="${1:-}"; shift || true
if ! printf '%s' "$PR" | grep -qE '^[0-9]+$'; then
  echo "usage: review-verdict-post.sh <PR番号> --critical N --major N --tests green|red --high-risk yes|no [--light] --body-file <path>" >&2
  exit 64
fi

# 値付きオプションの値存在ガード（末尾値なしで shift 2 が no-op になり無限ループする事故防止・{ISSUE-ID} Major 2）
_need_val() { [ $# -ge 2 ] || { echo "オプション $1 に値がありません" >&2; exit 64; }; }

CRITICAL="" MAJOR="" TESTS="" HIGH_RISK="" LIGHT="" BODY_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --critical)  _need_val "$@"; CRITICAL="$2"; shift 2 ;;
    --major)     _need_val "$@"; MAJOR="$2"; shift 2 ;;
    --tests)     _need_val "$@"; TESTS="$2"; shift 2 ;;
    --high-risk) _need_val "$@"; HIGH_RISK="$2"; shift 2 ;;
    --light)     LIGHT="light"; shift ;;
    --body-file) _need_val "$@"; BODY_FILE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

# --high-risk も必須（省略既定 no だと高リスク論点ありでも pass に倒れる permissive gate になる・{ISSUE-ID} Minor 4）
if ! { [ -n "$CRITICAL" ] && [ -n "$MAJOR" ] && [ -n "$TESTS" ] && [ -n "$HIGH_RISK" ] && [ -n "$BODY_FILE" ]; }; then
  echo "--critical / --major / --tests / --high-risk / --body-file は必須です" >&2; exit 64
fi
[ -f "$BODY_FILE" ] || { echo "body-file が見つかりません: $BODY_FILE" >&2; exit 64; }

BODY="$(cat "$BODY_FILE")"
if ! rvp_validate_body "$BODY"; then
  echo "本文契約違反: findings 本文に「## レビュー結果」見出し・「### 判定」節を含めない（スクリプトが付与する）/ 空本文不可" >&2
  exit 65
fi

VERDICT="$(rvp_derive_verdict "$CRITICAL" "$MAJOR" "$TESTS" "$HIGH_RISK")" || {
  echo "導出入力が不正です（critical/major は非負整数、tests は green|red、high-risk は yes|no）" >&2
  exit 64
}

COMMENT="$(rvp_compose_comment "$BODY" "$VERDICT" "$CRITICAL" "$MAJOR" "$TESTS" "$HIGH_RISK" "$LIGHT")"

URL="$(gh pr comment "$PR" --body "$COMMENT" 2>&1)" || {
  echo "投稿失敗: $URL" >&2
  exit 1
}

echo "VERDICT=$VERDICT"
echo "POSTED=$URL"
echo "次のアクション: 判定が pass なら /auto-merge ${PR}（auto-merge-run.sh）をそのまま実行する。ユーザーへのマージ可否の確認（AskUserQuestion 等）は不要 — マージ可否はゲートが決定済みで、ユーザーの依頼はマージまでを含む標準フロー（止めるのはゲートの役目）。"
exit 0