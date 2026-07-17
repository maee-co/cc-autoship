#!/bin/bash
# PostToolUse Hook: gh pr create 検知 → review と pr-context-summary スキルの起動を順序付きで指示（{ISSUE-ID} で 2 hook を統合）
# Note({ISSUE-ID}): コマンド名をスラッシュ記法ではなく「スキル名を起動」形式にすることで
#   cc-autoship 等プラグイン経由インストール時のプレフィックス（/cc-autoship:review 等）と
#   CC 組込コマンドの衝突を回避する（/review は CC 組込 review に shadow される）
# stdout: Claude 向け structured additionalContext。stderr: 人間オペレーター向け短縮ログ

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/command-match.sh
source "$SCRIPT_DIR/lib/command-match.sh"
# shellcheck source=lib/workflow-scope-check.sh
source "$SCRIPT_DIR/lib/workflow-scope-check.sh"
# shellcheck source=lib/pr-class.sh
source "$SCRIPT_DIR/lib/pr-class.sh"
# shellcheck source=lib/hook-input.sh
source "$SCRIPT_DIR/lib/hook-input.sh"
# protected-paths.sh は core 専用（`[self-improve]` PR の Tier P 判定）で、cc-autoship の
# 配布キットには同梱しない。不在を許容する（#1808）。無条件 source にすると配布先で
# 「No such file or directory」となり本 hook が exit 1 で死に、/review リマインドが出ず
# Issue→PR→review→auto-merge の連鎖が丸ごと止まる（v0.1.14 実害）。
# 同ディレクトリの improvement-outbox.sh が元から使っている `[ -f ]` ガード形に揃える。
# shellcheck source=lib/protected-paths.sh
[ -f "$SCRIPT_DIR/lib/protected-paths.sh" ] && source "$SCRIPT_DIR/lib/protected-paths.sh"

if ! command -v jq &>/dev/null; then
  exit 0
fi

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')

