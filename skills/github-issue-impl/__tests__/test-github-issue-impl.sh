#!/bin/bash

# github-issue-impl スキルのサニティチェック（GitHub 完結版）
# Usage: bash skills/github-issue-impl/__tests__/test-github-issue-impl.sh
#
# 初回最小リリースの github-issue-impl は GitHub Issue のみで動作し、
# Linear など外部トラッカーには依存しないことを検証する。

set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_FILE="$SKILL_DIR/SKILL.md"

GREP_CMD="/usr/bin/grep"

TESTS_PASSED=0
TESTS_FAILED=0

pass() {
  echo "  ✅ PASS: $1"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
  echo "  ❌ FAIL: $1"
  TESTS_FAILED=$((TESTS_FAILED + 1))
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 github-issue-impl スキル サニティチェック（GitHub 完結）"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ─────────────────────────────────────────
echo "1. SKILL.md の存在"
# ─────────────────────────────────────────

if [ -f "$SKILL_FILE" ]; then
  pass "SKILL.md が存在する"
else
  fail "SKILL.md が見つからない: $SKILL_FILE"
  echo ""
  echo "結果: PASS=$TESTS_PASSED FAIL=$TESTS_FAILED"
  exit 1
fi

echo ""

# ─────────────────────────────────────────
echo "2. Linear に依存しない（GitHub 完結）"
# ─────────────────────────────────────────

if $GREP_CMD -q "mcp__claude_ai_Linear__" "$SKILL_FILE"; then
  fail "Linear MCP (mcp__claude_ai_Linear__) を参照している（GitHub 完結のはず）"
else
  pass "Linear MCP を参照していない（GitHub 完結）"
fi

if $GREP_CMD -q "mcp__linear-server__" "$SKILL_FILE"; then
  fail "旧 Linear エンドポイント mcp__linear-server__ が残存している"
else
  pass "旧 Linear エンドポイントが残存していない"
fi

# 除外した lib への参照がないこと
if $GREP_CMD -q "linear-status-update.sh" "$SKILL_FILE"; then
  fail "除外した linear-status-update.sh を参照している"
else
  pass "linear-status-update.sh を参照していない"
fi

echo ""

# ─────────────────────────────────────────
echo "3. GitHub Issue ベースのフロー"
# ─────────────────────────────────────────

if $GREP_CMD -qE "gh issue|GitHub Issue" "$SKILL_FILE"; then
  pass "GitHub Issue ベースのフローが記述されている"
else
  fail "GitHub Issue の記述がない"
fi

# worktree 隔離フローが残っていること（dev-flow の核）
if $GREP_CMD -q "worktree" "$SKILL_FILE"; then
  pass "worktree 隔離フローが記述されている"
else
  fail "worktree の記述がない"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "結果: PASS=%d FAIL=%d\n" "$TESTS_PASSED" "$TESTS_FAILED"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "$TESTS_FAILED" -gt 0 ]; then
  exit 1
else
  exit 0
fi
