#!/bin/bash
# cwd-guard.sh のテスト
# Bash cwd リセット起因の「裸実行」検知（error-registry: bash-cwd-reset-001）。
# 純関数（cg_bare_tool / cg_should_warn）と hook スクリプトの JSON 出力を検証する。

LIB="$HOOKS_DIR/lib/cwd-guard.sh"
HOOK="$HOOKS_DIR/pre-tool-use-cwd-guard.sh"

# shellcheck source=../lib/cwd-guard.sh
source "$LIB"

# 真偽値ヘルパー（0=真 / 1=偽）
truth() {
  local func="$1"
  shift
  if "$func" "$@" >/dev/null; then echo "0"; else echo "1"; fi
}

# --- cg_bare_tool: 正の検知 ---
echo "cwd-guard: 裸実行の正の検知"

assert_eq "tsc" "$(cg_bare_tool 'npx tsc --noEmit')" "npx tsc 単体"
assert_eq "vitest" "$(cg_bare_tool 'npx vitest run')" "npx vitest 単体"
assert_eq "remotion" "$(cg_bare_tool 'npx remotion render Promo40 out/x.mp4')" "npx remotion 単体"
assert_eq "tsc" "$(cg_bare_tool 'npx tsc --noEmit && npx vitest run')" "連結コマンドの先頭"
assert_eq "tsc" "$(cg_bare_tool 'echo start; npx tsc --noEmit')" "セミコロン後のセグメント"
assert_eq "remotion" "$(cg_bare_tool 'REMOTION_TONE=cc-autoship npx remotion still Demo out/x.png')" \
  "env 代入プレフィックス付き"
assert_eq "vitest" "$(cg_bare_tool 'vitest run --silent')" "npx なしの直接実行"

# --- cg_bare_tool: 負の検知（誤発火防止） ---
echo "cwd-guard: 負の検知"

assert_eq "1" "$(truth cg_bare_tool 'cd /repo/tools/app && npx tsc --noEmit')" \
  "cd 同梱コマンドは対象外"
assert_eq "1" "$(truth cg_bare_tool 'cd tools/app && npx vitest run && npx tsc --noEmit')" \
  "cd 同梱（複数ツール）も対象外"
assert_eq "1" "$(truth cg_bare_tool 'npm run tsc')" "npm run 経由はセグメント先頭でないため対象外"
assert_eq "1" "$(truth cg_bare_tool 'git commit -m \"fix tsc help output\"')" \
  "引数文字列中の tsc に誤発火しない"
assert_eq "1" "$(truth cg_bare_tool 'grep -r vitest docs/')" "grep 引数の vitest に誤発火しない"
assert_eq "1" "$(truth cg_bare_tool 'npx turbo lint type-check')" "turbo 経由は対象外"
assert_eq "1" "$(truth cg_bare_tool '')" "空コマンド"

# --- cg_should_warn: 設定ファイル有無との合成 ---
echo "cwd-guard: cg_should_warn"

assert_eq "0" "$(truth cg_should_warn 'npx tsc --noEmit' 0)" "裸実行 + 設定なし = 警告"
assert_eq "1" "$(truth cg_should_warn 'npx tsc --noEmit' 1)" "裸実行でも設定ありなら不要"
assert_eq "1" "$(truth cg_should_warn 'cd x && npx tsc --noEmit' 0)" "cd 同梱なら設定なしでも不要"

# --- hook スクリプト: JSON 入出力（end-to-end） ---
echo "cwd-guard: hook スクリプトの JSON 出力"

TMP_NOCFG=$(mktemp -d)
TMP_CFG=$(mktemp -d)
echo '{}' > "$TMP_CFG/tsconfig.json"
trap 'rm -rf "$TMP_NOCFG" "$TMP_CFG"' EXIT

hook_out_nocfg=$(printf '%s' "{\"tool_name\":\"Bash\",\"cwd\":\"$TMP_NOCFG\",\"tool_input\":{\"command\":\"npx tsc --noEmit\"}}" | bash "$HOOK")
assert_valid_json "$hook_out_nocfg" "警告時の出力は valid JSON"
assert_contains "additionalContext" "$hook_out_nocfg" "警告は additionalContext で返す"
assert_contains "tsconfig.json" "$hook_out_nocfg" "警告文に欠落ファイル名を含む"
assert_contains "cd " "$hook_out_nocfg" "警告文に cd 同梱の対処を含む"

hook_out_cfg=$(printf '%s' "{\"tool_name\":\"Bash\",\"cwd\":\"$TMP_CFG\",\"tool_input\":{\"command\":\"npx tsc --noEmit\"}}" | bash "$HOOK")
assert_eq "" "$hook_out_cfg" "tsconfig がある cwd では沈黙"

hook_out_other=$(printf '%s' '{"tool_name":"Read","cwd":"/tmp","tool_input":{}}' | bash "$HOOK")
assert_eq "" "$hook_out_other" "Bash 以外のツールでは沈黙"

hook_out_cd=$(printf '%s' "{\"tool_name\":\"Bash\",\"cwd\":\"$TMP_NOCFG\",\"tool_input\":{\"command\":\"cd /x && npx tsc --noEmit\"}}" | bash "$HOOK")
assert_eq "" "$hook_out_cd" "cd 同梱コマンドでは沈黙"

# 警告はブロックしない（exit 0）
printf '%s' "{\"tool_name\":\"Bash\",\"cwd\":\"$TMP_NOCFG\",\"tool_input\":{\"command\":\"npx tsc --noEmit\"}}" | bash "$HOOK" >/dev/null
assert_exit_code 0 $? "警告時も exit 0（非ブロック）"