if [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')

# gh pr create コマンドを検知（{ISSUE-ID}: 引用符内・echo/grep 引数での出現は除外する純関数を使用）
if ! is_gh_pr_create_command "$COMMAND"; then
  exit 0
fi

# PR 番号を解決（{ISSUE-ID}）: hook 入力の stdout から URL を抽出 → 取れなければ gh pr view でフォールバック。
# 本番 PostToolUse は `.tool_response.stdout`（公式ドキュメント記載の `.tool_output.stdout` ではない）。
# 旧実装は `.tool_output.stdout` のみを見ていたため本番で常に空になり、PR_NUM 依存の
# workflow scope チェック（{ISSUE-ID}）と PR 分類（{ISSUE-ID}）が一度も発火しなかった（#1108/#1115/#1118/#1120）。
# lib/hook-input.sh の pr_num_resolve が tool_response / tool_output 双方を多段フォールバックで吸収し、
# stdout から取れない場合のみ gh pr view（cwd = PR 作成ブランチの worktree）で解決する。
# 解決不能時は空 → 従来どおり汎用リマインドに劣化（劣化なし）。
PR_NUM="$(pr_num_resolve "$INPUT" 2>/dev/null || true)"

# workflow scope 検知（{ISSUE-ID} / {ISSUE-ID} Phase 2）
# PR 番号が取れた場合のみ、.github/workflows/ 配下の新規追加ファイルを検知
# 検知時は REMINDER に workflow scope チェック項目を追加（順序 3 番目）
WORKFLOW_SCOPE_REMINDER=""
if [ -n "$PR_NUM" ]; then
  NEW_WORKFLOWS=$(get_new_workflow_files_from_pr "$PR_NUM" 2>/dev/null || true)
  if [ -n "$NEW_WORKFLOWS" ]; then
    # 改行を `, ` 区切りに整形（リマインダ本文用）
    NEW_WORKFLOWS_INLINE=$(printf '%s' "$NEW_WORKFLOWS" | tr '\n' ',' | sed 's/,$//; s/,/, /g')
    WORKFLOW_SCOPE_REMINDER="
3. ⚠️ **workflow scope チェック**: \`.github/workflows/\` 配下に新規ファイル追加あり（${NEW_WORKFLOWS_INLINE}）。
   - \`gh auth status\` で OAuth scope に \`workflow\` が含まれているか確認してください
   - 不足なら メンテナ に \`gh auth refresh -s workflow\` を実行いただくよう依頼（PR #N で push 失敗の前例あり）
   - 既に CI が pass している場合 push は成功済なので追加対応不要"
  fi
fi

# PR 分類（{ISSUE-ID} Phase A/B）: light のときだけ review / pr-context-summary を軽量版に切り替える。
# full / strict のときは現行文言と 1 字も変えない（回帰防止）。
# Phase A: pr-context-summary に --lightweight を付与 / Phase B: review スキルに --light を付与。
# pr_class_evaluate は gh 失敗・入力不正時に full へフォールバックし常に 0 を返すため hook を止めない。
PR_CLASS_LINE=""
REVIEW_ARGS="${PR_NUM}"
SUMMARY_ARGS="--mode pre-merge --pr ${PR_NUM}"
if [ -n "$PR_NUM" ]; then
  PR_CLASS_RESULT=$(pr_class_evaluate "$PR_NUM" 2>/dev/null || printf 'full\t')
  PR_CLASS=$(printf '%s' "$PR_CLASS_RESULT" | cut -f1)
  PR_CLASS_REASON=$(printf '%s' "$PR_CLASS_RESULT" | cut -f2-)
  if [ "$PR_CLASS" = "light" ]; then
    REVIEW_ARGS=$(pr_class_review_args_from_class light "$PR_NUM")
    SUMMARY_ARGS=$(pr_class_summary_args_from_class light "$PR_NUM")
    PR_CLASS_LINE="PR 分類: light（${PR_CLASS_REASON}）
"
  fi
fi

# self-modification guard 早期警告（{ISSUE-ID} 自己改善ループ Phase 2a・二重化の 1 段目）
# 判定の実体（オーソリ・最終防衛線）は auto-merge 条件 9（auto-merge-criteria.sh + protected-paths.sh）。
# 本 hook は早期警告のみ（hook は誤発火回避のため suppress されうるため最終防衛線にしない・design §4.3）。
# gh 失敗時は fail-open（警告なしで通常フローに劣化。hook を止めない）。
# protected-paths.sh 不在時（= 配布先）は早期警告自体をスキップする（#1808）。
PROTECTED_PATH_WARNING=""
if [ -n "$PR_NUM" ] && declare -f has_self_improve_marker_from_body >/dev/null 2>&1; then
  PR_DATA_FOR_GUARD=$(gh pr view "$PR_NUM" --json body,files 2>/dev/null || true)
  if [ -n "$PR_DATA_FOR_GUARD" ]; then
    PR_BODY_FOR_GUARD=$(printf '%s' "$PR_DATA_FOR_GUARD" | jq -r '.body // ""' 2>/dev/null || true)
    if has_self_improve_marker_from_body "$PR_BODY_FOR_GUARD" 2>/dev/null; then
      PR_FILES_FOR_GUARD=$(printf '%s' "$PR_DATA_FOR_GUARD" | jq -r '.files[].path' 2>/dev/null || true)
      if ! check_protected_paths_from_files "$PR_FILES_FOR_GUARD" 2>/dev/null; then
        PROTECTED_PATH_WARNING="

⚠️ **self-modification guard 発動**: この PR は \`[self-improve]\` マーカー付きで保護パス（Tier P）に触れています。**\`gh pr edit ${PR_NUM} --add-label ceo-judgment-required\` を実行し、PR 本文に独立行で \`[manual-merge]\` を追記してください**（auto-merge 条件 9 が最終的にブロックしますが、早期可視化のため自分で付与すること）。詳細: \`docs/superpowers/specs/2026-07-06-dev-flow-self-improvement-loop-design.md\` §4"
      fi
    fi
  fi
fi

# 順序付きリマインド: review スキルを最優先、pr-context-summary スキルを 2 番目、workflow scope を 3 番目（該当時のみ）
# 両方とも Claude が呼ばないと走らない（hook は instruction のみで自動実行しない）ため、
# 順序を明示することで review スキル呼び忘れ事故（{ISSUE-ID}）を構造的に防ぐ。
# Note({ISSUE-ID}): コマンド名をスラッシュ記法で書かず「スキル名を起動」形式にすることで
#   cc-autoship 等プラグイン経由インストール時のプレフィックス（/cc-autoship:review 等）と
#   CC 組込コマンドの衝突を回避する（/review は CC 組込 review に shadow される）。
# Note(#1815): レビュー結果の投稿は必ず review-verdict-post.sh（正規経路）を指し、
#   手書き `gh pr comment` を名指ししない。/auto-merge への連鎖の検知経路は 2 つあり、
#   ① スクリプト実行（フラグ signature で検知・言語非依存）② コメント本文（日本語見出しに依存）。
#   旧文言は② を指示しており commands/review.md の①指示と矛盾していた。hook のリマインドの方が
#   先に読まれるため②に乗り、英語見出しでは検知されず連鎖が**エラーなく黙って切れる**
#   （v0.1.15 e2e 実測）。①はスクリプトが見出しと判定節を生成するため英語レビューでも成立する。
if [ -n "$PR_NUM" ]; then
  REMINDER="${PR_CLASS_LINE}PR #${PR_NUM} が作成されました。以下を **順番に** 実行してください:

1. **最優先**: review スキルを起動（引数: ${REVIEW_ARGS}）（一次レビューを実施し、結果は**スキル手順どおり \`review-verdict-post.sh\` で投稿する** — 見出しと判定節はスクリプトが付与し、\`/auto-merge\` への連鎖もこの実行を検知する。手書きのレビューコメントで代替・重複投稿しない）
2. pr-context-summary スキルを起動（引数: ${SUMMARY_ARGS}）（メンテナ とのやり取り・意思決定サマリを GitHub Issue にコメントとして残し、後続タスクへの方針引き継ぎを可能にします）${WORKFLOW_SCOPE_REMINDER}

順序を守ること: review スキルを後回しにすると一次レビュー欠落のリスクがあります（dev-flow ルール参照）。${PROTECTED_PATH_WARNING}"
else
  REMINDER="gh pr create が実行されました。以下を **順番に** 実行してください:

1. **最優先**: review スキルを起動（引数: <PR#>）（一次レビュー。結果は**スキル手順どおり \`review-verdict-post.sh\` で投稿する** — 手書きのレビューコメントで代替しない）
2. pr-context-summary スキルを起動（引数: --mode pre-merge --pr <PR#>）（メンテナ とのやり取り・意思決定を GitHub Issue にコメント記録）

順序を守ること: review スキルを後回しにすると一次レビュー欠落のリスクがあります（dev-flow ルール参照）。"
fi

# stdout: Claude のコンテキストに structured 投入（最も見落とされにくい経路）
jq -n --arg ctx "$REMINDER" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}'

# stderr: 人間オペレーター向け短縮ログ
if [ -n "$PR_NUM" ]; then
  if [ -n "$WORKFLOW_SCOPE_REMINDER" ]; then
    echo "PR #${PR_NUM}: review then pr-context-summary + workflow scope reminder emitted" >&2
  else
    echo "PR #${PR_NUM}: review then pr-context-summary reminder emitted" >&2
  fi
else
  echo "gh pr create detected: review then pr-context-summary reminder emitted" >&2
fi

exit 0