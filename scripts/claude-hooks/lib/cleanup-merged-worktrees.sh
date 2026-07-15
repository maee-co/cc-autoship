#!/bin/bash
# マージ済み worktree を検出し、削除する共通関数。
# session-start / post-tool-use-pr-merge の両方から source して利用する。
#
# 使い方:
#   source scripts/claude-hooks/lib/cleanup-merged-worktrees.sh
#   cleanup_merged_worktrees            # stdout に結果を出力
#   cleanup_merged_worktrees stderr     # stderr に結果を出力
#
# 動作:
#   - git worktree list を走査し、main/master 以外のブランチを対象とする
#   - gh pr list --state merged で PR がマージ済みか確認（squash/rebase にも対応）
#   - 安全条件を満たす場合のみ自動削除（以下すべてを確認）:
#     1. PR が MERGED 状態であること
#     2. worktree に未コミット変更がない（git -C <path> status --porcelain が空）
#   - 安全でない場合（未コミット変更あり等）は警告のみ
#   - 現在 cwd が対象 worktree 配下の場合は削除をスキップ（自己削除を防ぐ）

cleanup_merged_worktrees() {
  local output_fd="${1:-stdout}"

  command -v gh &>/dev/null || return 0
  command -v git &>/dev/null || return 0

  local worktrees
  worktrees=$(git worktree list 2>/dev/null | tail -n +2)
  [ -z "$worktrees" ] && return 0

  local cwd
  cwd=$(pwd -P 2>/dev/null || pwd)

  local wt_path wt_branch pr_number wt_real msg dirty_files git_status_exit
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    wt_path=$(echo "$line" | awk '{print $1}')
    wt_branch=$(echo "$line" | sed -n 's/.*\[\(.*\)\]$/\1/p')
    [ -z "$wt_branch" ] && continue
    [ "$wt_branch" = "main" ] && continue
    [ "$wt_branch" = "master" ] && continue

    pr_number=$(gh pr list --head "$wt_branch" --state merged --json number -q '.[0].number' 2>/dev/null)
    [ -z "$pr_number" ] && continue

    # 安全条件チェック: 未コミット変更の有無を確認（git branch -d と組み合わせて誤削除を防ぐ）
    # git -C 失敗（存在しないパス等）は dirty とみなして安全側（スキップ）に倒す
    # --untracked-files=no: build 成果物 / node_modules / .env 等の未追跡ファイルは
    #   dirty 判定に含めない（追跡済みの未コミット変更のみを削除ブロック条件とする）
    dirty_files=$(git -C "$wt_path" status --porcelain --untracked-files=no 2>/dev/null)
    git_status_exit=$?
    if [ "$git_status_exit" -ne 0 ] || [ -n "$dirty_files" ]; then
      if [ "$git_status_exit" -ne 0 ]; then
        msg="⚠ スキップ（状態確認失敗）: $wt_branch (PR #${pr_number}) — worktree パスにアクセスできません: $wt_path"
      else
        msg="⚠ スキップ（未コミット変更あり）: $wt_branch (PR #${pr_number}) — 手動確認後に削除してください"
      fi
      if [ "$output_fd" = "stderr" ]; then
        echo "$msg" >&2
      else
        echo "$msg"
      fi
      continue
    fi

    # 自己削除を回避: 現在の cwd が対象 worktree 配下なら警告のみ
    wt_real=$(cd "$wt_path" 2>/dev/null && pwd -P)
    if [ -n "$wt_real" ] && [ "${cwd#"$wt_real"}" != "$cwd" ]; then
      msg="⚠ スキップ（自身の worktree）: $wt_branch (PR #${pr_number}) — 親ディレクトリから再実行してください"
    elif git worktree remove "$wt_path" 2>/dev/null; then
      # worktree 削除成功後、ブランチを個別に削除（失敗しても worktree は既に削除済み）
      # PR は上流で MERGED 確認済み（gh pr list --state merged）。squash/rebase マージでは
      # ブランチが main の祖先にならず -d が "not fully merged" で拒否するため、
      # -d 失敗時は -D で強制削除にフォールバックする（マージ済みなので安全）。
      if git branch -d "$wt_branch" 2>/dev/null || git branch -D "$wt_branch" 2>/dev/null; then
        msg="🧹 削除しました: $wt_branch (PR #${pr_number} マージ済み)"
      else
        msg="🧹 worktree 削除済み（ブランチ削除失敗）: $wt_branch (PR #${pr_number}) — 手動削除: git branch -d $wt_branch"
      fi
    else
      msg="⚠ スキップ（worktree 削除失敗）: $wt_branch (PR #${pr_number}) — 手動削除: git worktree remove $wt_path && git branch -d $wt_branch"
    fi

    if [ "$output_fd" = "stderr" ]; then
      echo "$msg" >&2
    else
      echo "$msg"
    fi
  done <<< "$worktrees"
}
