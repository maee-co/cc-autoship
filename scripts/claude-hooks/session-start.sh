#!/bin/bash
# SessionStart Hook: セッション開始時の環境チェック（情報表示のみ）

set -uo pipefail

echo "=== Claude Code Session ==="

# ブランチ名
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "不明")
echo "ブランチ: $BRANCH"

# 未コミット変更数
CHANGES=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
if [ "$CHANGES" -gt 0 ]; then
  echo "未コミット変更: ${CHANGES} ファイル"
fi

# Node.js バージョン
NODE_VER=$(node --version 2>/dev/null || echo "未インストール")
echo "Node.js: $NODE_VER"

# アクティブな worktree
WORKTREES=$(git worktree list 2>/dev/null | tail -n +2)
if [ -n "$WORKTREES" ]; then
  WTCOUNT=$(echo "$WORKTREES" | wc -l | tr -d ' ')
  echo "Worktree: ${WTCOUNT} 個"
fi

# --- マージ済み worktree の検出・クリーンアップ ---
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HOOK_DIR/lib/cleanup-merged-worktrees.sh"
cleanup_merged_worktrees

# --- dev-flow リマインド ---
if [ "$BRANCH" = "main" ]; then
  echo ""
  echo "⚠ dev-flow: 実装作業は worktree で行ってください"
  echo "  手順: Issue作成 → git worktree add → 実装 → PR"
fi

echo "==========================="

exit 0
