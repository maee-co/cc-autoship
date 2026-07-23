#!/bin/bash
# PostToolUse Hook: gh pr comment でレビュー結果コメント検知 → auto-merge スキル起動を指示（{ISSUE-ID}/116）
# 抑止: PR 本文に [manual-merge] タグがある場合
# Note: コマンド名をスラッシュ記法ではなく「スキル名を起動」形式にすることで
#   cc-autoship 等プラグイン経由インストール時のプレフィックス（/cc-autoship:auto-merge 等）と
#   CC 組込コマンドの衝突を回避する
# stdout: Claude 向け additionalContext。stderr: 人間オペレーター向け短縮ログ

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/command-match.sh
source "$SCRIPT_DIR/lib/command-match.sh"
# shellcheck source=lib/review-comment.sh
source "$SCRIPT_DIR/lib/review-comment.sh"

if ! command -v jq &>/dev/null; then
  exit 0
fi

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')

if [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# 検知対象コマンド: gh pr comment（従来）または review-verdict-post.sh（#N Phase 2・
# 判定の機械導出スクリプト。コメント投稿はスクリプト内部の gh 呼び出しで行われ本 hook からは
# 見えないため、スクリプト実行コマンド自体を「レビュー結果コメント投稿」として扱う）
IS_RVP=0
if is_review_verdict_post_command "$COMMAND"; then
  IS_RVP=1
elif ! is_gh_pr_comment_command "$COMMAND"; then
  exit 0
fi

if [ "$IS_RVP" = "1" ]; then
  # スクリプトは常に「## レビュー結果」見出しで投稿する（lib/review-verdict.sh の compose が付与）。
  # --fix 見出しは投稿しないため fix 分岐にも入らない。
  DETECT_TEXT="## レビュー結果"
else
  # 検知対象テキスト = コマンド文字列 + （あれば）body-file の中身
  # --body inline / --body-file <path> 双方で見出しを拾えるようにする
  DETECT_TEXT=$(rc_resolve_detection_text "$COMMAND" "$CWD")
fi

# レビュー結果コメントの "見出し" パターンを厳密にマッチ（偽陽性削減 / SSoT: lib/review-comment.sh）
# 検知対象: "## レビュー結果" / "## レビュー指摘修正結果" / "## 🤖 一次レビュー" 等の Markdown 見出し
# これにより メンテナ/Claude の通常コメント本文に「レビュー結果について」などが含まれても誤発火しない
if ! rc_has_review_heading "$DETECT_TEXT"; then
  exit 0
fi

# Codex 二次レビューの自己投稿は auto-merge 対象外（余分な /auto-merge 起動を防ぐ・{ISSUE-ID} Phase 3 C-1）。
# sibling: post-tool-use-codex-secondary-review.sh の自己除外ガードと対称。通常は Codex の見出し
# （## 🤖 Codex 二次レビュー）が rc_has_review_heading に一致せずここへ到達しないが、本文が偶然
# レビュー見出しを含むケースへの多層防御（--body / --body-file 双方の DETECT_TEXT で判定）。
if printf '%s' "$DETECT_TEXT" | grep -qF 'codex-secondary-review:'; then
  exit 0
fi

# PR 番号を抽出（複数の入力形式に対応）
# 1) gh pr comment 123 --body ...
# 2) gh pr comment https://github.com/owner/repo/pull/456 --body ...
# 3) gh pr comment --body "..." 789（番号が末尾）
PR_NUM=""
# パターン 0: review-verdict-post.sh <PR#>（第 1 引数が PR 番号・#N Phase 2）
if [ "$IS_RVP" = "1" ]; then
  PR_NUM=$(printf '%s' "$COMMAND" | grep -oE 'review-verdict-post\.sh["'"'"'[:space:]]+[0-9]+' | grep -oE '[0-9]+' | head -1 || true)
  # review.md の正規テンプレは locate 後に変数実行（bash "$RVP" <PR#>）するため、リテラル名の
  # 直後に番号が来ない。$RVP / ${RVP} 変数実行形からも第 1 引数を拾う（#N Major 1）
  if [ -z "$PR_NUM" ]; then
    PR_NUM=$(printf '%s' "$COMMAND" | grep -oE '(bash[[:space:]]+)?"?\$\{?RVP\}?"?[[:space:]]+[0-9]+' | grep -oE '[0-9]+' | head -1 || true)
  fi
fi
# パターン 1: gh pr comment 直後の数字
if [ -z "$PR_NUM" ]; then
  PR_NUM=$(printf '%s' "$COMMAND" | grep -oE 'gh pr comment[[:space:]]+[0-9]+' | grep -oE '[0-9]+' | head -1 || true)
fi
# パターン 2: GitHub URL から
if [ -z "$PR_NUM" ]; then
  PR_NUM=$(printf '%s' "$COMMAND" | grep -oE 'github\.com/[^ ]+/pull/[0-9]+' | grep -oE '[0-9]+$' | head -1 || true)
fi
# パターン 3: --body 後ろの数字（最後の手段）
if [ -z "$PR_NUM" ]; then
  PR_NUM=$(printf '%s' "$COMMAND" | grep -oE 'gh pr comment[[:space:]]+--body[[:space:]]+["'\''][^"'\'']*["'\''][[:space:]]+[0-9]+' | grep -oE '[0-9]+$' | head -1 || true)
fi

# --fix（レビュー指摘修正結果）の分岐（#N 判断 1）:
# --fix コメントは判定ステータスを持たないため auto-merge の判定根拠にできない（gate は最新の通常
# レビューのみ信頼）。よって auto-merge でなく **再 /review** を促す。再 /review は [manual-merge] PR でも
# 有用（修正の再確認）なので manual-merge 抑止の前に分岐して確定させる。
if rc_is_fix_result_heading "$DETECT_TEXT"; then
  if [ -n "$PR_NUM" ]; then
    FIX_REMINDER="\`/review --fix\` の修正結果コメントが投稿されました（PR #${PR_NUM}）。--fix コメントは判定ステータスを持たないため、そのままでは auto-merge できません（gate は最新の通常レビューのみ信頼）。次のアクションは **再 /review（引数: ${PR_NUM}）** です。修正後のコードを再レビューし、判定ステータス付きの \`## レビュー結果\` を投稿してください（それを hook が検知して auto-merge へ繋ぎます）。"
  else
    FIX_REMINDER="\`/review --fix\` の修正結果コメントが投稿されました。--fix は判定ステータスを持たないため、次のアクションは **再 /review** です（current branch から PR 番号を推論）。判定ステータス付きの \`## レビュー結果\` を投稿してください。"
  fi
  jq -n --arg ctx "$FIX_REMINDER" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}'
  echo "PR #${PR_NUM:-?}: --fix (レビュー指摘修正結果) detected → re-review reminder emitted" >&2
  exit 0
