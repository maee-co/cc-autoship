#!/usr/bin/env bash
# codex-secondary-review スキルの構造整合性テスト（{ISSUE-ID}: 可用性の事前判定）
# 実行: bash .claude/skills/codex-secondary-review/__tests__/test-skill-structure.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_FILE="${SCRIPT_DIR}/../SKILL.md"

if [ ! -f "$SKILL_FILE" ]; then
  echo "❌ SKILL.md が見つかりません: ${SKILL_FILE}"
  exit 2
fi

PASS=0
FAIL=0

assert_contains() {
  local desc="$1" pattern="$2"
  if grep -qF -- "$pattern" "$SKILL_FILE"; then
    echo "✅ ${desc}"
    PASS=$((PASS + 1))
  else
    echo "❌ ${desc} — 「${pattern}」が見つかりません"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Step 3.5: Codex 可用性の事前判定 ==="
assert_contains "事前判定ステップがある" "### Step 3.5: Codex 可用性の事前判定"
assert_contains "spawn 前の判定であることの明記" "spawn の**前に**非ネットワーク・決定的に可用性を判定"
assert_contains "CLI 実在チェック" "command -v codex"
assert_contains "agent 定義ファイルの実在チェック" "agents/codex-rescue.md"
assert_contains "不可用時は Step 4 を呼ばない" "Step 4 の Agent 呼び出しを行わず"
assert_contains "スキップ時の非ブロック挙動維持" "コメント非投稿・auto-merge 非ブロック"
assert_contains "誤可用判定時のフォールバック明記" "spawn 失敗 → 静かに失敗にフォールバック"

echo "=== Step 3.5: 有効化チェック ==="
assert_contains "判定を lib の純関数に委譲している" "csr_codex_available_default"
assert_contains "enabledPlugins を見ることの明記" "enabledPlugins"
assert_contains "スコープ優先順の明記" ".claude/settings.local.json"
assert_contains "不在を無効と扱うことの明記" "どこにも無ければ「無効」"
assert_contains "判定不能は不可用に倒す明記" "判定不能（jq 不在 / 設定 JSON 破損）は不可用に倒す"

echo "=== エッジケース表 ==="
assert_contains "未導入ケースが表にある" "Codex 未導入（CLI なし / agent 定義なし）"
assert_contains "installed だが未有効のケースが表にある" "Codex は installed だが**未有効**"

echo ""
echo "Result: passed=${PASS} failed=${FAIL}"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi