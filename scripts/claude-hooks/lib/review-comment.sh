#!/usr/bin/env bash
# review-comment.sh — レビュー結果コメントの検知ロジック共通ライブラリ
#
# post-tool-use-codex-secondary-review.sh と post-tool-use-auto-merge-after-review.sh は
# `gh pr comment` の本文に「## レビュー結果」等の見出しがあるかで起動を判定する。
# 旧実装は `tool_input.command` の **コマンド文字列** を grep していたため、
# `gh pr comment <PR> --body-file <path>` 経路だとコマンド引数にファイルパスしか現れず
# 本文の見出しが grep にマッチせず静かに終了していた（→ Codex 二次レビュー / auto-merge が不発）。
#
# 本 lib は body-file が指定されていればその中身を、なければコマンド文字列（inline `--body`）を
# 「検知対象テキスト」として返し、`--body` inline / `--body-file` 双方で見出しを拾えるようにする。
# 見出し検知の正規表現は両 hook で重複していたものをここに SSoT 化する。
#
# 純関数ライブラリ。テストは scripts/claude-hooks/__tests__/test-review-comment.sh。
#
# 公開関数:
#   - rc_has_review_heading <text>           : レビュー結果見出しを含むか（SSoT 正規表現）
#   - rc_extract_body_file_path <command>    : --body-file / -F のパスを抽出（クォート対応トークナイザ）
#   - rc_read_body_file <raw_path> [cwd]     : パスを解決してファイル本文を出力
#   - rc_resolve_detection_text <command> [cwd] : 検知対象テキスト（body-file 本文 or コマンド文字列）を返す
#
# 設計メモ:
#   - PR 番号抽出は本 lib では扱わない（呼び出し側がコマンド文字列から抽出する。
#     body 内容から誤抽出するのを避けるため）。
#   - body-file が読めた場合、検知対象は **本文に限定** する（コマンド文字列を混ぜない）。
#     これにより `--body-file "/tmp/## レビュー結果.md"` のような **パス名** が見出し誤検知を
#     起こす経路を塞ぐ（{ISSUE-ID} 二次レビューの Major 指摘）。
#   - body-file パスの抽出はクォート対応トークナイザで行い、inline `--body "... --body-file /x ..."`
#     のように **本文中で言及された** `--body-file` を実フラグと誤認しない（任意ファイル読み取り防止）。
#   - `set -e` を含めない（呼び出し側が `if rc_...; then` の真偽判定に使えるようにするため）。
#     直接実行時のみ strict mode を有効化し、source 先の親シェルに設定を漏らさない。
#
# 既知の制限:
#   - body-file パスにシェル変数（`$VAR` / `${VAR}`）を含む場合は解決しない（eval しない）。
#     `~/` の tilde 展開のみサポートする。mktemp 等で literal な絶対/相対パスを渡す経路を主対象とする。
#   - トークナイザは引用符（`'...'` / `"..."`）を解釈するが、バックスラッシュエスケープ・heredoc・
#     コマンド置換は解釈しない（hook 入力の `gh pr comment` では発生しない構造）。

# 直接実行した場合のみ strict mode を有効化する（source 時は親の設定を尊重）
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -uo pipefail
fi

# レビュー結果コメントの見出し検知パターン（SSoT）
# 検知対象: "## レビュー結果" / "## レビュー指摘修正結果" / "## レビュー指摘" / "## 🤖 一次レビュー" 等
# `[^#]*?` で見出し記号の直後に絵文字等が入るケースも許容しつつ、本文中の単なる言及は弾く。
RC_REVIEW_HEADING_PATTERN='##[[:space:]]*[^#]*?(レビュー結果|レビュー指摘修正結果|レビュー指摘|一次レビュー)'

# rc_has_review_heading: テキストにレビュー結果見出しが含まれるか判定
# 入力: $1 = 検査対象テキスト（複数行可）
# 戻り値: 0 = 含む / 1 = 含まない
rc_has_review_heading() {
  local text="${1:-}"
  # 言語不変マーカー（#N の構造解決・{ISSUE-ID}）優先 + 既存の日本語見出しパターン（後方互換）
  printf '%s' "$text" | grep -qE "$RC_REVIEW_HEADING_PATTERN" && return 0
  printf '%s' "$text" | grep -qE '<!--[[:space:]]*review-verdict:[[:space:]]*(pass|needs-review|fail)[[:space:]]*-->'
}

# `--fix` 結果コメントの見出し（`## レビュー指摘修正結果`）専用パターン（#N 判断 1）。
# 通常レビュー（`## レビュー結果` / `## 🤖 一次レビュー`）は判定ステータスを持つが、--fix コメントは
# 持たないため auto-merge の判定根拠にできない。hook はこれで区別し、--fix 後は再 /review を促す。
# 注: `レビュー指摘修正結果` は `レビュー結果` を部分文字列に含まない（レビュー→指摘→修正→結果）ため誤検知しない。
RC_FIX_RESULT_HEADING_PATTERN='##[[:space:]]*[^#]*?レビュー指摘修正結果'

