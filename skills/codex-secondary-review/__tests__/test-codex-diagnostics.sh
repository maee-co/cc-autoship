#!/usr/bin/env bash
# codex-diagnostics.sh の純関数テスト（{ISSUE-ID}: 可用性判定 pass 後の runtime 無音失敗の可観測性）
# 実行: bash .claude/skills/codex-secondary-review/__tests__/test-codex-diagnostics.sh
#
# 背景:
#   可用性判定（csr_codex_available_default）が pass しても、companion runtime（`task`）が
#   exit 1・stdout 空で失敗することがある。codex-rescue agent は仕様上 stdout しか返さず、
#   companion のエラーは stderr に出て**破棄される**ため、失敗理由が呼び出し元に伝わらない。
#   本 lib は、その破棄されるシグナル（解決された codex バイナリの実体・version liveness・
#   auth の実在・plugin cache）をローカルで捕捉し、無音のブラックボックス失敗を診断可能にする。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/codex-diagnostics.sh
source "${SCRIPT_DIR}/../lib/codex-diagnostics.sh"

PASS=0
FAIL=0

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

assert_no_match() {
  local desc="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "❌ ${desc} — 「${needle}」が出力に混入している"
    FAIL=$((FAIL + 1))
  else
    echo "✅ ${desc}"
    PASS=$((PASS + 1))
  fi
}

