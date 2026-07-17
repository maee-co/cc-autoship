#!/bin/bash
# PostToolUse Hook: /review 完了後、条件を満たす PR で Codex 二次レビューを促す（{ISSUE-ID}）
# 起動条件は lib/codex-trigger-criteria.sh で評価。抑止: [no-codex] タグ / Codex CLI 未認証
# Codex 指摘は /auto-merge 判定に含めない（Claude 一次レビューが authoritative）
#
# ⚠️ settings.json でこの hook に `"async": true` を付けてはいけない（PR #N → PR #N で確認済み）。
# async hook は fire-and-forget で stdout JSON の `additionalContext` が Claude のコンテキストに
# 届かないため、Claude が `/codex-secondary-review` を呼ばず起動連鎖が切断される。
# 実コストは ~1.3 秒で同期実行でセッションをブロックする問題はないため、同期 + timeout 15s を維持する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/command-match.sh
source "$SCRIPT_DIR/lib/command-match.sh"
# shellcheck source=lib/review-comment.sh
source "$SCRIPT_DIR/lib/review-comment.sh"

# 依存コマンドチェック: jq / gh のいずれも欠ければ静かに終了
if ! command -v jq &>/dev/null || ! command -v gh &>/dev/null; then
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

# 検知対象コマンド: review-verdict-post.sh（#1527 Phase 2・**正規経路**）または gh pr comment（従来）
# （{ISSUE-ID}: 引用符内・echo/grep 引数での出現は除外する純関数を使用）
# Note(#1815): 旧実装は gh pr comment しか見ておらず、#1527 の RVP 化に追随漏れしていた。
#   スクリプト経由の投稿は gh 呼び出しがスクリプト内部で起きるため PostToolUse からは見えず、
#   /review が正規経路で投稿すると本 hook が発火しない（= セキュリティ修正 PR でも Codex 二次
#   レビューが**黙って**走らない）。auto-merge hook の IS_RVP 分岐と対称に、スクリプト実行
#   コマンド自体を「レビュー結果コメント投稿」として扱う。
IS_RVP=0
if is_review_verdict_post_command "$COMMAND"; then
  IS_RVP=1
elif ! is_gh_pr_comment_command "$COMMAND"; then
  exit 0
fi

if [ "$IS_RVP" = "1" ]; then
  # スクリプトは常に「## レビュー結果」見出しで投稿する（lib/review-verdict.sh の compose が付与）。
  # Codex 自身の投稿は gh pr comment 経由のため、下段の自己除外ガードは②側でのみ効けばよい。
  DETECT_TEXT="## レビュー結果"
else
  # 検知対象テキスト = コマンド文字列 + （あれば）body-file の中身（{ISSUE-ID}）
  # --body inline / --body-file <path> 双方で見出し・マーカーを拾えるようにする
  DETECT_TEXT=$(rc_resolve_detection_text "$COMMAND" "$CWD")
fi

# レビュー結果コメントの "見出し" パターンを厳密にマッチ（SSoT: lib/review-comment.sh）
if ! rc_has_review_heading "$DETECT_TEXT"; then
  exit 0
fi

# 自分自身（Codex 二次レビュー）の投稿を検知したらスキップ（無限ループ防止）
# body-file 経由でもマーカーを拾えるよう検知対象テキストで判定（{ISSUE-ID}）
if printf '%s' "$DETECT_TEXT" | grep -qF 'codex-secondary-review:'; then
  exit 0
fi

# PR 番号を抽出（auto-merge-after-review.sh と同じパターン + branch 推論・{ISSUE-ID} Phase 3 B-3）
PR_NUM=""
# パターン 0: review-verdict-post.sh <PR#>（第 1 引数・#1527 Phase 2、#1815 で本 hook にも追加）
# 注: 配布対象ファイルで Issue を参照するときは半角スペース + `#` を挟まない（`・#1527` /
#     `、#1815` のように全角区切りで繋ぐ）。配布先の pollution-guard が ' #[0-9]+' を
#     内部 Issue 番号の漏洩として検知し、sync が止まるため。`PR #N` / `Issue #N` の
#     形は manifest の transform が `#N` へ置換するので従来どおり書いてよい。
if [ "$IS_RVP" = "1" ]; then
  PR_NUM=$(printf '%s' "$COMMAND" | grep -oE 'review-verdict-post\.sh["'"'"'[:space:]]+[0-9]+' | grep -oE '[0-9]+' | head -1 || true)
  # review.md の正規テンプレは locate 後に変数実行（bash "$RVP" <PR#>）するため、リテラル名の
  # 直後に番号が来ない。$RVP / ${RVP} 変数実行形からも第 1 引数を拾う（#1531 Major 1）
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
# パターン 3: --body 後ろの数字（最後の手段・auto-merge hook と対称）
if [ -z "$PR_NUM" ]; then
  PR_NUM=$(printf '%s' "$COMMAND" | grep -oE 'gh pr comment[[:space:]]+--body[[:space:]]+["'\''][^"'\'']*["'\''][[:space:]]+[0-9]+' | grep -oE '[0-9]+$' | head -1 || true)