fi

# manual-merge タグ抑止チェック
if [ -n "$PR_NUM" ] && command -v gh &>/dev/null; then
  PR_BODY=$(gh pr view "$PR_NUM" --json body --jq '.body' 2>/dev/null || echo "")
  if printf '%s' "$PR_BODY" | grep -qF '[manual-merge]'; then
    echo "PR #${PR_NUM} は [manual-merge] タグ付きのため auto-merge スキル起動を抑止" >&2
    exit 0
  fi
fi

if [ -n "$PR_NUM" ]; then
  REMINDER="レビュー結果コメントが投稿されました（PR #${PR_NUM}）。dev-flow ルールでは次のアクションは auto-merge スキルの起動（引数: ${PR_NUM}）です。判定 OK ならマージ→クリーンアップ→pr-context-summary スキル post-merge、NG なら判定結果コメントを残してハンドオフし停止します（ポーリングはしません・{ISSUE-ID}）。判定が pass の場合、ユーザーへのマージ可否の確認（AskUserQuestion 等）は不要です — マージ可否はゲートが決定済みで、ユーザーの依頼はマージまでを含む標準フロー（止めるのはゲートの役目・#N）。"
else
  REMINDER="レビュー結果コメントが投稿されました。dev-flow ルールでは次のアクションは auto-merge スキルの起動（引数: <PR#>）です（current branch から PR 番号を自動推論できます）。判定 OK ならマージ→クリーンアップ→pr-context-summary スキル post-merge、NG なら判定結果コメントを残してハンドオフし停止します（ポーリングはしません・{ISSUE-ID}）。"
fi

# stdout: Claude のコンテキストに structured 投入
jq -n --arg ctx "$REMINDER" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}'

# stderr: 人間オペレーター向け短縮ログ
if [ -n "$PR_NUM" ]; then
  echo "PR #${PR_NUM}: auto-merge reminder emitted" >&2
else
  echo "review comment detected: auto-merge reminder emitted" >&2
fi

exit 0