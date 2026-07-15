#!/bin/bash
# PreCompact Hook: コンパクション直前にトランスクリプトのスナップショットを
# .sessions/ にバックアップする
#
# 発火タイミング: manual（/compact コマンド）/ auto（自動コンパクション）
# 動作: transcript_path を .sessions/ にコピーするだけのシンプルな実装
#
# 入力 JSON (stdin):
#   { "hook_event_name": "PreCompact", "trigger": "manual|auto", "transcript_path": "..." }

set -uo pipefail

INPUT=$(cat)

# jq が無ければスキップ
if ! command -v jq &>/dev/null; then
  exit 0
fi

# jq を1回だけ呼び出して複数フィールドを一括抽出（fork コスト削減）
# @tsv は空フィールドで位置ズレするため、改行区切りで順に読み込む
{ IFS= read -r TRANSCRIPT_PATH; IFS= read -r TRIGGER; } < <(
  echo "$INPUT" | jq -r '.transcript_path // "", .trigger // ""'
)

# transcript_path が無ければスキップ
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  exit 0
fi

# .sessions/ ディレクトリを CLAUDE_PROJECT_DIR 基準で作成
# mkdir 失敗時は cp を試みず静かにスキップ（書き込み権限なし等の環境への対応）
SESSIONS_DIR="${CLAUDE_PROJECT_DIR:-.}/.sessions"
mkdir -p "$SESSIONS_DIR" || exit 0

# バックアップファイル名: compact_{trigger}_{timestamp}_{元ファイル名}
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BASENAME=$(basename "$TRANSCRIPT_PATH")
DEST="${SESSIONS_DIR}/compact_${TRIGGER:-unknown}_${TIMESTAMP}_${BASENAME}"

cp "$TRANSCRIPT_PATH" "$DEST" 2>/dev/null || true

exit 0
