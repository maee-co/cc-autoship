#!/usr/bin/env bash
# /github-issue-impl スキルの構造検証テスト
set -euo pipefail

SKILL_FILE="$(dirname "$0")/SKILL.md"
PASS=0
FAIL=0
ERRORS=""

assert() {
  local desc="$1"
  local result="$2"
  if [ "$result" = "0" ]; then
    PASS=$((PASS + 1))
    echo "  ✓ $desc"
  else
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}\n  ✗ $desc"
    echo "  ✗ $desc"
  fi
}

echo "=== /github-issue-impl SKILL.md 構造テスト ==="
echo ""

# ファイル存在チェック
echo "[1] ファイル存在チェック"
test -f "$SKILL_FILE"
assert "SKILL.md が存在する" $?

# Frontmatter チェック
echo "[2] Frontmatter チェック"
head -1 "$SKILL_FILE" | grep -q '^---$'
assert "Frontmatter 開始 (---)" $?

grep -q '^name: github-issue-impl$' "$SKILL_FILE"
assert "name: github-issue-impl" $?

grep -q '^description:' "$SKILL_FILE"
assert "description フィールドが存在" $?

grep -q '^user-invocable: true$' "$SKILL_FILE"
assert "user-invocable: true" $?

grep -q '^allowed-tools:' "$SKILL_FILE"
assert "allowed-tools フィールドが存在" $?

# allowed-tools に必要なツールが含まれているか
echo "[3] allowed-tools 内容チェック"
TOOLS_LINE=$(grep '^allowed-tools:' "$SKILL_FILE")
echo "$TOOLS_LINE" | grep -q 'Bash'
assert "allowed-tools に Bash が含まれる" $?

echo "$TOOLS_LINE" | grep -q 'Read'
assert "allowed-tools に Read が含まれる" $?

echo "$TOOLS_LINE" | grep -q 'Grep'
assert "allowed-tools に Grep が含まれる" $?

echo "$TOOLS_LINE" | grep -q 'Agent'
assert "allowed-tools に Agent が含まれる" $?

echo "$TOOLS_LINE" | grep -q 'Write'
assert "allowed-tools に Write が含まれる" $?

echo "$TOOLS_LINE" | grep -q 'Edit'
assert "allowed-tools に Edit が含まれる" $?

# ステップ構造チェック
echo "[4] ステップ構造チェック"
grep -q '### ステップ 1' "$SKILL_FILE"
assert "ステップ 1 が存在" $?

grep -q '### ステップ 2' "$SKILL_FILE"
assert "ステップ 2 が存在" $?

grep -q '### ステップ 3' "$SKILL_FILE"
assert "ステップ 3 が存在" $?

grep -q '### ステップ 4' "$SKILL_FILE"
assert "ステップ 4 が存在" $?

grep -q '### ステップ 5' "$SKILL_FILE"
assert "ステップ 5 が存在" $?

# 安全性チェック
echo "[5] 安全性チェック"
grep -q 'gh auth status' "$SKILL_FILE"
assert "gh 認証チェック (gh auth status) が含まれる" $?

grep -q 'DATA_PRIVACY_POLICY' "$SKILL_FILE"
assert "DATA_PRIVACY_POLICY への参照が含まれる" $?

grep -q 'body-file' "$SKILL_FILE"
assert "--body-file によるシェルインジェクション対策がある" $?

grep -q 'スコープ外編集を禁止' "$SKILL_FILE"
assert "スコープ外編集禁止ルールが記載されている" $?

# 引数チェック
echo "[6] 引数チェック"
grep -q '\-\-plan-only' "$SKILL_FILE"
assert "--plan-only 引数が記載されている" $?

grep -q '\-\-team' "$SKILL_FILE"
assert "--team 引数が記載されている" $?

# Issue 状態チェック
echo "[7] Issue 状態 & エッジケースチェック"
grep -q 'closed' "$SKILL_FILE"
assert "closed Issue のハンドリングが記載されている" $?

grep -q '存在しない' "$SKILL_FILE"
assert "Issue が存在しない場合のハンドリングが記載されている" $?

grep -q 'state' "$SKILL_FILE"
assert "gh issue view に state フィールドが含まれている" $?

# Team モードフォールバック
echo "[8] Team モード フォールバックチェック"
grep -q 'team-config.md が見つからない場合' "$SKILL_FILE"
assert "team-config.md 不存在時のフォールバックが記載されている" $?

grep -q '通常モードにフォールバック' "$SKILL_FILE"
assert "通常モードへのフォールバックが明記されている" $?

# 対象アプリ特定ロジック
echo "[9] 対象アプリ特定ロジック"
grep -q '対象アプリの特定' "$SKILL_FILE"
assert "対象アプリ特定のセクションが存在する" $?

grep -q 'タイトルの.*App名' "$SKILL_FILE"
assert "タイトルからのアプリ名推論が記載されている" $?

# 進捗記録
echo "[10] 進捗記録"
grep -q '\progress/' "$SKILL_FILE"
assert "progress/ への進捗記録が記載されている" $?

# 完了後のアクション確認
echo "[11] 完了後のアクション"
grep -q 'クローズ' "$SKILL_FILE"
assert "Issue クローズの確認が記載されている" $?

grep -q 'PR を作成' "$SKILL_FILE"
assert "PR 作成の確認が記載されている" $?

echo ""
echo "=== 結果: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  echo -e "\n失敗項目:$ERRORS"
  exit 1
fi