fi
# パターン 4: コマンドから取れなければ current branch の PR から推論（auto-merge hook のフォールバックと対称）。
# codex は条件付き起動のため reminder ではなく実 PR 番号を解決し、起動可否は後段の
# codex_trigger_evaluate に委ねる。gh の異常出力混入を避けるため純粋な整数のときのみ採用する。
if [ -z "$PR_NUM" ] && [ -n "$CWD" ] && [ -d "$CWD" ]; then
  PR_NUM=$( (cd "$CWD" && gh pr view --json number --jq '.number' 2>/dev/null) | grep -oE '^[0-9]+$' | head -1 || true)
fi

# PR 番号が抽出できない場合はスキップ（条件評価には PR 番号が必須）
if [ -z "$PR_NUM" ]; then
  exit 0
fi

# Codex CLI 利用可能性チェック（companion script 経由）
# パス解決の優先順位:
#   1. CODEX_COMPANION_SCRIPT 環境変数（テスト・カスタム配置向け）
#   2. $HOME/.claude/plugins/cache/openai-codex/codex/<version>/scripts/codex-companion.mjs の最新版
# バージョン番号や絶対パス（/Users/<user>/…）をハードコードしない（C1）
COMPANION="${CODEX_COMPANION_SCRIPT:-}"
if [ -z "$COMPANION" ] || [ ! -f "$COMPANION" ]; then
  # shellcheck disable=SC2012
  COMPANION=$(ls -t "$HOME"/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs 2>/dev/null | head -1 || true)
fi
if [ -z "$COMPANION" ] || [ ! -f "$COMPANION" ] || ! command -v node &>/dev/null; then
  exit 0
fi

CODEX_STATUS=$(node "$COMPANION" setup --json 2>/dev/null || echo '{}')
CODEX_READY=$(printf '%s' "$CODEX_STATUS" | jq -r '.ready // false')
if [ "$CODEX_READY" != "true" ]; then
  echo "Codex CLI が ready ではないため二次レビュー起動を抑止" >&2
  exit 0
fi

# 起動条件評価
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/codex-trigger-criteria.sh"

# stdout（起動理由 or 非該当理由）と stderr（システムエラー）を分離して取得
# m2 指摘: 旧実装の `2>&1` だと rc=1 と rc=2 が REASON 上で区別不能だった
REASON_FILE=$(mktemp)
ERR_FILE=$(mktemp)
trap 'rm -f "$REASON_FILE" "$ERR_FILE"' EXIT
if ! codex_trigger_evaluate "$PR_NUM" >"$REASON_FILE" 2>"$ERR_FILE"; then
  # rc=1（起動条件未満 / opt-out）も rc=2（gh / jq エラー）も静かに終了する設計だが、
  # rc=2 だけは stderr に診断ログを残してオペレーター追跡を可能にする
  if [ -s "$ERR_FILE" ]; then
    echo "codex-secondary-review hook: $(cat "$ERR_FILE")" >&2
  fi
  exit 0
fi
REASON=$(cat "$REASON_FILE")

# Note({ISSUE-ID}): コマンド名をスラッシュ記法ではなく「スキル名を起動」形式にすることで
#   cc-autoship 等プラグイン経由インストール時のプレフィックス（/cc-autoship:codex-secondary-review 等）と
#   CC 組込コマンドの衝突（shadowing）を回避する（sibling: post-tool-use-auto-merge-after-review.sh）
REMINDER="PR #${PR_NUM} は Codex 二次レビューの起動条件を満たしました（${REASON}）。codex-secondary-review スキルを起動してください（引数: ${PR_NUM}）。/auto-merge と並列で動作し、Codex 指摘は auto-merge 判定に影響しません（Claude 一次レビューが authoritative）。"

jq -n --arg ctx "$REMINDER" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}'
echo "PR #${PR_NUM}: /codex-secondary-review reminder emitted (${REASON})" >&2

exit 0