#!/bin/bash
# cwd-guard: サブディレクトリ前提コマンドの「裸実行」検知（純関数・{ISSUE-ID}）
#
# Bash ツールの cwd はバックグラウンド実行・ユーザー割込後にリポジトリルートへ
# リセットされることがある（error-registry: bash-cwd-reset-001・同一セッション 4 回再発）。
# 設定ファイルを持たないディレクトリで `npx tsc` 等が裸で走るとツールがヘルプを
# 出して fail し手戻りになるため、PreToolUse で警告する（ブロックはしない）。
# `cd` を同一コマンドに含めていれば意図的な移動とみなし対象外。
#
# 純関数（fs 非依存・単語照合のみ。実 fs 判定は呼び出し側 hook が行う）:
#   cg_bare_tool <command>                       → 裸実行ツール名を stdout（無ければ return 1）
#   cg_should_warn <command> <has_local_config>  → 0=警告すべき / 1=不要（has_local_config: 0|1）

# コマンド内に cd セグメントがあるか（あれば意図的な移動とみなす）
_cg_has_cd_segment() {
  printf '%s' "$1" | grep -qE '(^|[;&|])[[:space:]]*cd[[:space:]]'
}

# セグメント先頭（^ / ; / & / |）+ 任意の env 代入プレフィックス + 任意の npx に続く
# tsc / vitest / remotion を検知する。引用符内・引数位置の語（npm run tsc /
# grep vitest 等）はセグメント先頭に来ないため対象外。
cg_bare_tool() {
  local cmd="${1:-}"
  [ -n "$cmd" ] || return 1
  _cg_has_cd_segment "$cmd" && return 1
  local tool
  tool=$(printf '%s' "$cmd" \
    | grep -oE '(^|[;&|])[[:space:]]*([A-Za-z_][A-Za-z_0-9]*=[^[:space:]]*[[:space:]]+)*(npx[[:space:]]+)?(tsc|vitest|remotion)([[:space:]]|$)' \
    | head -1 \
    | grep -oE '(tsc|vitest|remotion)' \
    | tail -1)
  [ -n "$tool" ] || return 1
  printf '%s' "$tool"
}

cg_should_warn() {
  local cmd="${1:-}" has_cfg="${2:-1}"
  [ "$has_cfg" = "1" ] && return 1
  cg_bare_tool "$cmd" >/dev/null
}

# ツール → 必要な設定ファイル（スペース区切りの候補）。hook が cwd 実在確認に使う。
cg_required_configs() {
  case "${1:-}" in
    tsc) printf '%s' "tsconfig.json" ;;
    vitest) printf '%s' "vitest.config.ts vitest.config.mts vitest.config.js vitest.config.mjs vite.config.ts vite.config.js" ;;
    remotion) printf '%s' "remotion.config.ts remotion.config.js" ;;
    *) return 1 ;;
  esac
}