# 診断出力から `key=value` の value を取り出す（最初の一致行の = 以降すべて）。
diag_value() {
  local key="$1" text="$2"
  printf '%s\n' "$text" | grep -m1 "^${key}=" | sed "s/^${key}=//"
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- codex スタブ（PATH 注入用）を用意する ---------------------------------
BIN_OK="$TMP/bin-ok"; mkdir -p "$BIN_OK"
cat >"$BIN_OK/codex" <<'EOF'
#!/bin/sh
# --version で正常にバージョン文字列を stdout に返す
echo "codex-cli 9.9.9; advanced runtime available"
exit 0
EOF
chmod +x "$BIN_OK/codex"

BIN_FAIL="$TMP/bin-fail"; mkdir -p "$BIN_FAIL"
cat >"$BIN_FAIL/codex" <<'EOF'
#!/bin/sh
# 起動そのものは通るが --version が非ゼロ + stderr にエラーを出す（shim 不調の模擬）
echo "codex: failed to resolve runtime shim" 1>&2
exit 3
EOF
chmod +x "$BIN_FAIL/codex"

BIN_NOISY="$TMP/bin-noisy"; mkdir -p "$BIN_NOISY"
cat >"$BIN_NOISY/codex" <<'EOF'
#!/bin/sh
# 長大な stderr（切り詰めの検証用）
i=0
while [ "$i" -lt 50 ]; do printf 'ERRLINE-%02d-xxxxxxxxxxxxxxxxxxxxxxxxxxxx\n' "$i" 1>&2; i=$((i + 1)); done
exit 1
EOF
chmod +x "$BIN_NOISY/codex"

EMPTY_BIN="$TMP/emptybin"; mkdir -p "$EMPTY_BIN"

with_bin() { local dir="$1"; shift; PATH="${dir}:${PATH}" "$@"; }
without_bin() { PATH="$EMPTY_BIN" "$@"; }

# --- auth.json / plugin cache のフィクスチャ --------------------------------
AUTH_PRESENT="$TMP/auth-present.json"
# 秘密トークンらしき値を入れ、出力に**中身が混入しない**ことを後で assert する
printf '%s' '{"OPENAI_API_KEY":"sk-SECRET-TOKEN-DO-NOT-LEAK-abcdef"}' >"$AUTH_PRESENT"
AUTH_MISSING="$TMP/no-such-auth.json"

CACHE_PRESENT="$TMP/cache"; mkdir -p "$CACHE_PRESENT/openai-codex/codex/1.0.4/agents"
CACHE_MISSING="$TMP/no-such-cache"

echo "=== codex バイナリ実在・version liveness ==="
OUT=$(with_bin "$BIN_OK" csr_runtime_diagnostics "$AUTH_PRESENT" "$CACHE_PRESENT")
assert_eq "codex_bin に解決パスが載る" "${BIN_OK}/codex" "$(diag_value codex_bin "$OUT")"
assert_eq "version に stdout 先頭行が載る" "codex-cli 9.9.9; advanced runtime available" "$(diag_value version "$OUT")"
assert_eq "version_exit=0（正常）" "0" "$(diag_value version_exit "$OUT")"
assert_eq "version_stderr は空なら (empty)" "(empty)" "$(diag_value version_stderr "$OUT")"
assert_eq "auth_json=present" "present" "$(diag_value auth_json "$OUT")"
assert_eq "plugin_cache=present" "present" "$(diag_value plugin_cache "$OUT")"

echo "=== codex 不在 ==="
OUT=$(without_bin csr_runtime_diagnostics "$AUTH_MISSING" "$CACHE_MISSING")
assert_eq "codex_bin=not-found" "not-found" "$(diag_value codex_bin "$OUT")"
assert_eq "version=na（起動せず）" "na" "$(diag_value version "$OUT")"
assert_eq "version_exit=na" "na" "$(diag_value version_exit "$OUT")"
assert_eq "version_stderr=na" "na" "$(diag_value version_stderr "$OUT")"
assert_eq "auth_json=missing" "missing" "$(diag_value auth_json "$OUT")"
assert_eq "plugin_cache=missing" "missing" "$(diag_value plugin_cache "$OUT")"

echo "=== codex は起動するが --version が非ゼロ（shim 不調の模擬） ==="
OUT=$(with_bin "$BIN_FAIL" csr_runtime_diagnostics "$AUTH_PRESENT" "$CACHE_PRESENT")
assert_eq "version_exit に非ゼロが載る" "3" "$(diag_value version_exit "$OUT")"
assert_eq "version_stderr に stderr 先頭行が載る" "codex: failed to resolve runtime shim" "$(diag_value version_stderr "$OUT")"

echo "=== stderr は 1 行・上限バイトで切り詰める ==="
OUT=$(with_bin "$BIN_NOISY" csr_runtime_diagnostics "$AUTH_PRESENT" "$CACHE_PRESENT")
STDERR_VAL="$(diag_value version_stderr "$OUT")"
# 先頭行のみ（2 行目以降が混ざらない）
assert_eq "stderr は 1 行に丸める（先頭行のみ）" "ERRLINE-00-xxxxxxxxxxxxxxxxxxxxxxxxxxxx" "$STDERR_VAL"
# 出力全体が 1 行あたり上限（240 文字）を超えない
LONGEST=$(printf '%s\n' "$OUT" | awk '{ if (length > max) max = length } END { print max }')
if [ "${LONGEST:-0}" -le 240 ]; then
  echo "✅ 各行が 240 文字以内に収まる（got max=${LONGEST}）"; PASS=$((PASS + 1))
else
  echo "❌ 行長が上限超過 — max=${LONGEST}"; FAIL=$((FAIL + 1))
fi

echo "=== セキュリティ: auth.json の中身を絶対に出力しない ==="
OUT=$(with_bin "$BIN_OK" csr_runtime_diagnostics "$AUTH_PRESENT" "$CACHE_PRESENT")
assert_no_match "秘密トークン文字列が出力に出ない" "sk-SECRET-TOKEN-DO-NOT-LEAK-abcdef" "$OUT"
assert_no_match "OPENAI_API_KEY キー名も出ない" "OPENAI_API_KEY" "$OUT"

echo "=== 決定性（同一入力で安定） ==="
A=$(with_bin "$BIN_OK" csr_runtime_diagnostics "$AUTH_PRESENT" "$CACHE_PRESENT")
B=$(with_bin "$BIN_OK" csr_runtime_diagnostics "$AUTH_PRESENT" "$CACHE_PRESENT")
assert_eq "同一入力で診断出力が一致する" "$A" "$B"

echo "=== 既定ラッパー: HOME 未設定 + set -u でも unbound エラーを出さない ==="
UNSET_ERR=$(env -u HOME bash -c "
  set -u
  source '${SCRIPT_DIR}/../lib/codex-diagnostics.sh'
  csr_runtime_diagnostics_default >/dev/null
" 2>&1)
assert_eq "HOME 未設定 + set -u で stderr が空" "" "$UNSET_ERR"

echo "=== 既定ラッパー: HOME 既定パスを組み立てる ==="
FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/.claude/plugins/cache/openai-codex/codex/1.0.4/agents"
printf '%s' '{"tokens":"x"}' >"$FAKE_HOME/.codex/auth.json"
OUT=$(HOME="$FAKE_HOME" with_bin "$BIN_OK" csr_runtime_diagnostics_default)
assert_eq "既定ラッパーが ~/.codex/auth.json を present と判定" "present" "$(diag_value auth_json "$OUT")"
assert_eq "既定ラッパーが ~/.claude/plugins/cache を present と判定" "present" "$(diag_value plugin_cache "$OUT")"

echo ""
echo "Result: passed=${PASS} failed=${FAIL}"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi