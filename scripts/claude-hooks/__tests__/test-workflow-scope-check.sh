#!/bin/bash
# test-workflow-scope-check.sh — workflow-scope-check.sh の純関数テスト（{ISSUE-ID} Phase 2）

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../lib/workflow-scope-check.sh"

if [ ! -f "$LIB" ]; then
  echo "FAIL: lib not found at $LIB" >&2
  exit 1
fi

# shellcheck source=../lib/workflow-scope-check.sh
source "$LIB"

PASS=0
FAIL=0

assert_pass() {
  local label="$1"
  PASS=$((PASS + 1))
  echo "  ✅ $label"
}

assert_fail() {
  local label="$1"
  local reason="${2:-}"
  FAIL=$((FAIL + 1))
  echo "  ❌ $label${reason:+ — $reason}" >&2
}

# ------------------------------------------------------------------------
# is_workflow_file の単独テスト
# ------------------------------------------------------------------------
echo "[is_workflow_file]"

if is_workflow_file ".github/workflows/lint.yml"; then
  assert_pass "yml 直下を検知"
else
  assert_fail "yml 直下を検知"
fi

if is_workflow_file ".github/workflows/ci.yaml"; then
  assert_pass "yaml 直下を検知"
else
  assert_fail "yaml 直下を検知"
fi

if ! is_workflow_file ".github/workflows/subdir/foo.yml"; then
  assert_pass "サブディレクトリは対象外"
else
  assert_fail "サブディレクトリは対象外" "サブディレクトリも検知してしまった"
fi

if ! is_workflow_file "scripts/workflows/foo.yml"; then
  assert_pass "別ディレクトリの yml は対象外"
else
  assert_fail "別ディレクトリの yml は対象外"
fi

if ! is_workflow_file ".github/workflows/README.md"; then
  assert_pass ".md は対象外"
else
  assert_fail ".md は対象外"
fi

if ! is_workflow_file ".github/workflowsfoo.yml"; then
  assert_pass "前方一致誤検知防止"
else
  assert_fail "前方一致誤検知防止" ".github/workflowsfoo.yml を検知してしまった"
fi

if ! is_workflow_file ""; then
  assert_pass "空パスは対象外"
else
  assert_fail "空パスは対象外"
fi

# ------------------------------------------------------------------------
# has_new_workflow_in_files の単独テスト
# ------------------------------------------------------------------------
echo "[has_new_workflow_in_files]"

if printf '.github/workflows/lint.yml\nREADME.md\n' | has_new_workflow_in_files; then
  assert_pass "workflow と他ファイル混在で検知"
else
  assert_fail "workflow と他ファイル混在で検知"
fi

if ! printf 'README.md\nsrc/foo.ts\n' | has_new_workflow_in_files; then
  assert_pass "workflow なしは検知しない"
else
  assert_fail "workflow なしは検知しない"
fi

if ! printf '' | has_new_workflow_in_files; then
  assert_pass "空入力は検知しない"
else
  assert_fail "空入力は検知しない"
fi

if printf '.github/workflows/a.yml\n.github/workflows/b.yaml\n' | has_new_workflow_in_files; then
  assert_pass "複数 workflow ファイルを検知"
else
  assert_fail "複数 workflow ファイルを検知"
fi

if ! printf '.github/workflows/subdir/foo.yml\n' | has_new_workflow_in_files; then
  assert_pass "サブディレクトリのみは検知しない"
else
  assert_fail "サブディレクトリのみは検知しない"
fi

# ------------------------------------------------------------------------
# get_new_workflow_files_from_pr の入力バリデーション
# ------------------------------------------------------------------------
echo "[get_new_workflow_files_from_pr]"

if ! get_new_workflow_files_from_pr ""; then
  assert_pass "PR 番号未指定で失敗"
else
  assert_fail "PR 番号未指定で失敗"
fi

# ------------------------------------------------------------------------
# get_new_workflow_files_from_pr — gh モックを使ったフィルタリングテスト
# ------------------------------------------------------------------------
echo "[get_new_workflow_files_from_pr (gh mock)]"

# モック用 tmpdir を作成し cleanup trap を設定（PATH を保存して汚染しない）
GH_MOCK_DIR=$(mktemp -d)
ORIGINAL_PATH="$PATH"
cleanup_gh_mock() {
  rm -rf "$GH_MOCK_DIR"
  export PATH="$ORIGINAL_PATH"
}
trap cleanup_gh_mock EXIT

