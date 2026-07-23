#!/usr/bin/env bash
# PreToolUse Hook: CI が赤い PR の手動 `gh pr merge` をブロックする（#N / {ISSUE-ID}）
#
# 背景:
#   auto-merge の「CI 全 check pass」ゲートは /auto-merge 経路のみで、`gh pr merge`
#   （手動）には効かない。GitHub Free × private のためブランチ保護（required status
#   checks）も使えず、static-checks=FAILURE の PR #N が手動マージされて main の CI が
#   全滅する事故が実発生した（#N / 復旧 #N）。本 hook が gh 経由の主要経路を塞ぐ
#   （GitHub Web UI 経由は捕捉不可 — 完全ではないが規律依存を構造ガードに変える）。
#
# 判定:
#   - `gh pr checks <PR>` の state 列に fail / error があればブロック（exit 2）
#   - pending はブロックしない（実行中マージの是非は /auto-merge 経路の CI 待ちが担う）
#   - opt-out: PR 本文に独立行 `[force-merge]`（意図的な赤マージ・記法は [manual-merge] と同じ）
#
# 失敗モード（fail-open の理由）:
#   jq / gh 不在・PR 番号解決不可・checks 取得失敗（認証切れ等）はスキップして通す。
#   マージ可否の最終ゲートではなく「赤マージ事故の主要経路を塞ぐ網」であり、
#   gh 障害時に全マージを止める方が実害が大きい。CI 未設定 repo（checks 空）も通す。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/command-match.sh
source "$SCRIPT_DIR/lib/command-match.sh"
# shellcheck source=lib/merge-ci-gate.sh
source "$SCRIPT_DIR/lib/merge-ci-gate.sh"

if ! command -v jq &>/dev/null || ! command -v gh &>/dev/null; then
    exit 0
fi

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')

if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')

if ! is_gh_pr_merge_command "$COMMAND"; then
    exit 0
fi

# --auto / --disable-auto は判定対象外（--auto は「green になったら自動マージ」= 本ゲートの
# 目的そのもの。ブロックすると [force-merge] 濫用を誘発し形骸化する）
if mcg_is_auto_merge_command "$COMMAND"; then
    exit 0
fi

# repo 解決: -R / --repo / URL の owner/repo。空なら現在の repo。
# 番号だけを後段に渡すと別 repo の PR を現在 repo で照会してしまうため必ず引き継ぐ
REPO=$(mcg_repo_from_merge_command "$COMMAND")
# 展開は必ず ${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"} のガード形で書く（テストが静的に強制する）。
# 素の macOS の /bin/bash は 3.2 で、`set -u` 下の空配列 "${A[@]}" を unbound として fatal 終了する
# （bash 4.4 で修正済み）。本 hook は settings.json から `bash <script>` = PATH の bash で起動され、
# homebrew bash が無い環境では 3.2 が使われる。素の形だと repo 指定なしの `gh pr merge <N>`（＝最も
# 一般的な経路）で毎回 fatal し、exit 1 = 非ブロックのため **赤 PR がゲートを素通りする**。
# 本 hook は cc-autoship として OSS 配布されるため、配布先の素の macOS で顕在化する。
GH_REPO_ARGS=()
CROSS_REPO=0
if [ -n "$REPO" ]; then
    GH_REPO_ARGS=(-R "$REPO")
    CROSS_REPO=1
fi

# PR 番号解決: コマンド明示 > 現在ブランチの PR。解決できなければ fail-open
PR=$(mcg_pr_number_from_merge_command "$COMMAND")
if [ -z "$PR" ]; then
    PR=$(gh pr view "${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"}" --json number -q .number 2>/dev/null || true)
fi
if [ -z "$PR" ]; then
    exit 0
fi

# opt-out: PR 本文の独立行 [force-merge]
BODY=$(gh pr view "${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"}" "$PR" --json body -q .body 2>/dev/null || true)
if [ -n "$BODY" ] && mcg_has_force_merge_tag "$BODY"; then
    exit 0
fi

# gh pr checks は failing があると非ゼロ exit するため || true で出力だけ受ける
CHECKS=$(gh pr checks "${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"}" "$PR" 2>/dev/null || true)

# checks が空のとき「CI 未設定 repo」と「CI はあるが head SHA に未報告」を区別する。
# 空を一律 fail-open すると、CI を直して push した直後のマージが素通りし #N を再演する
ROLLUP_LEN=$(gh pr view "${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"}" "$PR" --json statusCheckRollup \
    --jq '.statusCheckRollup | length' 2>/dev/null || true)
WORKFLOWS=$(mcg_workflows_exist "${CLAUDE_PROJECT_DIR:-.}" "$CROSS_REPO")
PRESENCE=$(mcg_ci_presence_decision "${ROLLUP_LEN}" "$WORKFLOWS")

if [ -z "$CHECKS" ]; then
    if [ "$PRESENCE" = "absent" ]; then
        exit 0
    fi
    {
        echo "🚫 PR #${PR} は CI の結果がまだ報告されていません。手動マージをブロックしました（赤マージ事故防止）。"
        echo ""
        echo "この repo には workflow 定義があるため「CI 未設定」ではなく「未報告」と判定しました。"
        echo "push 直後は checks が head SHA に未登録のため、この状態でマージすると CI 結果を見ずに main へ入ります。"
        echo ""
        echo "対応: CI の登録・完了を待ってから再実行するか、/auto-merge ${PR} を使ってください。"
        echo "意図的なマージ（インフラ都合等）は PR 本文に独立行で [force-merge] を追加すると通過できます。"
    } >&2
    exit 2
fi

FAILING=$(mcg_failing_from_checks "$CHECKS")
if [ -n "$FAILING" ]; then
    {
        echo "🚫 PR #${PR} は CI が失敗しています。手動マージをブロックしました（赤マージ事故防止）。"
        echo ""
        echo "failing checks:"
        printf '%s\n' "$FAILING" | sed 's/^/  - /'
        echo ""
        echo "対応: CI を green にしてから再実行するか、/auto-merge ${PR} を使ってください。"
        echo "意図的な赤マージ（インフラ都合等）は PR 本文に独立行で [force-merge] を追加すると通過できます。"
    } >&2
    exit 2
fi

exit 0