#!/bin/bash
# SessionStart reminder: open な maintenance Issue を 1 行 nudge する純関数。
set -uo pipefail

# Pure: open maintenance Issue 一覧（stdin: "番号<TAB>タイトル" の行）→ nudge 文。
# 0 行 / 空行のみなら空文字を返す（hook 側は空なら無音終了）。
# 自動適用はしない方針のため、apply コマンドの「案内」のみ行う。
maintenance_reminder_message() {
  local lines count first_num
  lines=$(cat)
  count=$(printf '%s\n' "$lines" | grep -c . || true)
  [ "${count:-0}" -gt 0 ] || { echo ""; return; }
  first_num=$(printf '%s\n' "$lines" | grep -m1 . | cut -f1)
  # バッククォートは Markdown のコード装飾として出力する literal（コマンド置換ではない）
  # shellcheck disable=SC2016
  printf '📋 未適用の repo-maintenance Issue が %d 件あります。`/repo-maintenance --apply %s` で safe 項目を適用できます（自動適用はしません）。' \
    "$count" "$first_num"
}