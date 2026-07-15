#!/bin/bash
# PR 分類器（full / light / strict）— {ISSUE-ID} Phase A
#
# 設計 SSoT: docs/superpowers/specs/2026-07-02-pr-flow-lightweight-classification-design.md
# 分類基準の値（閾値・strict 条件・タグ）の docs 側 SSoT: docs/rules/pr-flow-details.md「PR 分類（full / light / strict）」
#
# PR 後段フロー（review / auto-merge / pr-context-summary / Codex 二次レビュー）の
# 深さを決める最上位レイヤ。tiny PR（docs-only / test-only / 小差分）の後段固定費を削る。
#
# 方針:
#   - 判定順序は「strict > full > light」の先勝ち・安全側優先
#   - 分類基準の値（辞書・除外パターン）は既存純関数を source して共有し二重管理しない
#     * 実コード行数: categorize_diff_lines_from_files（auto-merge-criteria.sh）
#     * 危険操作・公開コンテンツ・UI 変更: check_dangerous_from_data / check_public_content_from_files
#       / ui_changed_apps_from_files（auto-merge-criteria.sh）
#     * security キーワード辞書・外部 API キーワード: check_security_intent_from_text
#       / check_keyword_from_files（codex-trigger-criteria.sh）
#   - 純関数 pr_class_from_data（テスト対象）と gh ラッパー pr_class_evaluate に分離
#   - gh 失敗・入力不正時は full にフォールバック（安全側・hook を止めない）
#
# 出力形式: stdout に "<class>\t<理由>"（class は light|full|strict）

set -uo pipefail

# 二重 source ガード（source 済みなら再定義せず即 return。readonly 再定義エラーも回避）
if [ -n "${_PR_CLASS_SH_LOADED:-}" ]; then
  # shellcheck disable=SC2317  # source でなく直接実行されたときのみ return が失敗し || true に到達する
  return 0 2>/dev/null || true
fi
_PR_CLASS_SH_LOADED=1

# source 元（bash: BASH_SOURCE / zsh: $0）相対で sibling lib / data を解決する。
# bash の hook 実行と zsh での source（スキル経由）双方で動くよう ${BASH_SOURCE[0]:-$0} を使う。
_PRCLASS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

# 既存純関数を再利用（辞書・除外パターンの二重管理を避ける）。
# 既に読み込み済みなら再 source しない（readonly 再定義エラーの回避）。
declare -f categorize_diff_lines_from_files >/dev/null 2>&1 \
  || source "${_PRCLASS_LIB_DIR:-.}/auto-merge-criteria.sh"
declare -f check_security_intent_from_text >/dev/null 2>&1 \
  || source "${_PRCLASS_LIB_DIR:-.}/codex-trigger-criteria.sh"

# light 閾値（設計判断 1 / メンテナ 承認 2026-07-02）: 実コード ≤ 50 行 かつ 変更ファイル ≤ 3（または実コード = 0）
readonly PR_CLASS_LIGHT_MAX_PROD_LINES=50
readonly PR_CLASS_LIGHT_MAX_FILES=3

# Pure: PR 本文に昇格タグ [full-review] が独立行であるかを判定
# Args: pr_body
# Returns: 0=あり, 1=なし
# タグ判定は既存の独立行純関数パターン（check_optin_from_body 系・{ISSUE-ID} 装飾誤検知対策）と同一。
#   - 独立行（前後が空白文字のみ）の [full-review] のみ true
#   - 装飾付き **[full-review]** / インラインコード `[full-review]` / 行内言及は無視
check_full_review_optin_from_body() {
  local pr_body="$1"
  if printf '%s' "$pr_body" | grep -qE '^[[:space:]]*\[full-review\][[:space:]]*$'; then
    return 0
  fi
  return 1
}

