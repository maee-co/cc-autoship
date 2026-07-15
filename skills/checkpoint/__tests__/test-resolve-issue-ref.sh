#!/usr/bin/env bash
# checkpoint スキルの Issue 参照判別ロジックのユニットテスト
# 実行: bash .claude/skills/checkpoint/__tests__/test-resolve-issue-ref.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/resolve-issue-ref.sh
source "$SCRIPT_DIR/../lib/resolve-issue-ref.sh"

pass=0
fail=0

# assert_classify REF EXPECTED_STDOUT EXPECTED_RC
assert_classify() {
  local ref="$1" exp_out="$2" exp_rc="$3"
  local out rc
  out="$(classify_issue_ref "$ref" 2>/dev/null)"
  rc=$?
  if [[ "$out" == "$exp_out" && "$rc" == "$exp_rc" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "  ✗ classify '$ref': expected [$exp_out](rc $exp_rc) got [$out](rc $rc)"
  fi
}

# assert_branch BRANCH EXPECTED_STDOUT EXPECTED_RC
assert_branch() {
  local branch="$1" exp_out="$2" exp_rc="$3"
  local out rc
  out="$(extract_issue_ref_from_branch "$branch" 2>/dev/null)"
  rc=$?
  if [[ "$out" == "$exp_out" && "$rc" == "$exp_rc" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "  ✗ branch '$branch': expected [$exp_out](rc $exp_rc) got [$out](rc $rc)"
  fi
}

echo "== classify_issue_ref =="
# GitHub Issue 番号（従来経路）
assert_classify "123" "github:123" 0
# Linear Issue ID
assert_classify "{ISSUE-ID}" "linear:{ISSUE-ID}" 0
# 小文字も大文字に正規化して受理
assert_classify "mae-114" "linear:{ISSUE-ID}" 0
assert_classify "Mae-485" "linear:{ISSUE-ID}" 0
# 不正値はエラー（rc 1）
assert_classify "" "" 1
assert_classify "abc" "" 1
assert_classify "#123" "" 1
assert_classify "MAE-" "" 1
assert_classify "{ISSUE-ID}" "" 1

echo "== extract_issue_ref_from_branch =="
# Linear ID を含むブランチ（現行命名規則）
assert_branch "feat/{ISSUE-ID}-token-rotation" "{ISSUE-ID}" 0
assert_branch "fix/{ISSUE-ID}-checkpoint" "{ISSUE-ID}" 0
# 小文字ブランチも正規化
assert_branch "feat/mae-485-foo" "{ISSUE-ID}" 0
# 後方互換: 素の数字
assert_branch "fix/120-foo" "120" 0
assert_branch "feat/371-preview" "371" 0
# Linear ID の後に説明が続いても先頭の番号だけ抽出（BASH_REMATCH バグ回帰防止）
assert_branch "feat/{ISSUE-ID}-a-99" "{ISSUE-ID}" 0
# Issue 参照なし
assert_branch "feat/codex-dev-flow-rules" "" 1
assert_branch "main" "" 1

echo "== クロスシェル非依存性（bash / zsh どちらで source しても同一動作）=="
# lib は Claude の Bash ツールや メンテナ 環境（zsh）から source されうる。
# BASH_REMATCH に依存すると zsh で番号が欠落するため、両シェルで検証する。
LIB="$SCRIPT_DIR/../lib/resolve-issue-ref.sh"
for sh in bash zsh; do
  if command -v "$sh" >/dev/null 2>&1; then
    out="$("$sh" -c "source '$LIB'; classify_issue_ref '{ISSUE-ID}'" 2>/dev/null)"
    if [[ "$out" == "linear:{ISSUE-ID}" ]]; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1)); echo "  ✗ $sh classify '{ISSUE-ID}': expected [linear:{ISSUE-ID}] got [$out]"
    fi
    out="$("$sh" -c "source '$LIB'; extract_issue_ref_from_branch 'feat/{ISSUE-ID}-x'" 2>/dev/null)"
    if [[ "$out" == "{ISSUE-ID}" ]]; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1)); echo "  ✗ $sh extract 'feat/{ISSUE-ID}-x': expected [{ISSUE-ID}] got [$out]"
    fi
  else
    echo "  ($sh 不在: スキップ)"
  fi
done

echo ""
echo "結果: pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]]