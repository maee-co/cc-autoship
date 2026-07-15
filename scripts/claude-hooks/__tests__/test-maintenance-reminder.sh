#!/bin/bash
# maintenance-reminder.sh の単体テスト
# shellcheck disable=SC1091
source "$HOOKS_DIR/lib/maintenance-reminder.sh"

echo "maintenance-reminder: open Issue ありで nudge 生成"
OUT=$(printf '253\t[infra] repo-maintenance 週次レポート\n254\t[infra] 別件\n' | maintenance_reminder_message)
assert_contains "2 件" "$OUT" "件数を表示"
assert_contains "apply 253" "$OUT" "先頭 Issue 番号で apply コマンドを案内"
assert_contains "自動適用はしません" "$OUT" "自動適用しない旨を明記（merge 規律）"

echo "maintenance-reminder: 1 件"
OUT=$(printf '253\t[infra] x\n' | maintenance_reminder_message)
assert_contains "1 件" "$OUT" "1 件表示"
assert_contains "apply 253" "$OUT" "apply 253"

echo "maintenance-reminder: 空入力は空"
OUT=$(printf '' | maintenance_reminder_message)
assert_eq "" "$OUT" "open Issue なしは空文字（hook が無音終了）"
OUT=$(printf '\n' | maintenance_reminder_message)
assert_eq "" "$OUT" "空行のみも空文字"