# rc_is_fix_result_heading: テキストが --fix の修正結果見出しを含むか判定
# 入力: $1 = 検査対象テキスト（複数行可）
# 戻り値: 0 = 含む / 1 = 含まない
rc_is_fix_result_heading() {
  local text="${1:-}"
  printf '%s' "$text" | grep -qE "$RC_FIX_RESULT_HEADING_PATTERN"
}

# _rc_shell_tokenize: コマンド文字列を引用符を解釈してトークン分割（1 行 1 トークンで出力）
# - シングル / ダブルクォートで囲まれた領域は 1 トークンにまとめ、クォート自体は除去する
# - クォート外の空白 / タブでトークンを区切る
# これにより inline `--body "... --body-file /x ..."` のクォート内 `--body-file` は本文トークンの
# 一部となり、独立した実フラグとは区別される。
_rc_shell_tokenize() {
  local s="${1:-}"
  local i=0 len=${#s} ch quote='' tok='' have=0
  while [ "$i" -lt "$len" ]; do
    ch="${s:$i:1}"
    if [ -n "$quote" ]; then
      if [ "$ch" = "$quote" ]; then
        quote=''
      else
        tok+="$ch"; have=1
      fi
    else
      case "$ch" in
        \'|\")     quote="$ch"; have=1 ;;
        ' '|$'\t') if [ "$have" = 1 ]; then printf '%s\n' "$tok"; tok=''; have=0; fi ;;
        *)         tok+="$ch"; have=1 ;;
      esac
    fi
    i=$((i + 1))
  done
  [ "$have" = 1 ] && printf '%s\n' "$tok"
  return 0
}

# rc_extract_body_file_path: コマンド文字列から --body-file / -F のパスを抽出
# 対応形式: --body-file <path> / --body-file=<path> / -F <path> / -F=<path>
#   （値のクォートはトークナイザが除去。クォート内に空白を含むパスにも対応）
# 入力: $1 = コマンド文字列
# 出力: 抽出したパス
# 戻り値: 0 = 抽出成功 / 1 = body-file 指定なし
rc_extract_body_file_path() {
  local cmd="${1:-}"
  [ -z "$cmd" ] && return 1
  # 複数行コマンド（行継続・複数行 body 等）でもクォート内言及を実フラグと誤認しないよう改行を空白に潰す
  cmd="${cmd//$'\n'/ }"

  local found_flag=0 tok
  while IFS= read -r tok; do
    if [ "$found_flag" = 1 ]; then
      printf '%s' "$tok"
      return 0
    fi
    case "$tok" in
      --body-file=*) printf '%s' "${tok#--body-file=}"; return 0 ;;
      -F=*)          printf '%s' "${tok#-F=}"; return 0 ;;
      --body-file|-F) found_flag=1 ;;
    esac
  done < <(_rc_shell_tokenize "$cmd")
  return 1
}

# rc_read_body_file: body-file パスを解決してファイル本文を出力
# 解決順: 絶対パス優先 → 相対は cwd 基準 → PWD 基準 → そのまま。`~/` は $HOME に展開。
# 入力: $1 = パス（クォート除去済み想定）, $2 = cwd（省略可）
# 出力: ファイル本文（読めた場合のみ）
# 戻り値: 0 = 読めた / 1 = stdin(-) / 空 / 解決不能 / 読めない
rc_read_body_file() {
  local raw="${1:-}"
  local cwd="${2:-}"
  [ -z "$raw" ] && return 1
  # stdin マーカー（-）は hook からは読めないのでスキップ
  [ "$raw" = "-" ] && return 1

  local p="$raw"
  # case パターンとしての "~" はリテラル一致が目的（展開を期待していない）。SC2088 は誤検知。
  # shellcheck disable=SC2088
  case "$p" in
    "~/"*) p="${HOME}/${p#\~/}" ;;
    "~")   p="${HOME}" ;;
  esac

  local -a candidates=()
  case "$p" in
    /*) candidates+=("$p") ;;
    *)
      [ -n "$cwd" ] && candidates+=("$cwd/$p")
      candidates+=("$PWD/$p")
      candidates+=("$p")
      ;;
  esac

  local c
  for c in "${candidates[@]}"; do
    if [ -f "$c" ] && [ -r "$c" ]; then
      cat -- "$c"
      return 0
    fi
  done
  return 1
}

# rc_resolve_detection_text: 検知対象テキストを返す
#   - body-file が指定され読めれば → その **本文のみ**（コマンド文字列のパス名等による誤検知を防ぐ）
#   - body-file 指定だが読めない → コマンド文字列にフォールバック（取りこぼし=false negative を避ける）
#   - body-file 指定なし（inline `--body`） → コマンド文字列
# 入力: $1 = コマンド文字列, $2 = cwd（省略可）
# 出力: 検知対象テキスト
# 戻り値: 常に 0（フェイルセーフ）
rc_resolve_detection_text() {
  local cmd="${1:-}"
  local cwd="${2:-}"

  local path=""
  path=$(rc_extract_body_file_path "$cmd") || path=""
  if [ -n "$path" ]; then
    local content
    if content=$(rc_read_body_file "$path" "$cwd"); then
      printf '%s' "$content"
      return 0
    fi
    # body-file 指定だが読めない（変数パス等）→ コマンド文字列にフォールバック
  fi

  printf '%s' "$cmd"
}