# Pure: files JSON + body + title から PR クラスを判定
# Args: files_json（gh pr view --json files の .files: [{path,additions,deletions},...]）body title
# Stdout: "<class>\t<理由>"（class: light|full|strict）
# Returns: 常に 0（クラスは stdout で伝える。呼び出し側で set -e 下でも止めない）
pr_class_from_data() {
  local files_json="$1" body="${2:-}" title="${3:-}"

  # 入力検証: files_json が有効な JSON 配列でなければ full フォールバック（安全側）
  if ! printf '%s' "$files_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf 'full\t入力不正（files JSON が配列でない）のため full フォールバック\n'
    return 0
  fi

  local file_list file_diff_list file_count
  file_list=$(printf '%s' "$files_json" | jq -r '.[].path // empty' 2>/dev/null)
  file_diff_list=$(printf '%s' "$files_json" | jq -r '.[] | "\(.path)\t\(.additions // 0)\t\(.deletions // 0)"' 2>/dev/null)
  file_count=$(printf '%s' "$files_json" | jq -r 'length' 2>/dev/null)
  [[ "$file_count" =~ ^[0-9]+$ ]] || file_count=0

  # 実コード行数（テスト・.md 除外）を SSoT 関数で算出
  local categorized prod_add prod_del td_add td_del
  categorized=$(categorize_diff_lines_from_files "$file_diff_list")
  read -r prod_add prod_del td_add td_del <<< "$categorized"
  local prod_total=$((prod_add + prod_del))
  local td_total=$((td_add + td_del))

  # ---- strict（先勝ち・安全側優先。タグでも降格不可） ----
  # ① security 変更（codex の security キーワード辞書を共有。title + body を対象）
  local sec_text
  sec_text=$(printf '%s\n%s' "$title" "$body")
  if check_security_intent_from_text "$sec_text"; then
    printf 'strict\tsecurity 変更を検知（codex キーワード辞書）\n'
    return 0
  fi
  # ④ 危険操作（migration/auth/課金/データ削除 = check_dangerous_from_data を共有。①の auth/migration パスも兼ねる）
  if ! check_dangerous_from_data "$file_list" "$body" >/dev/null 2>&1; then
    printf 'strict\t危険操作（migration/auth/課金/データ削除）を検知\n'
    return 0
  fi
  # ② 公開コンテンツ（data/public-content-paths.txt）
  if ! check_public_content_from_files "$file_list" >/dev/null 2>&1; then
    printf 'strict\t公開コンテンツへの変更を検知\n'
    return 0
  fi
  # ③ .github/workflows/**
  local f
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in
      .github/workflows/*)
        printf 'strict\t.github/workflows 変更を検知\n'
        return 0
        ;;
    esac
  done <<< "$file_list"
  # ⑤ 外部 API 連携ファイルの追加・変更（codex の外部 API キーワードパスを共有）
  if check_keyword_from_files "$file_list"; then
    printf 'strict\t外部 API 連携ファイルを検知\n'
    return 0
  fi

  # ---- full（[full-review] 昇格 / UI 変更は light 禁止） ----
  if check_full_review_optin_from_body "$body"; then
    printf 'full\t[full-review] タグによる昇格\n'
    return 0
  fi
  # UI 変更（frontend-apps.txt 配下のフロントコード）は必ず full 以上（L1 e2e gate・testing.md 整合）
  local frontend_apps_file frontend_apps ui_apps
  frontend_apps_file="${FRONTEND_APPS_FILE:-${_PRCLASS_LIB_DIR:-.}/../data/frontend-apps.txt}"
  frontend_apps=""
  [ -f "$frontend_apps_file" ] && frontend_apps=$(grep -vE '^[[:space:]]*(#|$)' "$frontend_apps_file" 2>/dev/null || true)
  ui_apps=$(ui_changed_apps_from_files "$file_list" "$frontend_apps")
  if [ -n "$ui_apps" ]; then
    local ui_apps_inline
    ui_apps_inline=$(printf '%s' "$ui_apps" | tr '\n' ' ' | sed 's/ *$//')
    printf 'full\tUI 変更（L1 e2e gate 対象: %s）\n' "$ui_apps_inline"
    return 0
  fi

  # ---- light ----
  if [ "$prod_total" -eq 0 ]; then
    printf 'light\t実コード 0 行（docs/test-only）・%s ファイル・テスト/docs %s 行\n' "$file_count" "$td_total"
    return 0
  fi
  if [ "$prod_total" -le "$PR_CLASS_LIGHT_MAX_PROD_LINES" ] && [ "$file_count" -le "$PR_CLASS_LIGHT_MAX_FILES" ]; then
    printf 'light\t実コード %s 行・%s ファイル（≤%s 行 / ≤%s ファイル）\n' \
      "$prod_total" "$file_count" "$PR_CLASS_LIGHT_MAX_PROD_LINES" "$PR_CLASS_LIGHT_MAX_FILES"
    return 0
  fi

  # ---- default full ----
  printf 'full\t実コード %s 行・%s ファイル（light 閾値 %s 行/%s ファイル 超）\n' \
    "$prod_total" "$file_count" "$PR_CLASS_LIGHT_MAX_PROD_LINES" "$PR_CLASS_LIGHT_MAX_FILES"
  return 0
}

# Pure: クラスから pr-context-summary の引数文字列を組み立てる（文言分岐の testable な純関数）
# Args: class pr_num
# Stdout: light のみ --lightweight を付与、full/strict は通常引数
pr_class_summary_args_from_class() {
  local class="$1" pr_num="$2"
  if [ "$class" = "light" ]; then
    printf '%s' "--mode pre-merge --pr ${pr_num} --lightweight"
  else
    printf '%s' "--mode pre-merge --pr ${pr_num}"
  fi
}

# Pure: クラスから review スキルの引数文字列を組み立てる（Phase B・文言分岐の testable な純関数）
# Args: class pr_num
# Stdout: light のみ "<pr_num> --light"（短縮レビュー）、full/strict は "<pr_num>"（現行文言）
pr_class_review_args_from_class() {
  local class="$1" pr_num="$2"
  if [ "$class" = "light" ]; then
    printf '%s' "${pr_num} --light"
  else
    printf '%s' "${pr_num}"
  fi
}

# gh から PR メタデータ（files/body/title）を 1 回で取得し pr_class_from_data に渡す
# Args: pr_number
# Stdout: "<class>\t<理由>"
# Returns: 常に 0（gh/jq 不在・gh 失敗時は full フォールバック。hook を止めない）
pr_class_evaluate() {
  local pr="$1"

  if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    printf 'full\tgh/jq 不在のため full フォールバック\n'
    return 0
  fi

  local pr_data
  if ! pr_data=$(gh pr view "$pr" --json files,body,title 2>/dev/null); then
    printf 'full\tgh pr view 失敗のため full フォールバック\n'
    return 0
  fi

  local files_json body title
  files_json=$(printf '%s' "$pr_data" | jq -c '.files // []' 2>/dev/null)
  body=$(printf '%s' "$pr_data" | jq -r '.body // ""' 2>/dev/null)
  title=$(printf '%s' "$pr_data" | jq -r '.title // ""' 2>/dev/null)

  pr_class_from_data "$files_json" "$body" "$title"
}