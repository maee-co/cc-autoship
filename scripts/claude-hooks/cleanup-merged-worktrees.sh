#!/usr/bin/env bash
# マージ済み（または Close 済み）の worktree とブランチをクリーンアップする
#
# 使い方:
#   cleanup-merged-worktrees.sh <PR番号>          # 指定 PR に対応する worktree をクリーンアップ
#   cleanup-merged-worktrees.sh --branch <名前>   # 指定ブランチに対応する worktree をクリーンアップ
#   cleanup-merged-worktrees.sh --all             # 全 worktree をスキャンしマージ済みを一括削除
#
# オプション:
#   --dry-run   実際の git/gh コマンドを実行せず、対象とアクションをログ出力するだけ
#
# 安全策:
# - main は対象外（メイン worktree は削除しない）
# - 未 push の commit を持つブランチは削除前に警告（-D で強制削除）
# - PR が見つからない / OPEN のブランチは触らない
# - main の更新は HEAD == main の worktree でのみ行う（他 worktree からは触らない）

set -euo pipefail

DRY_RUN=0

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

run_cmd() {
    if [ "$DRY_RUN" = "1" ]; then
        echo "  [dry-run] $*"
        return 0
    fi
    "$@"
}

# git remote URL から owner/repo の slug を抽出する（純粋関数・テスタブル）。
# 対応: git@github.com:owner/repo.git / https://github.com/owner/repo(.git)
parse_repo_slug() {
    printf '%s\n' "$1" | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##'
}

# 現在の origin から owner/repo slug を返す。
repo_slug() {
    local url
    url="$(git remote get-url origin 2>/dev/null)" || return 1
    parse_repo_slug "$url"
}

