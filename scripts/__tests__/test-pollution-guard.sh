#!/usr/bin/env bash
# scripts/__tests__/test-pollution-guard.sh
#
# MAE-303: pollution-guard.sh の各パターン検出を検証する純関数テスト。
# 各テストは独立した TMPDIR で実行され、既存パターンおよび MAE-303 追加パターン
# （#ceo-asks / /Users/mae / ' #数字' / Kana Fujisawa）の検出を確認する。

set -uo pipefail

GUARD="$(cd "$(dirname "$0")/.." && pwd)/pollution-guard.sh"

PASS=0
FAIL=0
FAIL_DETAILS=()

assert() {
  local desc="$1"
  local rc="$2"
  if [ "$rc" -eq 0 ]; then
    PASS=$((PASS + 1))
    echo "  ✓ $desc"
  else
    FAIL=$((FAIL + 1))
    FAIL_DETAILS+=("$desc")
    echo "  ✗ $desc"
  fi
}

# --- helpers ---

make_tmpdir() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/rules"
  echo "$d"
}

run_guard_rc() {
  local root="$1"
  local rc=0
  bash "$GUARD" "$root" >/dev/null 2>&1 || rc=$?
  echo "$rc"
}

# ─────────────────────────────────────────────
echo "[1] クリーン: 汚染なしの場合は PASS (exit 0)"

tmpdir=$(make_tmpdir)
echo "This content is clean." > "$tmpdir/rules/clean.md"
rc=$(run_guard_rc "$tmpdir"); rm -rf "$tmpdir"
assert "クリーン dir は exit 0" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"

# ─────────────────────────────────────────────
echo "[2] 既存パターン検出"

tmpdir=$(make_tmpdir)
# MAE-XXX: concatenate to avoid self-detection by the guard when scanning scripts/
echo "ref MAE-""123 was fixed" > "$tmpdir/rules/ref.md"
rc=$(run_guard_rc "$tmpdir"); rm -rf "$tmpdir"
assert "MAE-番号を検出 (exit 1)" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"

tmpdir=$(make_tmpdir)
echo "user@""maee.co has access" > "$tmpdir/rules/ref.md"
rc=$(run_guard_rc "$tmpdir"); rm -rf "$tmpdir"
assert "@maee.co を検出 (exit 1)" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"

tmpdir=$(make_tmpdir)
echo "app: diggly" > "$tmpdir/rules/app.md"
rc=$(run_guard_rc "$tmpdir"); rm -rf "$tmpdir"
assert "アプリ名 diggly を検出 (exit 1)" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"

# ─────────────────────────────────────────────
echo "[3] 新規パターン: #ceo-asks チャンネル名"

# Use variable split to avoid self-detection in scripts/
SLACK_PREFIX="#ceo"; SLACK_SUFFIX="-asks"
tmpdir=$(make_tmpdir)
echo "post to ${SLACK_PREFIX}${SLACK_SUFFIX} for approval" > "$tmpdir/rules/slack.md"
rc=$(run_guard_rc "$tmpdir"); rm -rf "$tmpdir"
assert "#ceo-asks を検出 (exit 1)" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"

tmpdir=$(make_tmpdir)
echo "post to #help for questions" > "$tmpdir/rules/slack_clean.md"
rc=$(run_guard_rc "$tmpdir"); rm -rf "$tmpdir"
assert "無関係チャンネル #help はスルー (exit 0)" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"

# ─────────────────────────────────────────────
echo "[4] 新規パターン: マシン固有絶対パス /Users/mae"

PATH_PREFIX="/Users/"; PATH_SUFFIX="mae"
tmpdir=$(make_tmpdir)
echo "path: ${PATH_PREFIX}${PATH_SUFFIX}/Works/core" > "$tmpdir/rules/path.md"
rc=$(run_guard_rc "$tmpdir"); rm -rf "$tmpdir"
assert "/Users/mae を検出 (exit 1)" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"

tmpdir=$(make_tmpdir)
echo "path: /Users/someone/projects" > "$tmpdir/rules/path_clean.md"
rc=$(run_guard_rc "$tmpdir"); rm -rf "$tmpdir"
assert "/Users/someone はスルー (exit 0)" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"

# ─────────────────────────────────────────────
echo "[5] 新規パターン: core 内部 PR/Issue 番号コメント ( #数字)"

# Construct with split to avoid self-detection
HASH_REF=" #""654"
tmpdir=$(make_tmpdir)
echo "see${HASH_REF} for details" > "$tmpdir/rules/prref.md"
rc=$(run_guard_rc "$tmpdir"); rm -rf "$tmpdir"
assert "' #654' を検出 (exit 1)" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"

tmpdir=$(make_tmpdir)
echo "refer to issue-654 for details" > "$tmpdir/rules/prref_clean.md"
rc=$(run_guard_rc "$tmpdir"); rm -rf "$tmpdir"
assert "issue-654 形式はスルー (exit 0)" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"

# markdown heading: "## Section" should not match (has space, no digit immediately after #)
tmpdir=$(make_tmpdir)
echo "## Section header" > "$tmpdir/rules/heading.md"
rc=$(run_guard_rc "$tmpdir"); rm -rf "$tmpdir"
assert "markdown 見出し ## Section はスルー (exit 0)" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"

# ─────────────────────────────────────────────
echo "[6] 新規パターン: メンテナ実名"

# Split to avoid self-detection in this test file
FIRST_NAME="Kana"; LAST_NAME=" Fujisawa"
tmpdir=$(make_tmpdir)
echo "author: ${FIRST_NAME}${LAST_NAME}" > "$tmpdir/rules/name.md"
rc=$(run_guard_rc "$tmpdir"); rm -rf "$tmpdir"
assert "実名 Kana Fujisawa を検出 (exit 1)" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"

tmpdir=$(make_tmpdir)
echo "author: Alice Smith" > "$tmpdir/rules/name_clean.md"
rc=$(run_guard_rc "$tmpdir"); rm -rf "$tmpdir"
assert "別名 Alice Smith はスルー (exit 0)" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"

# ─────────────────────────────────────────────
echo "[7] __tests__/ は除外される（テストファイル自身は污染扱いしない）"

tmpdir=$(make_tmpdir)
mkdir -p "$tmpdir/scripts/__tests__"
# Write an actual MAE-reference inside __tests__/
echo "MAE-""999 fixture" > "$tmpdir/scripts/__tests__/fixture.md"
rc=$(run_guard_rc "$tmpdir"); rm -rf "$tmpdir"
assert "__tests__/ 内の汚染文字列は除外 (exit 0)" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"

# ─────────────────────────────────────────────
echo ""
echo "Result: passed=$PASS failed=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed:"
  for d in "${FAIL_DETAILS[@]}"; do echo "  ✗ $d"; done
  exit 1
fi
