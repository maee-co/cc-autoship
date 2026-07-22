#!/bin/bash
# hook-input.sh — PostToolUse hook 入力パースの共通ヘルパー
#
# 本番 PostToolUse の stdin は `.tool_response.*` を送る。公式ドキュメントは `.tool_output.*` と
# 記載するが、実際の runtime payload は `.tool_response`（稼働中の post-tool-use-failure.sh も
# `.tool_response.error // .tool_response.stderr` を参照している）。旧 pr-created hook は
# `.tool_output.stdout` のみを見ていたため本番で STDOUT が常に空になり、PR_NUM 依存の
# workflow scope チェックと PR 分類が一度も発火しなかった
# （{ISSUE-ID}/{ISSUE-ID}/{ISSUE-ID}/{ISSUE-ID} 実測）。本 lib は tool_response / tool_output 双方のスキーマを
# 多段フォールバックで吸収し、スキーマ差異に対して堅牢にする。
#
# 純関数（テスト対象）:
#   - hook_stdout_from_input <input_json> : tool 実行の stdout を多段フォールバックで抽出
#   - pr_num_from_stdout <text>           : stdout 内の GitHub PR URL から PR 番号を抽出
# gh ラッパー:
#   - pr_num_resolve <input_json>         : stdout 抽出 → 失敗時のみ gh pr view で最終フォールバック
#
# 設計メモ:
#   - `set -e` を含めない（呼び出し側が `if pr_num_from_stdout ...; then` の真偽判定に使えるよう）。
#     直接実行時のみ strict mode を有効化し、source 先の親シェルに設定を漏らさない。

# 直接実行した場合のみ strict mode を有効化する（source 時は親の設定を尊重）
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -uo pipefail
fi

# Pure: PostToolUse 入力 JSON から tool 実行の stdout を多段フォールバックで抽出する
# 優先順位: .tool_response.stdout → .tool_response.output → .tool_output.stdout
#           → .tool_response が文字列ならそのまま
# null / 空文字はスキップして次の候補を試す（明示的な空 stdout でフォールスルーさせるため）。
# Args: input_json
# Stdout: 抽出した stdout（候補が全て空なら空出力）
# Returns: 常に 0（フェイルセーフ）
hook_stdout_from_input() {
  local input="${1:-}"
  [ -z "$input" ] && return 0
  # try/catch で「.tool_response が文字列/欠落でも .stdout 参照でエラーにしない」を担保し、
  # 各候補を必ず 1 要素（値 or null）に正規化してから優先順位順に最初の非空を採る。
  printf '%s' "$input" | jq -r '
    def g(f): (try f catch null);
    [ g(.tool_response.stdout),
      g(.tool_response.output),
      g(.tool_output.stdout),
      (if (.tool_response | type) == "string" then .tool_response else null end)
    ] | map(select(. != null and . != "")) | .[0] // empty
  ' 2>/dev/null || true
}

# Pure: テキスト（tool stdout）から GitHub PR URL の PR 番号を抽出する
# Args: text
# Stdout: PR 番号（数字のみ）
# Returns: 0=抽出成功, 1=PR URL が無い / 番号を取れない
pr_num_from_stdout() {
  local text="${1:-}"
  [ -z "$text" ] && return 1
  local url
  url=$(printf '%s' "$text" | grep -oE 'https://github\.com/[^ ]+/pull/[0-9]+' | head -1)
  [ -z "$url" ] && return 1
  local num
  num=$(printf '%s' "$url" | grep -oE '[0-9]+$')
  [ -z "$num" ] && return 1
  printf '%s' "$num"
}

# gh ラッパー: 入力から PR 番号を解決する。
# stdout（多段フォールバック抽出）から取れればそれを、取れなければ gh pr view で最終フォールバック。
# gh 呼び出しは「stdout から取れなかった場合のみ」に限定（成功パスの追加コストゼロ）。
# hook の cwd は PR 作成ブランチの worktree なので `gh pr view`（無引数）で現ブランチの PR を解決できる。
# Args: input_json
# Stdout: PR 番号（解決できた場合のみ）
# Returns: 0=解決成功, 1=未解決（呼び出し側は空 = 従来どおり汎用リマインドに劣化）
pr_num_resolve() {
  local input="${1:-}"
  local stdout num
  stdout=$(hook_stdout_from_input "$input")
  if num=$(pr_num_from_stdout "$stdout"); then
    printf '%s' "$num"
    return 0
  fi
  # 最終フォールバック: gh pr view（stdout から PR 番号が取れなかった場合のみ）
  if command -v gh >/dev/null 2>&1; then
    num=$(gh pr view --json number -q .number 2>/dev/null || true)
    if [ -n "$num" ] && [[ "$num" =~ ^[0-9]+$ ]]; then
      printf '%s' "$num"
      return 0
    fi
  fi
  return 1
}