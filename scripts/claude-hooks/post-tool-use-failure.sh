#!/bin/bash
# PostToolUseFailure Hook: 失敗したツール呼び出しに対して Claude にリカバリヒントを返す
# CC 2.1.139+ の PostToolUseFailure イベントを活用
#
# 役割: Edit/Write/Bash の失敗時に、頻出パターンに対する具体的なヒントを
#       hookSpecificOutput.additionalContext で Claude に注入し、無駄な再試行を減らす
#
# 失敗時も Claude を止めないため、常に exit 0

set -uo pipefail

# jq が無ければスキップ
if ! command -v jq &>/dev/null; then
  exit 0
fi

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# tool_response から error / stderr を抽出
TOOL_ERROR=$(echo "$INPUT" | jq -r '.tool_response.error // .tool_response.stderr // .tool_response // empty')

HINT=""

case "$TOOL_NAME" in
  Edit|Write|NotebookEdit)
    if echo "$TOOL_ERROR" | grep -qiE "file has not been read|has not been read yet"; then
      HINT="ファイルを編集する前に Read ツールで対象ファイルを読み込んでください。新規ファイルの場合は親ディレクトリの存在を確認してから Write してください。"
    elif echo "$TOOL_ERROR" | grep -qiE "not unique|appears.*times"; then
      HINT="old_string が一意でありません。前後の context を増やすか replace_all を使うか検討してください。"
    elif echo "$TOOL_ERROR" | grep -qiE "not found in|did not match"; then
      HINT="old_string がファイル内に見つかりません。Read で現在の内容を確認するか、Edit ではなく Write による全置換も検討してください。"
    elif echo "$TOOL_ERROR" | grep -qiE "permission denied|EACCES"; then
      HINT="権限不足です。settings.json の deny ルールに該当している可能性が高いので変更内容を見直してください。"
    fi
    ;;
  Bash)
    if echo "$TOOL_ERROR" | grep -qiE "command not found|not recognized"; then
      HINT="コマンドが見つかりません。'which <cmd>' で存在確認するか、Homebrew/npx 経由で実行できないか確認してください。"
    elif echo "$TOOL_ERROR" | grep -qiE "permission denied"; then
      HINT="権限不足です。スクリプトに 'chmod +x' が必要か、deny ルールに該当している可能性があります。"
    fi
    ;;
esac

# ヒントがある場合のみ JSON 出力
if [[ -n "$HINT" ]]; then
  jq -nc --arg ctx "$HINT" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUseFailure",
      additionalContext: $ctx
    }
  }'
fi

exit 0
