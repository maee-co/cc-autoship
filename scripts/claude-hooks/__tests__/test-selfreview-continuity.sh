#!/usr/bin/env bash
# /review・/auto-merge の「同一セッション実装 → レビュー → マージは設計どおり」ガイドの
# 存在を固定する（{ISSUE-ID} / {ISSUE-ID}-B）。
#
# 背景: cc-autoship 0.1.7 の P6 クリーンラン（demo repo・auto mode）で、実行セッションが
#   ゲート全緑にもかかわらず「実装とレビューが同一セッションのため自己承認しない」と
#   自主判断して判定を `要確認` に降格し、/auto-merge を実行せず停止した。`要確認` は
#   check_review_status_from_text が決定的にパースして auto-merge を機械ブロックするため、
#   review.md / auto-merge.md に「同一セッション一気通貫は設計された標準動作」を明示して
#   著者性を理由とした降格・ハンドオフを仕様で封じる。本テストはその文言の存在（と
#   判定節への配置）を回帰検知する。
#
# runner 規約: test-runner.sh が PASS/FAIL/ERRORS と assert_* / 色変数を注入し、
#   本ファイルを source して $FAIL を exit code 扱いする。
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
REVIEW_MD="$ROOT/commands/review.md"
AM_MD="$ROOT/commands/auto-merge.md"

echo "test-selfreview-continuity: 同一セッション自己承認降格の仕様封じ（{ISSUE-ID}）"

# --- review.md: 判定ステータス定義の節（最初の「**判定ステータス**」以降）にガイドがある ---
VERDICT_SECTION="$(awk '/\*\*判定ステータス\*\*/{f=1} f{print} f&&/^---$/{exit}' "$REVIEW_MD")"

if [ -n "$VERDICT_SECTION" ]; then
  PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} review.md の判定ステータス節を抽出できる"
else
  FAIL=$((FAIL + 1)); ERRORS+=("review.md の判定ステータス節を抽出できる: 空"); echo -e "  ${RED}✗${NC} review.md の判定ステータス節を抽出できる（空）"
fi

assert_contains "同一セッション" "$VERDICT_SECTION" "review.md 判定節: 同一セッションへの言及がある"
assert_contains "自己承認" "$VERDICT_SECTION" "review.md 判定節: 自己承認（にあたらない旨）への言及がある"
assert_contains "設計" "$VERDICT_SECTION" "review.md 判定節: 設計どおりである旨の明示がある"

# 降格禁止: 「著者性を理由に 要確認 に降格しない」趣旨の文（要確認 + 降格 の共起）
if printf '%s' "$VERDICT_SECTION" | grep -q "降格"; then
  PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} review.md 判定節: 要確認への降格禁止が明示されている"
else
  FAIL=$((FAIL + 1)); ERRORS+=("review.md 判定節: 要確認への降格禁止が明示されている: '降格' 不在"); echo -e "  ${RED}✗${NC} review.md 判定節: 要確認への降格禁止が明示されている"
fi

# --- auto-merge.md: 「同一セッションでも必ず実行」ガイドがある ---
assert_contains "同一セッション" "$(cat "$AM_MD")" "auto-merge.md: 同一セッションへの言及がある"
assert_contains "必ず実行" "$(cat "$AM_MD")" "auto-merge.md: pass 時に必ず実行する旨の明示がある"

# --- 既存ゲートの不変条件: ガイド追加が要確認/fail の定義そのものを消していない ---
assert_contains '`要確認`' "$VERDICT_SECTION" "review.md 判定節: 要確認 の定義が残っている"
assert_contains '`fail`' "$VERDICT_SECTION" "review.md 判定節: fail の定義が残っている"