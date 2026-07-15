#!/bin/bash
# PostToolUse Hook: Edit/Write 後に自動 eslint --fix
# lint エラーで作業を止めないため、常に exit 0

set -uo pipefail

# jq が無ければスキップ
if ! command -v jq &>/dev/null; then
  exit 0
fi

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Edit/Write 以外はスキップ
if [ "$TOOL_NAME" != "Edit" ] && [ "$TOOL_NAME" != "Write" ]; then
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# ファイルパスが空ならスキップ
if [ -z "$FILE_PATH" ] || [ ! -f "$FILE_PATH" ]; then
  exit 0
fi

# 対象拡張子のみ
case "$FILE_PATH" in
  *.ts|*.tsx|*.js|*.jsx|*.mjs)
    ;;
  *)
    exit 0
    ;;
esac

# eslint --fix を実行（未インストール時はスキップ、失敗しても無視）
npx --no-install eslint --fix "$FILE_PATH" 2>/dev/null || true

exit 0
