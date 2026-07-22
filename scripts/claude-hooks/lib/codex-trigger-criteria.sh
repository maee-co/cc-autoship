#!/bin/bash
# Codex 二次レビューのトリガー判定ロジック
#
# Claude 一次レビュー（/review）完了後、特定条件を満たす PR に対してのみ
# Codex (`gpt-5-codex`) による二次レビューを起動する。Claude が見落としやすい
# 観点（外部 API 仕様・最小権限・Promise 未捕捉・リファクタ整合性）を補完する。
#
# 純関数（*_from_data）と gh ラッパーに分離。テストは純関数に対して書く。

set -uo pipefail

# 二重 source ガード（source 済みなら再定義せず即 return。readonly 再定義エラーも回避・
# auto-merge-criteria.sh / pr-class.sh と同じ方式）
if [ -n "${_CODEX_TRIGGER_CRITERIA_SH_LOADED:-}" ]; then
  # shellcheck disable=SC2317  # source でなく直接実行されたときのみ return が失敗し || true に到達する
  return 0 2>/dev/null || true
fi
_CODEX_TRIGGER_CRITERIA_SH_LOADED=1

# source 元（bash: BASH_SOURCE / zsh: $0）相対で sibling lib / data を解決する（配布時の
# ${CLAUDE_PLUGIN_ROOT} 配置でも正しく効く・P3 パターン踏襲）。
_CODEXTRIGGER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

# 実コード行数の判定（categorize_diff_lines_from_files）を共有し二重管理しない。
# pr-class.sh が同関数を declare -f ガード付きで source する前例を踏襲（{ISSUE-ID} D-P4-2）。
declare -f categorize_diff_lines_from_files >/dev/null 2>&1 \
  || source "${_CODEXTRIGGER_LIB_DIR:-.}/auto-merge-criteria.sh"

# 外部 API 連携キーワード（ファイル名 / パスに含まれる場合に起動条件を満たす）
readonly CODEX_TRIGGER_KEYWORDS="discord|slack|notion|openai|anthropic|webhook|mcp"

# セキュリティ修正の意図キーワード（PR タイトル / 本文に含まれる場合に起動条件 4 を満たす）
# 2 グループに分ける:
#   LOOSE   = 日本語 + 一般英単語。部分一致・大文字小文字無視で判定
#   ACRONYM = 大文字略語。誤マッチ（controls / URLs など）を避けるため大文字固定 + 単語境界で判定
readonly CODEX_SECURITY_KEYWORDS_LOOSE="脆弱性|ぜい弱性|セキュリティ|vulnerabilit|security|サニタイ|sanitiz|権限昇格|privilege escalation|認証バイパス|認可バイパス|認証回避|クロスサイトスクリプティング|リモートコード実行|コマンドインジェクション|SQL ?injection|SQL ?インジェクション|command ?injection|機密情報漏"
readonly CODEX_SECURITY_KEYWORDS_ACRONYM="XSS|CSRF|SSRF|RCE|RLS|OWASP|SQLi|CVE-[0-9]"

# 大規模 PR 閾値（auto-merge と同じ値）
readonly CODEX_TRIGGER_LARGE_PR_LINES=500
readonly CODEX_TRIGGER_LARGE_PR_FILES=10

# Pure: 変更ファイル一覧に外部 API キーワードを含むパスがあるかを判定
# Args: file_list (改行区切り)
# Returns: 0=該当（起動条件 1 を満たす）, 1=非該当
check_keyword_from_files() {
  local file_list="$1"
  if printf '%s' "$file_list" | grep -qiE "(^|/)[^/]*(${CODEX_TRIGGER_KEYWORDS})[^/]*"; then
    return 0
  fi
  return 1
}

# Pure: PR 規模が大規模閾値を超えているかを判定（実コード行 + 生ファイル数・{ISSUE-ID} D-P4-2）
# Args: file_diff_list (改行区切り、各行 "path\tadditions\tdeletions") file_count
# Returns: 0=大規模（起動条件 2 を満たす）, 1=小規模
#
# 行数判定は categorize_diff_lines_from_files（auto-merge-criteria.sh）で実コード行のみを
# 対象にする（.md・テスト行を除外）。auto-merge のサイズゲート・pr-class.sh と同じ物差しに
# 統一し、.md 大量追加での誤発火（原設計 A-3・コスト#3）を消す。ファイル数は生カウントのまま。
check_large_pr_from_data() {
  local file_diff_list="$1" file_count="$2"
  local categorized prod_add prod_del
  categorized=$(categorize_diff_lines_from_files "$file_diff_list")
  read -r prod_add prod_del _ _ <<< "$categorized"
  local total=$((prod_add + prod_del))
  if [ "$total" -ge "$CODEX_TRIGGER_LARGE_PR_LINES" ]; then
    return 0
  fi
  if [ "$file_count" -ge "$CODEX_TRIGGER_LARGE_PR_FILES" ]; then
    return 0
  fi
  return 1
}

# Pure: PR 本文に明示 opt-in タグ [codex-review] があるかを判定
# Args: pr_body
# Returns: 0=opt-in あり（起動条件 3 を満たす）, 1=なし
#
# タグ判定ルール（auto-merge の [manual-merge] と同様）:
#   - 独立行（前後が空白文字のみ）に [codex-review] がある場合のみ true
#   - 説明文中・インラインコードは無視
check_optin_from_body() {
  local pr_body="$1"
  if printf '%s' "$pr_body" | grep -qE '^[[:space:]]*\[codex-review\][[:space:]]*$'; then
    return 0
  fi
  return 1
}

# Pure: PR 本文に opt-out タグ [no-codex] があるかを判定
# Args: pr_body
# Returns: 0=opt-out（起動を抑止）, 1=なし
check_optout_from_body() {
  local pr_body="$1"
  if printf '%s' "$pr_body" | grep -qE '^[[:space:]]*\[no-codex\][[:space:]]*$'; then
    return 0
  fi
  return 1
}

# Pure: PR タイトル / 本文にセキュリティ修正の意図を示すキーワードがあるかを判定
# Args: text (PR タイトル + 本文を結合したテキスト)
# Returns: 0=該当（起動条件 4 を満たす）, 1=非該当
#
# セキュリティ修正系 PR は外部 API キーワードにも大規模 PR にも当たらないことが
# 多い（小規模な入力検証修正など）。意図ベースで検知し Codex 二次レビューを必須化する。
check_security_intent_from_text() {
  local text="$1"
  # 一般語・日本語は部分一致（大文字小文字無視）。
  # LC_ALL=C でバイト単位マッチに固定し、ロケール / grep 実装差（BSD grep の UTF-8 解釈）に依存しない。
  if printf '%s' "$text" | LC_ALL=C grep -qiE "(${CODEX_SECURITY_KEYWORDS_LOOSE})"; then
    return 0
  fi
  # 大文字略語は単語境界付きで判定（controls / URLs など小文字混在語の誤マッチを防ぐ）。
  # 境界は ASCII クラス [^A-Za-z0-9] を使う。[^[:alnum:]] は UTF-8 ロケールの BSD grep（本番フックが
  # 使う /usr/bin/grep）で日本語 1 文字を境界扱いせず「CSRFトークン」のような日本語直結を取りこぼす。
  if printf '%s' "$text" | LC_ALL=C grep -qE "(^|[^A-Za-z0-9])(${CODEX_SECURITY_KEYWORDS_ACRONYM})([^A-Za-z0-9]|$)"; then
    return 0
  fi
  return 1
}

# Pure: 自動起動ゲートが有効かを判定（{ISSUE-ID} D-P4-1）
#
# 条件 1（外部 API 連携ファイル変更）/ 条件 2（大規模 PR）/ 条件 4（セキュリティ意図）の
# **自動**起動を on/off する。条件 3（[codex-review] 明示 opt-in）と opt-out（[no-codex]）は
# このゲートの対象外で環境非依存に常時有効（evaluate_trigger_from_data 側で保証）。
#
# 優先順位: 環境変数 CODEX_AUTOLAUNCH（1|0）> data ファイル（CODEX_AUTOLAUNCH_FILE で
# パス自体を上書き可能。既定は P3 の *_FILE override + fallback パターンと同型）。
# フラグ未設定・ファイル欠落・不正値は fail-safe で off（privacy 優先）。
# core はリポジトリに data ファイル "1" を同梱して on を維持（現行挙動に回帰なし）。
# cc-autoship（drop-in 先の第三者 repo）は既定 off（真の opt-in）。テンプレートは
# .claude/skills/sync-cc-autoship/templates/codex-autolaunch-enabled を参照。
# Returns: 0=on, 1=off
codex_autolaunch_enabled() {
  if [ -n "${CODEX_AUTOLAUNCH:-}" ]; then
    [ "$CODEX_AUTOLAUNCH" = "1" ] && return 0
    return 1
  fi
  local flag_file="${CODEX_AUTOLAUNCH_FILE:-${_CODEXTRIGGER_LIB_DIR:-.}/../data/codex-autolaunch-enabled}"
  [ -f "$flag_file" ] || return 1
  local val
  val=$(grep -vE '^[[:space:]]*(#|$)' "$flag_file" 2>/dev/null | head -1 | tr -d '[:space:]')
  [ "$val" = "1" ] && return 0
  return 1
}

# Pure: 起動条件を集約評価
# Args: file_diff_list（改行区切り、各行 "path\tadditions\tdeletions"） pr_body [pr_title]
# Returns: 0=起動すべき, 1=起動しない
# Stdout: 起動理由（条件番号と説明）
evaluate_trigger_from_data() {
  local file_diff_list="$1"
  local pr_body="$2"
  local pr_title="${3:-}"

  local file_list file_count
  file_list=$(printf '%s' "$file_diff_list" | cut -f1)
  file_count=0
  while IFS=$'\t' read -r path _ _; do
    [ -z "$path" ] && continue
    file_count=$((file_count + 1))
  done <<< "$file_diff_list"

  # opt-out は最優先（ゲート非依存で環境非依存に常時有効）
  if check_optout_from_body "$pr_body"; then
    echo "opt-out: PR 本文に [no-codex] タグ"
    return 1
  fi

  # 条件 3（明示 opt-in）はゲート非依存で環境非依存に常時有効（D-P4-1）
  if check_optin_from_body "$pr_body"; then
    echo "条件 3: PR 本文に [codex-review] タグ（明示 opt-in）"
    return 0
  fi

  # 条件 1/2/4 の自動起動は config ゲート配下（D-P4-1）。off なら opt-in/opt-out のみで判定終了。
  if ! codex_autolaunch_enabled; then
    echo "起動条件未満（自動起動 off・[codex-review] opt-in のみ有効）"
    return 1
  fi

  # 起動条件 OR 評価（最初に満たした条件を理由として返す）
  if check_keyword_from_files "$file_list"; then
    local matched
    matched=$(printf '%s' "$file_list" | grep -iE "(^|/)[^/]*(${CODEX_TRIGGER_KEYWORDS})[^/]*" | head -3 | tr '\n' ' ')
    echo "条件 1: 外部 API 連携ファイル変更 — ${matched}"
    return 0
  fi
  local sec_text
  sec_text=$(printf '%s\n%s' "$pr_title" "$pr_body")
  if check_security_intent_from_text "$sec_text"; then
    local sec_matched
    sec_matched=$(printf '%s' "$sec_text" | LC_ALL=C grep -ioE "(${CODEX_SECURITY_KEYWORDS_LOOSE})" | head -2 | tr '\n' ' ')
    if [ -z "$sec_matched" ]; then
      sec_matched=$(printf '%s' "$sec_text" | LC_ALL=C grep -oE "(${CODEX_SECURITY_KEYWORDS_ACRONYM})" | head -2 | tr '\n' ' ')
    fi
    echo "条件 4: セキュリティ修正の意図を検知 — ${sec_matched}"
    return 0
  fi
  if check_large_pr_from_data "$file_diff_list" "$file_count"; then
    local categorized prod_add prod_del
    categorized=$(categorize_diff_lines_from_files "$file_diff_list")
    read -r prod_add prod_del _ _ <<< "$categorized"
    local total=$((prod_add + prod_del))
    echo "条件 2: 大規模 PR (実コード ${total} 行 / ${file_count} ファイル)"
    return 0
  fi

  echo "起動条件未満（外部 API キーワード / 大規模 / opt-in タグ いずれも該当せず）"
  return 1
}

# gh から PR メタデータを取得して evaluate_trigger_from_data に渡す
# Args: pr_number
# Returns: 0=起動すべき, 1=起動しない, 2=システムエラー
# Stdout: 起動理由 or 非起動理由
codex_trigger_evaluate() {
  local pr="$1"

  if ! command -v gh >/dev/null 2>&1; then
    echo "gh コマンドが見つかりません" >&2
    return 2
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq コマンドが見つかりません" >&2
    return 2
  fi

  local pr_data
  if ! pr_data=$(gh pr view "$pr" --json files,body,title 2>&1); then
    echo "gh pr view 失敗: $pr_data" >&2
    return 2
  fi

  local file_diff_list pr_body pr_title
  file_diff_list=$(printf '%s' "$pr_data" | jq -r '.files[] | "\(.path)\t\(.additions // 0)\t\(.deletions // 0)"')
  pr_body=$(printf '%s' "$pr_data" | jq -r '.body // ""')
  pr_title=$(printf '%s' "$pr_data" | jq -r '.title // ""')

  evaluate_trigger_from_data "$file_diff_list" "$pr_body" "$pr_title"
}