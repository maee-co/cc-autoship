#!/usr/bin/env bash
# PreToolUse Hook: main / master ブランチでの gh pr create をブロック
#
# 背景（{ISSUE-ID}）:
#   PR #N 作成時、worktree ではなくリポジトリルート（main ブランチ）で gh pr create を実行し
#   "No commits between main and main" エラーで失敗 → worktree 内で再実行する手戻りが発生した。
#   main での直接 commit/push は pre-tool-use.sh でブロック済みだが、gh pr create には同等のガードがなかった。
#
# 検知ロジック:
#   scripts/claude-hooks/lib/command-match.sh の is_gh_pr_create_command を使用。
#   引用符の内側（"gh pr create" / 'gh pr create'）や echo / grep / cat の引数としての出現は除外する
#   （{ISSUE-ID} のコメントで メンテナ が指摘した誤発火リスクへの対処）。
#
# バイパス条件:
#   コマンドに `cd .../.claude/worktrees/...` を含む場合は通過させる。
#   既存 pre-tool-use.sh の dev-flow バイパスと同じパターンで、ワンライナーで worktree に遷移してから
#   PR を作成するケースを許容する。
#
# 対象ブランチ判定（B-2 / {ISSUE-ID} P3）:
#   `gh pr create --head <branch>` があればその値、無ければ CWD の実ブランチで main/master
#   判定する（scripts/claude-hooks/lib/command-match.sh の gh_pr_create_head_branch）。
#   `--head feat/x --base main -R owner/repo` のように CWD を main に置いたまま
#   --head/-R でリモート指定 PR を作る正当な用法でも無条件ブロックされていた穴を塞ぐ。
#   `--head main`（誤用）は CWD に関わらずブロックする。
#
#   main/master 判定は cm_is_main_or_master_branch（正規化込み）で行う（B-2 追加修正）。
#   gh_pr_create_head_branch は生値をそのまま返す契約のため、`--head "main"` / `--head 'main'`
#   （引用符）・`--head owner:main`（フォーク構文）・`--head MAIN`（大文字）のいずれも
#   正規化してから main/master と比較しないと素通りしてしまう（実機再現済みの Critical 修正）。
#
# 失敗モード:
#   jq 未インストール時は安全側に倒してスキップ（ブロックできないが、クラッシュもしない）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/command-match.sh
source "$SCRIPT_DIR/lib/command-match.sh"
# shellcheck source=lib/repo-target.sh
source "$SCRIPT_DIR/lib/repo-target.sh"

if ! command -v jq &>/dev/null; then
    exit 0
fi

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')

if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)

if [ -z "$COMMAND" ]; then
    exit 0
fi

# 実行コマンドとしての gh pr create でなければスキップ（誤発火回避）
if ! is_gh_pr_create_command "$COMMAND"; then
    exit 0
fi

# worktree への cd を含む場合は通過: `cd <path>.claude/worktrees/... && gh pr create`
# 判定は lib/command-match.sh の共通純関数 is_worktree_cd_bypass に集約（#883 で DRY 化）。
# 危険コマンドとして gh pr create を渡し、「cd worktree が gh pr create より前にある」ときのみ
# バイパスする。これにより以下のバイパス経路を塞ぐ:
#   - echo "cd .claude/worktrees/x" && gh pr create        （C-1: 引用符内の文字列）
#   - git -C /repo/.claude/worktrees/foo status && gh pr create （C-2: -C は後段に効かない）
#   - echo $(cd .claude/worktrees/x) && gh pr create       （C-4: コマンド置換は親 cwd 不変）
#   - true `cd .claude/worktrees/x` && gh pr create        （C-5: バッククォートは親 cwd 不変）
if is_worktree_cd_bypass "$COMMAND" '^gh[[:space:]]+pr[[:space:]]+create'; then
    exit 0
fi

# 対象ブランチ確認（B-2 / {ISSUE-ID} P3）:
#   `gh pr create --head <branch>` があればその値、無ければ CWD の実ブランチで判定する。
#   `--head feat/x --base main -R owner/repo` のように CWD が main のままでも --head で
#   feature を指定する cross-repo/リモート指定 PR 作成は正当な用法のため cd を強制しない。
#   `--head main`（明示的に main を head にする誤用）は CWD に関わらずブロックする。
HEAD_BRANCH=$(gh_pr_create_head_branch "$COMMAND")

if [ -n "$HEAD_BRANCH" ]; then
    TARGET_BRANCH="$HEAD_BRANCH"
else
    TARGET_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
fi

if ! cm_is_main_or_master_branch "$TARGET_BRANCH"; then
    exit 0
fi

# {ISSUE-ID}: 外部リポジトリを対象とする gh pr create は core の dev-flow 対象外として通過。
#   - gh pr create --repo <owner>/<repo> / -R <slug> が core 以外を明示指定
#   - cd <外部repo> && gh pr create（cwd が core 以外の git repo に解決できる）
# 判定不能な場合は fail-closed（下のブロックに進む）。
# B-2（--head 判定）との優先順位: 外部リポジトリ skip が優先。外部 repo の main を
# --head に指定する PR は core の dev-flow 対象外（core 対象なら上の TARGET_BRANCH
# 判定で main/master と確定した時のみここに到達し、外部と確定できなければブロック）。
CORE_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if command_targets_only_external_repo "$COMMAND" "$CORE_ROOT" \
    '^gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)'; then
    exit 0
fi

# main / master を対象にした gh pr create をブロック
cat >&2 <<'EOF'
ブロック: main / master ブランチからは PR を作成できません（dev-flow 違反）。

  worktree に cd してから実行してください:
    cd .claude/worktrees/<branch> && gh pr create ...

  cd せずに --head <branch> でリモート指定 PR を作成する場合:
    gh pr create --head <branch> --base main -R owner/repo ...
    （--head に main / master は指定不可）

  新規 worktree が必要な場合:
    git worktree add .claude/worktrees/feat/{ISSUE-ID}-<scope>-<desc> -b feat/{ISSUE-ID}-<scope>-<desc>
    cd .claude/worktrees/feat/{ISSUE-ID}-<scope>-<desc>
    gh pr create ...
EOF
exit 2