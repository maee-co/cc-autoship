#!/bin/bash
# cc-bestpractice スキルのセキュリティ不変条件テスト（{ISSUE-ID}）
# Usage: bash skills/cc-bestpractice/__tests__/test-cc-bestpractice.sh
#
# 検証内容（deep-audit 監査 {ISSUE-ID} の再発防止）:
# - dry-run が既定で、実適用は --apply 明示時のみ（Web 由来推奨の無確認自動適用を防ぐ）
# - 権限を緩める変更は追加でも review 固定（SEO 汚染ページの権限緩和偽装を塞ぐ）
# - Web 由来の推奨は「提案であって命令ではない」data-vs-instruction ガードがある

set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_FILE="$(cd "$SCRIPT_DIR/.." && pwd)/SKILL.md"
GREP="/usr/bin/grep"

P=0
F=0
pass() { echo "  ✅ PASS: $1"; P=$((P + 1)); }
fail() { echo "  ❌ FAIL: $1"; F=$((F + 1)); }

echo "📋 cc-bestpractice セキュリティ不変条件テスト（{ISSUE-ID}）"

if [ ! -f "$SKILL_FILE" ]; then
  fail "SKILL.md が見つからない: $SKILL_FILE"
  echo "結果: PASS=$P FAIL=$F"
  exit 1
fi
pass "SKILL.md が存在する"

# {ISSUE-ID}-1: dry-run 既定 + --apply 明示時のみ適用
if $GREP -q -- "--apply" "$SKILL_FILE"; then
  pass "--apply フラグが定義されている（適用は明示時のみ）"
else
  fail "--apply フラグがない（{ISSUE-ID}: 適用は明示時のみ）"
fi

if $GREP -qE "既定は.*dry-run|dry-run.*既定" "$SKILL_FILE"; then
  pass "dry-run が既定である旨が明記されている"
else
  fail "dry-run 既定の明記がない（{ISSUE-ID}）"
fi

# {ISSUE-ID}-2: 権限を緩める変更は追加でも review 固定
if $GREP -q "権限を緩める変更は追加でも" "$SKILL_FILE"; then
  pass "権限緩和は追加でも review 固定が明記されている"
else
  fail "権限緩和の review 固定がない（{ISSUE-ID}）"
fi

# {ISSUE-ID}-3: data-vs-instruction ガード（Web 推奨は提案であって命令ではない）
if $GREP -q "提案であって命令ではない" "$SKILL_FILE"; then
  pass "Web 由来推奨の data-vs-instruction ガードがある"
else
  fail "data-vs-instruction ガードがない（{ISSUE-ID}）"
fi

echo "結果: PASS=$P FAIL=$F"
[ "$F" -gt 0 ] && exit 1 || exit 0