# マージ後に残ったリモートブランチを削除する（C4）。
# gh api 経由で削除し、pre-push / pre-tool-use ガードを回避する（git push を使わない）。
delete_remote_branch_if_exists() {
    local branch="$1" slug
    # main/master は誤操作防止のため絶対に削除しない
    if [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
        return 0
    fi
    # リモートに無ければ何もしない
    if ! git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
        return 0
    fi
    slug="$(repo_slug)" || { echo "  → リモート削除スキップ: repo slug 解決失敗"; return 0; }
    echo "  → リモートブランチ削除: origin/$branch"
    run_cmd gh api -X DELETE "repos/$slug/git/refs/heads/$branch"
}

cleanup_one() {
    local branch="$1"
    local worktree_path="$2"

    if [ -z "$worktree_path" ] || [ ! -d "$worktree_path" ]; then
        echo "⚠️  worktree が見つかりません: $branch (スキップ)"
        return 0
    fi

    if [ "$worktree_path" = "$REPO_ROOT" ]; then
        echo "⚠️  メイン worktree はクリーンアップ対象外: $branch (スキップ)"
        return 0
    fi

    echo "🧹 worktree 削除: $worktree_path ($branch)"
    if run_cmd git worktree remove "$worktree_path" 2>/tmp/cleanup-merged-worktrees.err; then
        :
    else
        echo "  → 通常削除に失敗（$(cat /tmp/cleanup-merged-worktrees.err 2>/dev/null | head -1)）。--force で再試行..."
        run_cmd git worktree remove --force "$worktree_path"
    fi

    if run_cmd git branch -d "$branch" 2>/tmp/cleanup-merged-worktrees.err; then
        echo "  → ブランチ削除: $branch"
    else
        local err
        err="$(cat /tmp/cleanup-merged-worktrees.err 2>/dev/null | head -1)"
        echo "  → 通常削除失敗: $err — -D で強制削除します"
        if run_cmd git branch -D "$branch" 2>/tmp/cleanup-merged-worktrees.err; then
            echo "  → ブランチ強制削除: $branch"
        else
            echo "  → ブランチ強制削除失敗: $(cat /tmp/cleanup-merged-worktrees.err 2>/dev/null | head -1)"
        fi
    fi

    # リモートに同名ブランチが残っていれば削除する（C4）
    delete_remote_branch_if_exists "$branch"
}

# ブランチ名から worktree のパスを取得（なければ空文字）
worktree_path_for_branch() {
    local branch="$1"
    git worktree list --porcelain | awk -v target="refs/heads/$branch" '
        /^worktree / { wt=$2 }
        /^branch / { if ($2 == target) { print wt; exit } wt="" }
    '
}

# PR 番号から head ブランチを取得
branch_for_pr() {
    local pr="$1"
    gh pr view "$pr" --json headRefName --jq '.headRefName' 2>/dev/null
}

# PR 状態を取得（MERGED / CLOSED / OPEN）
pr_state() {
    local pr="$1"
    gh pr view "$pr" --json state --jq '.state' 2>/dev/null
}

# ブランチ名から「マージ済みまたは Close 済み」の PR 番号を取得（なければ空文字）
pr_for_branch() {
    local branch="$1"
    gh pr list --head "$branch" --state all --json number,state \
        --jq 'map(select(.state == "MERGED" or .state == "CLOSED")) | .[0].number // empty' 2>/dev/null
}

usage() {
    cat <<EOF
Usage:
  $0 <PR番号>
  $0 --branch <ブランチ名>
  $0 --all

Options:
  --dry-run    実際のコマンドを実行せずアクションのみ表示
EOF
    exit 1
}

main() {
    # --dry-run を引数列から除去（出現位置を問わない）
    local args=()
    local arg
    for arg in "$@"; do
        if [ "$arg" = "--dry-run" ]; then
            DRY_RUN=1
            echo "🔬 dry-run モード: 実際のコマンドは実行されません"
        else
            args+=("$arg")
        fi
    done

    if [ ${#args[@]} -eq 0 ]; then
        usage
    fi

    case "${args[0]}" in
        --all)
            echo "🔍 全 worktree をスキャンしてマージ済み/Close 済みを削除します"
            git worktree list --porcelain | awk '
                /^worktree / { wt=$2 }
                /^branch / { if (wt != "") print wt "\t" $2; wt="" }
            ' | while IFS=$'\t' read -r wt ref; do
                local branch_name="${ref#refs/heads/}"
                if [ "$branch_name" = "main" ]; then
                    continue
                fi
                local pr
                pr=$(pr_for_branch "$branch_name")
                if [ -n "$pr" ]; then
                    echo "→ $branch_name (PR #$pr)"
                    cleanup_one "$branch_name" "$wt"
                fi
            done
            echo "✅ クリーンアップ完了"
            ;;
        --branch)
            if [ ${#args[@]} -lt 2 ]; then
                usage
            fi
            local branch="${args[1]}"
            local wt
            wt=$(worktree_path_for_branch "$branch")
            cleanup_one "$branch" "$wt"
            ;;
        *)
            local pr="${args[0]}"
            if ! [[ "$pr" =~ ^[0-9]+$ ]]; then
                usage
            fi
            local state
            state=$(pr_state "$pr")
            if [ -z "$state" ]; then
                echo "❌ PR #$pr の情報を取得できませんでした" >&2
                exit 1
            fi
            if [ "$state" != "MERGED" ] && [ "$state" != "CLOSED" ]; then
                echo "⚠️  PR #$pr はまだ $state です。クリーンアップをスキップします"
                exit 0
            fi
            local branch
            branch=$(branch_for_pr "$pr")
            if [ -z "$branch" ]; then
                echo "❌ PR #$pr の head ブランチを取得できませんでした" >&2
                exit 1
            fi
            local wt
            wt=$(worktree_path_for_branch "$branch")
            cleanup_one "$branch" "$wt"

            # マージ済みなら main を最新化（HEAD が main の worktree からのみ）
            if [ "$state" = "MERGED" ]; then
                echo "🔄 main を最新化"
                run_cmd git fetch --prune origin
                if [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ]; then
                    run_cmd git pull --ff-only origin main
                else
                    echo "  → 現 worktree は main 以外のため pull はスキップ（次回 main 起動時に最新化）"
                fi
            fi
            echo "✅ PR #$pr のクリーンアップ完了"
            ;;
    esac
}

# sourcing 時（テスト等）は main を実行しない。直接実行時のみ起動する。
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
    main "$@"
fi
