#!/usr/bin/env bash
# codex-availability.sh の純関数テスト（{ISSUE-ID}: installed だが未有効を検知する）
# 実行: bash .claude/skills/codex-secondary-review/__tests__/test-codex-availability.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/codex-availability.sh
source "${SCRIPT_DIR}/../lib/codex-availability.sh"

PASS=0
FAIL=0

assert_rc() {
  local desc="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "✅ ${desc}"
    PASS=$((PASS + 1))
  else
    echo "❌ ${desc} — want rc=${want} got rc=${got}"
    FAIL=$((FAIL + 1))
  fi
}

assert_eq() {
  local desc="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "✅ ${desc}"
    PASS=$((PASS + 1))
  else
    echo "❌ ${desc} — want [${want}] got [${got}]"
    FAIL=$((FAIL + 1))
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

KEY="codex@openai-codex"

printf '%s' '{"enabledPlugins":{"codex@openai-codex":true}}'  >"$TMP/on.json"
printf '%s' '{"enabledPlugins":{"codex@openai-codex":false}}' >"$TMP/off.json"
printf '%s' '{"enabledPlugins":{"other@x":true}}'             >"$TMP/absent.json"
printf '%s' '{}'                                              >"$TMP/empty.json"
printf '%s' '{"enabledPlugins":'                              >"$TMP/broken.json"

echo "=== csr_plugin_enabled: 単一スコープ ==="
csr_plugin_enabled "$KEY" "$TMP/on.json";      assert_rc "明示 true は有効" 0 "$?"
csr_plugin_enabled "$KEY" "$TMP/off.json";     assert_rc "明示 false は無効" 1 "$?"
csr_plugin_enabled "$KEY" "$TMP/absent.json";  assert_rc "エントリ不在は無効（既定有効にしない）" 1 "$?"
csr_plugin_enabled "$KEY" "$TMP/empty.json";   assert_rc "enabledPlugins 自体が無い場合も無効" 1 "$?"
csr_plugin_enabled "$KEY" "$TMP/nope.json";    assert_rc "設定ファイル不在は無効" 1 "$?"
csr_plugin_enabled "$KEY" "$TMP/broken.json";  assert_rc "壊れた JSON は無効側に倒す" 1 "$?"

echo "=== csr_plugin_enabled: スコープ優先順（先に渡した方が勝つ） ==="
csr_plugin_enabled "$KEY" "$TMP/on.json"  "$TMP/off.json"; assert_rc "先頭 true × 後続 false → 有効" 0 "$?"
csr_plugin_enabled "$KEY" "$TMP/off.json" "$TMP/on.json";  assert_rc "先頭 false × 後続 true → 無効（先勝ち）" 1 "$?"
csr_plugin_enabled "$KEY" "$TMP/nope.json" "$TMP/on.json"; assert_rc "不在ファイルは飛ばして次を見る" 0 "$?"
csr_plugin_enabled "$KEY" "$TMP/absent.json" "$TMP/on.json"; assert_rc "エントリ無しは確定させず次スコープを見る" 0 "$?"

echo "=== csr_agent_definition_exists ==="
mkdir -p "$TMP/cache/openai-codex/codex/1.0.4/agents"
touch "$TMP/cache/openai-codex/codex/1.0.4/agents/codex-rescue.md"
csr_agent_definition_exists "$TMP/cache" "$TMP/noproj"; assert_rc "plugin cache に定義があれば 0" 0 "$?"
csr_agent_definition_exists "$TMP/nocache" "$TMP/noproj"; assert_rc "どこにも無ければ 1" 1 "$?"

mkdir -p "$TMP/proj/.claude/agents"
touch "$TMP/proj/.claude/agents/codex-rescue.md"
csr_agent_definition_exists "$TMP/nocache" "$TMP/proj"; assert_rc "プロジェクト直下の定義も拾う" 0 "$?"

echo "=== csr_codex_available: 統合（3 条件の AND） ==="
FAKE_BIN="$TMP/bin"; mkdir -p "$FAKE_BIN"
printf '#!/bin/sh\nexit 0\n' >"$FAKE_BIN/codex"; chmod +x "$FAKE_BIN/codex"

with_codex_cli() { PATH="$FAKE_BIN:$PATH" "$@"; }
without_codex_cli() { PATH="$TMP/emptybin" "$@"; }
mkdir -p "$TMP/emptybin"

with_codex_cli csr_codex_available "$KEY" "$TMP/cache" "$TMP/noproj" "$TMP/on.json"
assert_rc "CLI あり + 有効 + 定義あり → 可用" 0 "$?"

with_codex_cli csr_codex_available "$KEY" "$TMP/cache" "$TMP/noproj" "$TMP/off.json"
assert_rc "未有効なら定義があっても不可用（{ISSUE-ID} の再発ケース）" 1 "$?"

with_codex_cli csr_codex_available "$KEY" "$TMP/cache" "$TMP/noproj" "$TMP/absent.json"
assert_rc "enabledPlugins 不在も不可用（実測された今回の状態）" 1 "$?"

with_codex_cli csr_codex_available "$KEY" "$TMP/nocache" "$TMP/noproj" "$TMP/on.json"
assert_rc "有効でも定義が無ければ不可用" 1 "$?"

without_codex_cli csr_codex_available "$KEY" "$TMP/cache" "$TMP/noproj" "$TMP/on.json"
assert_rc "CLI が無ければ不可用" 1 "$?"

echo "=== csr_agent_definition_exists: 空引数ガード ==="
csr_agent_definition_exists "" ""; assert_rc "空引数でルートから glob せず 1" 1 "$?"

echo "=== csr_codex_available_default: 実際の入口（HOME / CLAUDE_PROJECT_DIR 注入） ==="
# 既定ラッパーが参照する実パス構成を temp に作る
FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME/.claude/plugins/cache/openai-codex/codex/1.0.4/agents"
touch "$FAKE_HOME/.claude/plugins/cache/openai-codex/codex/1.0.4/agents/codex-rescue.md"
FAKE_PROJ="$TMP/proj-default"
mkdir -p "$FAKE_PROJ/.claude"

printf '%s' '{"enabledPlugins":{"codex@openai-codex":true}}' >"$FAKE_HOME/.claude/settings.json"
PATH="$FAKE_BIN:$PATH" HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$FAKE_PROJ" csr_codex_available_default
assert_rc "user settings で有効 → 可用" 0 "$?"

printf '%s' '{"enabledPlugins":{"codex@openai-codex":false}}' >"$FAKE_PROJ/.claude/settings.json"
PATH="$FAKE_BIN:$PATH" HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$FAKE_PROJ" csr_codex_available_default
assert_rc "project settings の false が user の true に優先する" 1 "$?"

printf '%s' '{"enabledPlugins":{"codex@openai-codex":true}}' >"$FAKE_PROJ/.claude/settings.local.json"
PATH="$FAKE_BIN:$PATH" HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$FAKE_PROJ" csr_codex_available_default
assert_rc "settings.local.json が最優先" 0 "$?"

rm -f "$FAKE_HOME/.claude/settings.json" "$FAKE_PROJ/.claude/settings.json" "$FAKE_PROJ/.claude/settings.local.json"
PATH="$FAKE_BIN:$PATH" HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$FAKE_PROJ" csr_codex_available_default
assert_rc "設定がどこにも無ければ不可用（今回の実環境と同じ状態）" 1 "$?"

echo "=== set -u × 環境変数未設定でもエラーを出さない ==="
# HOME / CLAUDE_PROJECT_DIR が未設定でも unbound variable で落ちない（エラー行を出さない）
UNSET_ERR=$(env -u HOME -u CLAUDE_PROJECT_DIR bash -c "
  set -u
  source '${SCRIPT_DIR}/../lib/codex-availability.sh'
  csr_codex_available_default
  echo \"rc=\$?\"
" 2>&1 >/dev/null)
assert_eq "HOME/CLAUDE_PROJECT_DIR 未設定 + set -u で stderr が空" "" "$UNSET_ERR"

echo "=== 決定性・非ネットワーク（{ISSUE-ID} の設計方針を維持） ==="
a=$(with_codex_cli csr_codex_available "$KEY" "$TMP/cache" "$TMP/noproj" "$TMP/on.json"; echo $?)
b=$(with_codex_cli csr_codex_available "$KEY" "$TMP/cache" "$TMP/noproj" "$TMP/on.json"; echo $?)
assert_eq "同一入力で結果が安定する" "$a" "$b"

echo ""
echo "Result: passed=${PASS} failed=${FAIL}"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi