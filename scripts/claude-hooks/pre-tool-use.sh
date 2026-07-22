#!/bin/bash
# PreToolUse Hook: 破壊的コマンドをブロック
# stdin から JSON を受け取り、危険なパターンを検出して exit 2 でブロック

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/command-match.sh
source "$SCRIPT_DIR/lib/command-match.sh"
# shellcheck source=lib/repo-target.sh
source "$SCRIPT_DIR/lib/repo-target.sh"

# jq が無ければ安全側に倒してスキップ（ブロックできないが、クラッシュもしない）
if ! command -v jq &>/dev/null; then
  exit 0
fi

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Bash ツール以外はスキップ
if [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# ブロック対象パターン
block_patterns=(
  'rm -rf /($| )'
  'rm -rf /[a-zA-Z]'
  'rm -rf ~'
  'DROP TABLE'
  'DROP DATABASE'
  'TRUNCATE '
  # force push パターン: --force / -f を独立トークン（直後に空白）として要求し、
  # ブランチ名内に偶発的に "-f...-main" を含む通常 push（例: worktree-feat+{ISSUE-ID}-...-main-protection）
  # が誤発火しないようにする
  'git push .*--force .*main( |$)'
  'git push .*--force .*master( |$)'
  'git push .*-f .*main( |$)'
  'git push .*-f .*master( |$)'
  'git reset --hard'
)

for pattern in "${block_patterns[@]}"; do
  if echo "$COMMAND" | grep -qiE "$pattern"; then
    echo "ブロック: 破壊的コマンドを検出 — $pattern" >&2
    exit 2
  fi
done

# bootstrap 例外: remote にまだ main（デフォルトブランチ）が無い新規 repo の初回 push は許可する。
# テスト用に環境変数 CLAUDE_HOOK_FAKE_REMOTE_MAIN（1=あり/0=無し）で上書き可能にし、
# 未設定時のみ実 git ls-remote を呼ぶ（{ISSUE-ID} P3）。
#
# fail-closed 方針（レビュー指摘 Critical 修正）:
# git ls-remote がネットワーク瞬断等で失敗した場合、stdout は main 未存在時と同じ「空」になるため、
# 「本当に main が無い（成功して空）」と「判定できない（コマンド自体が失敗）」を区別する。
# 判定できない場合は安全側 = main あり扱い（return 0 = ブロック維持）に倒す。
# ネットワークハング対策として timeout（存在する環境のみ）でラップする。
_ls_remote_heads() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 5 git ls-remote --heads origin "$1" 2>/dev/null
  else
    git ls-remote --heads origin "$1" 2>/dev/null
  fi
}

_remote_has_main() {
  if [ -n "${CLAUDE_HOOK_FAKE_REMOTE_MAIN:-}" ]; then
    [ "${CLAUDE_HOOK_FAKE_REMOTE_MAIN}" = "1" ]
    return
  fi
  local out rc
  if out=$(_ls_remote_heads main); then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
    return 0 # main あり
  elif [ "$rc" -ne 0 ]; then
    return 0 # ls-remote 失敗（network 等）→ fail-closed（ブロック維持）
  fi
  if out=$(_ls_remote_heads master); then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
    return 0 # master あり
  elif [ "$rc" -ne 0 ]; then
    return 0 # ls-remote 失敗（network 等）→ fail-closed（ブロック維持）
  fi
  return 1 # main/master とも「成功して空」= 本当に無い → bootstrap 許可
}

# --- dev-flow 強制: main ブランチでの直接 commit/push をブロック ---
# 判定は「CWD の実ブランチ」または「コマンド中の git -C <path> が指す dir の実ブランチ」の
# いずれかが main/master なら対象にする（B-1・{ISSUE-ID} P3）。
# 旧実装は CWD ブランチのみで判定していたため、`git -C <path> commit` が
# `grep -qE '(^|[;&|]\s*)git commit'` にマッチせず素通りしていた
# （worktree 誤ブロックの原因かつ、main repo に対する `git -C /repo commit` が main
#  ブロックを迂回できる穴になっていた。CWD が feature でも -C 先が main なら塞ぐ）。
# resolve_target_branch / cm_git_danger_targets_main（lib/command-match.sh）で
# セグメント単位に対象ブランチを実解決してこの穴を塞ぐ。
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

