#!/bin/bash
# PreToolUse Hook: cwd-guard — サブディレクトリ前提コマンドの裸実行に警告（{ISSUE-ID}）
#
# Bash ツールの cwd はバックグラウンド実行・ユーザー割込後にリセットされることがあり
# （error-registry: bash-cwd-reset-001）、tsconfig.json 等を持たない cwd で
# `npx tsc` / `npx vitest` / `npx remotion` が裸で走るとヘルプ出力で fail する。
# 該当ツールの設定ファイルが cwd に無いときだけ additionalContext で警告する。
# **ブロックはしない**（常に exit 0。誤検知しても実行は止めない安全設計）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/cwd-guard.sh
source "$SCRIPT_DIR/lib/cwd-guard.sh"

# jq が無ければ静かにスキップ
command -v jq &>/dev/null || exit 0

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
[ "$TOOL_NAME" = "Bash" ] || exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
[ -n "$COMMAND" ] && [ -n "$CWD" ] || exit 0

TOOL=$(cg_bare_tool "$COMMAND") || exit 0

# cwd に該当ツールの設定ファイルがあれば正当な実行とみなし沈黙
CONFIGS=$(cg_required_configs "$TOOL") || exit 0
for f in $CONFIGS; do
  [ -f "$CWD/$f" ] && exit 0
done

PRIMARY_CFG=${CONFIGS%% *}
MSG="⚠️ cwd-guard: cwd（${CWD}）に ${PRIMARY_CFG} が見つかりません。'${TOOL}' はサブディレクトリ前提の可能性があります（Bash の cwd はバックグラウンド実行・割込後にリセットされることがある）。対象ディレクトリを 'cd <絶対パス> && ...' で同一コマンドに含めて再実行してください（bash-cwd-reset-001）。"

jq -nc --arg ctx "$MSG" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $ctx}}'
exit 0