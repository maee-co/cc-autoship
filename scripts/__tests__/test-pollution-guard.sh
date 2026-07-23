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
echo "[8] #1814: 全角記号前置の #番号 を検出（旧実装は半角スペース前置のみ）"

HASH="#"
tmpdir=$(make_tmpdir)
printf 'gate は最新のみ信頼・%s1198 判断 1\n' "$HASH" > "$tmpdir/rules/msg.md"
rc=$(run_guard_rc "$tmpdir"); rm -rf "$tmpdir"
assert "・#番号（全角中黒前置）を検出 (exit 1)" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"

tmpdir=$(make_tmpdir)
printf '反映は公開当日（%s1195）。\n' "$HASH" > "$tmpdir/rules/paren.md"
rc=$(run_guard_rc "$tmpdir"); rm -rf "$tmpdir"
assert "（#番号（全角括弧前置）を検出 (exit 1)" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"

tmpdir=$(make_tmpdir)
printf 'color: %s112233; background: %sf0f0f0\n' "$HASH" "$HASH" > "$tmpdir/rules/color.md"
rc=$(run_guard_rc "$tmpdir"); rm -rf "$tmpdir"
assert "6 桁 hex 色はスルー (exit 0)" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"

# ─────────────────────────────────────────────
echo "[8b] MAE-954: 5 桁以上の内部 #番号（{2,4} 上限では未検出だった）を検出"

tmpdir=$(make_tmpdir)
printf 'see%s12345 for details\n' " #" > "$tmpdir/rules/five_digit.md"
rc=$(run_guard_rc "$tmpdir"); rm -rf "$tmpdir"
assert "' #12345'（5 桁・半角スペース前置）を検出 (exit 1)" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"

tmpdir=$(make_tmpdir)
printf 'gate は最新のみ信頼・%s12345 判断 1\n' "$HASH" > "$tmpdir/rules/five_digit_fullwidth.md"
rc=$(run_guard_rc "$tmpdir"); rm -rf "$tmpdir"
assert "・#12345（5 桁・全角中黒前置）を検出 (exit 1)" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"

tmpdir=$(make_tmpdir)
printf 'color: %s112233; background: %sf0f0f0\n' "$HASH" "$HASH" > "$tmpdir/rules/color_2to5.md"
rc=$(run_guard_rc "$tmpdir"); rm -rf "$tmpdir"
assert "{2,5} 上限でも 6 桁 hex 色はスルー (exit 0)" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"

# ─────────────────────────────────────────────
echo "[9] #1814: private repo URL（github.com/maee-co/core）を検出"

tmpdir=$(make_tmpdir)
echo "see https://github.com/maee-co/""core/issues/912" > "$tmpdir/rules/url.md"
rc=$(run_guard_rc "$tmpdir"); rm -rf "$tmpdir"
assert "maee-co/core への実 URL を検出 (exit 1)" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"

tmpdir=$(make_tmpdir)
echo "dev repo is github.com/maee-co/cc-autoship-dev" > "$tmpdir/rules/devurl.md"
rc=$(run_guard_rc "$tmpdir"); rm -rf "$tmpdir"
assert "cc-autoship-dev 言及はスルー（透明性許容・exit 0）" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"

# ─────────────────────────────────────────────
echo "[10] #1814: 除外リスト方式 — .github/ 等の非列挙ディレクトリも走査する"

tmpdir=$(make_tmpdir)
mkdir -p "$tmpdir/.github"
echo "funding: MAE-""123 の手順で" > "$tmpdir/.github/FUNDING.yml"
rc=$(run_guard_rc "$tmpdir"); rm -rf "$tmpdir"
assert ".github/ 配下の汚染を検出 (exit 1)" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"

tmpdir=$(make_tmpdir)
mkdir -p "$tmpdir/docs"
echo "internal ops MAE-""123（release 配置時に除外される内部手順）" > "$tmpdir/docs/repo-meta.md"
rc=$(run_guard_rc "$tmpdir"); rm -rf "$tmpdir"
assert "docs/repo-meta.md は除外（release 非配置・exit 0）" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"

tmpdir=$(make_tmpdir)
mkdir -p "$tmpdir/.claude-plugin"
printf '{"author": {"name": "Kana Fujisawa"}}\n' > "$tmpdir/.claude-plugin/plugin.json"
rc=$(run_guard_rc "$tmpdir"); rm -rf "$tmpdir"
assert ".claude-plugin/ の author 実名は除外（意図的 attribution・exit 0）" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"

tmpdir=$(make_tmpdir)
printf 'MIT License\n\nCopyright (c) 2026 Kana Fujisawa\n' > "$tmpdir/LICENSE"
rc=$(run_guard_rc "$tmpdir"); rm -rf "$tmpdir"
assert "LICENSE の copyright 実名は除外（意図的 attribution・exit 0）" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"

# ─────────────────────────────────────────────
echo "[11] #1814 round 2: fail-close — 実在しない ROOT は ERROR (exit 2)"

rc=$(run_guard_rc "/nonexistent-pollution-guard-root-$$")
assert "実在しない ROOT は exit 2（PASSED にしない）" "$([ "$rc" -eq 2 ] && echo 0 || echo 1)"

# ─────────────────────────────────────────────
echo "[12] #1814 round 2: 社内ロール表記を検出、メンテナ表記はスルー"

tmpdir=$(make_tmpdir)
echo "この操作は C""EO の対応待ちです。" > "$tmpdir/rules/role.md"
rc=$(run_guard_rc "$tmpdir"); rm -rf "$tmpdir"
assert "C""EO 表記を検出 (exit 1)" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"

tmpdir=$(make_tmpdir)
echo "この操作はメンテナの対応待ちです。" > "$tmpdir/rules/role.md"
rc=$(run_guard_rc "$tmpdir"); rm -rf "$tmpdir"
assert "メンテナ表記はスルー (exit 0)" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"

# ─────────────────────────────────────────────
echo ""
echo "Result: passed=$PASS failed=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed:"
  for d in "${FAIL_DETAILS[@]}"; do echo "  ✗ $d"; done
  exit 1
fi