# 軽量プリフィルタ: コマンドに -C フラグが含まれない場合、対象は必ず CWD のみになるため
# CURRENT_BRANCH だけで判定できる（無関係なコマンドで cm_git_danger_targets_main の
# セグメント走査・git 呼び出しを避ける最適化。正しさには影響しない）。
COMMAND_HAS_DASH_C=0
if printf '%s' "$COMMAND" | grep -qE '(^|[[:space:]])-C(=|[[:space:]])'; then
  COMMAND_HAS_DASH_C=1
fi

if [ "$CURRENT_BRANCH" = "main" ] || [ "$CURRENT_BRANCH" = "master" ] || [ "$COMMAND_HAS_DASH_C" = "1" ]; then
  # 外部リポジトリ判定用に core の toplevel を解決
  CORE_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  # worktree バイパス判定:
  # 「引用符・コマンド置換除去 → セグメント分割 → セグメント先頭が cd .claude/worktrees/」のみ通過。
  # 旧実装（素の grep）は以下の経路をバイパスできていた（セキュリティ修正 #N / #N）:
  #   C-1: echo "cd .claude/worktrees/x" && git commit -m x  （引用符内文字列に反応）
  #   C-2: git -C /repo/.claude/worktrees/foo status && git commit  （-C は後段 commit に効かない）
  #   C-3: git commit -m x ; cd .claude/worktrees/foo  （commit が先でも通過）
  # is_worktree_cd_bypass の危険コマンド判定（danger_re）も -C 形式を含むよう拡張済み
  # （C-3 の -C 版: git -C /main commit -m x ; cd .claude/worktrees/foo が誤ってバイパス
  #  扱いにならないようにするため・B-1・{ISSUE-ID} P3）。
  if is_worktree_cd_bypass "$COMMAND"; then
    :  # dev-flow チェックのみスキップ（後続チェックは継続）
  elif command_targets_only_external_repo "$COMMAND" "$CORE_ROOT"; then
    # {ISSUE-ID}: すべての git commit/push が core 以外のリポジトリ
    # （cd <外部repo> / git -C <外部repo>）を対象に実行される場合、core の dev-flow
    # 対象外なので main 保護をスキップする。判定不能時は fail-closed（下の else でブロック）。
    # 破壊的コマンド保護（force push / reset --hard 等）は上で判定済みのため維持される。
    :
  else
    # commit/push 検知は command-match.sh の cm_git_danger_targets_main に集約する
    # （{ISSUE-ID} + {ISSUE-ID} P3 B-1 の統合）:
    #   - {ISSUE-ID}: 実トークン化ベースの検知（is_git_commit_command と同じ
    #     「コマンド置換 + bash -c 展開 → クォート認識セグメント分割 → 実トークン化」
    #     パイプラインを内部で使うため、`git "commit"` / `git p"u"sh` のような
    #     引用符分割サブコマンドも復元して検知する）
    #   - B-1: セグメント単位で `git -C <path>` の対象ブランチを実解決して判定する。
    #     CWD が main でも `git -C <worktree> commit` は正当（誤ブロック解消）、
    #     逆に CWD が feature でも `git -C <main repo> commit` はブロック（穴の封鎖）。
    #     -C 指定ありで実ブランチ解決不能なら fail-closed（ブロック側）。
    if cm_git_danger_targets_main "$COMMAND" "commit"; then
      echo "ブロック: main ブランチでの直接コミットは dev-flow 違反です。worktree を作成してください。" >&2
      exit 2
    fi
    if cm_git_danger_targets_main "$COMMAND" "push"; then
      # 例外: feature ブランチのリモート削除（--delete / -d）は dev-flow 違反でない
      # （マージ後の後始末で使う）。ただし main/master の削除は誤操作防止のため引き続きブロック。
      # main/master は空白だけでなく "/" 境界も見て、refs/heads/main 形式の削除も取りこぼさない。
      # 判定は is_git_push_delete_non_main_command に集約（トークン化済みセグメントで判定するため
      # push/delete/main いずれかが引用符分割されていても回避できない）。
      if is_git_push_delete_non_main_command "$COMMAND"; then
        :  # リモートブランチ削除（main/master 以外）は許可
      elif ! _remote_has_main; then
        :  # bootstrap 許可: remote にまだ main が無い新規 repo の初回 push（{ISSUE-ID} P3）
      else
        echo "ブロック: main ブランチでの直接プッシュは dev-flow 違反です。PR 経由でマージしてください。" >&2
        exit 2
      fi
    fi
  fi
fi

exit 0