# ヘルパー: モック gh を生成（PATH は呼び出し元で設定/復元する）
write_gh_mock() {
  local api_output="$1"    # gh api --jq が返す改行区切りファイルパス
  local api_exit="${2:-0}" # gh api の exit code
  local repo_name="${3:-example-org/core}"
  cat > "$GH_MOCK_DIR/gh" <<GHEOF
#!/bin/bash
case "\$*" in
  *"repo view"*)
    printf '%s\n' "$repo_name"
    exit 0
    ;;
  *"api"*"--jq"*)
    [ "$api_exit" -ne 0 ] && exit "$api_exit"
    printf '%s' "$api_output"
    exit 0
    ;;
  *) exit 1 ;;
esac
GHEOF
  chmod +x "$GH_MOCK_DIR/gh"
}

# テスト 1: workflow ファイルを含む PR → 検知
write_gh_mock ".github/workflows/lint.yml
README.md
src/foo.ts
"
export PATH="$GH_MOCK_DIR:$ORIGINAL_PATH"
result=$(get_new_workflow_files_from_pr "42")
if [ "$result" = ".github/workflows/lint.yml" ]; then
  assert_pass "workflow ファイルを含む PR で検知"
else
  assert_fail "workflow ファイルを含む PR で検知" "got: $result"
fi
export PATH="$ORIGINAL_PATH"

# テスト 2: workflow ファイルを含まない PR → 空出力
write_gh_mock "README.md
src/foo.ts
"
export PATH="$GH_MOCK_DIR:$ORIGINAL_PATH"
result=$(get_new_workflow_files_from_pr "99")
if [ -z "$result" ]; then
  assert_pass "workflow なし PR は空出力"
else
  assert_fail "workflow なし PR は空出力" "got: $result"
fi
export PATH="$ORIGINAL_PATH"

# テスト 3: 複数 workflow ファイル → 全件出力
write_gh_mock ".github/workflows/ci.yml
.github/workflows/release.yaml
scripts/setup.sh
"
export PATH="$GH_MOCK_DIR:$ORIGINAL_PATH"
result=$(get_new_workflow_files_from_pr "123")
expected=".github/workflows/ci.yml
.github/workflows/release.yaml"
if [ "$result" = "$expected" ]; then
  assert_pass "複数 workflow ファイルを全件出力"
else
  assert_fail "複数 workflow ファイルを全件出力" "got: $result"
fi
export PATH="$ORIGINAL_PATH"

# テスト 4: workflow サブディレクトリは除外
write_gh_mock ".github/workflows/subdir/foo.yml
.github/workflows/top.yml
"
export PATH="$GH_MOCK_DIR:$ORIGINAL_PATH"
result=$(get_new_workflow_files_from_pr "200")
if [ "$result" = ".github/workflows/top.yml" ]; then
  assert_pass "サブディレクトリ workflow を除外"
else
  assert_fail "サブディレクトリ workflow を除外" "got: $result"
fi
export PATH="$ORIGINAL_PATH"

# テスト 5: gh api 失敗 → 空出力（fail safe）
write_gh_mock "" 1
export PATH="$GH_MOCK_DIR:$ORIGINAL_PATH"
result=$(get_new_workflow_files_from_pr "500" 2>/dev/null || true)
if [ -z "$result" ]; then
  assert_pass "gh api 失敗時は空出力（fail safe）"
else
  assert_fail "gh api 失敗時は空出力（fail safe）" "got: $result"
fi
export PATH="$ORIGINAL_PATH"

# テスト 6: gh repo view が空を返す → return 1
cat > "$GH_MOCK_DIR/gh" << 'GHEOF'
#!/bin/bash
case "$*" in
  *"repo view"*) printf ''; exit 0 ;;
  *) exit 1 ;;
esac
GHEOF
chmod +x "$GH_MOCK_DIR/gh"
export PATH="$GH_MOCK_DIR:$ORIGINAL_PATH"
if ! get_new_workflow_files_from_pr "777" 2>/dev/null; then
  assert_pass "repo view 空なら return 1"
else
  assert_fail "repo view 空なら return 1"
fi
export PATH="$ORIGINAL_PATH"

# ------------------------------------------------------------------------
# サマリ
# ------------------------------------------------------------------------
echo
echo "PASS=$PASS FAIL=$FAIL"

if [ "$FAIL" -gt 0 ]; then
  return 1 2>/dev/null || exit 1
fi
return 0 2>/dev/null || exit 0