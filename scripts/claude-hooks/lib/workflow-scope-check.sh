#!/bin/bash
# workflow-scope-check.sh — `.github/workflows/*.{yml,yaml}` の新規追加検知
#
# 純関数ライブラリ。テストは scripts/claude-hooks/__tests__/test-workflow-scope-check.sh。
#
# 目的:
#   PR に `.github/workflows/*.{yml,yaml}` の新規ファイル追加が含まれる場合、
#   OAuth workflow scope 不足で push が失敗する事故（PR #N で実発生）を未然に防ぐため
#   hook 側で検知して Claude / CEO に gh auth status / gh auth refresh -s workflow を促す。
#
# 関数:
#   - is_workflow_file <path>: 単一パスが workflow ファイルか判定
#   - has_new_workflow_in_files: stdin の改行区切りパス一覧に workflow が含まれるか判定
#   - get_new_workflow_files_from_pr <pr_num>: PR の **新規追加** ファイルから workflow を抽出
#
# `set -e` を含めていない（意図的）:
#   has_new_workflow_in_files が `return 1`（該当なし）を返す際、呼び出し側で
#   `if has_new_workflow_in_files; then ...` の真偽判定に使えるようにするため。
#   source 先の親スクリプトに `-e` が設定されていても、`if` 文中の return 1 は
#   abort を発生させないので実質的に問題ない。
#
# `set -uo pipefail` は直接実行時のみ有効化する:
#   source 先の親シェルに nounset / pipefail を漏らさないため、BASH_SOURCE チェックでガード。
#   （PR #N の ui-change-detect.sh 修正と同じ方針）

# このファイルを直接実行した場合のみ strict mode を有効化する（source 時は親の設定を尊重）
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -uo pipefail
fi

# is_workflow_file: ファイルパスが .github/workflows/*.{yml,yaml} 直下か判定
# 入力: $1 = ファイルパス
# 戻り値: 0 = workflow ファイル / 1 = それ以外
# 注: サブディレクトリ (.github/workflows/subdir/foo.yml) は対象外（GitHub Actions の仕様上、
#     workflow ファイルは workflows/ 直下のみが認識される）
is_workflow_file() {
  local path="${1:-}"
  case "$path" in
    .github/workflows/*.yml|.github/workflows/*.yaml)
      # サブディレクトリを除外（パターン中の * が / を含む path にもマッチしてしまうため）
      case "$path" in
        .github/workflows/*/*) return 1 ;;
        *) return 0 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

# has_new_workflow_in_files: stdin から改行区切りファイルパス一覧を受け取り、
# 1 件でも workflow ファイルが含まれていれば 0 を返す
# 戻り値: 0 = 検知 / 1 = なし
has_new_workflow_in_files() {
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    if is_workflow_file "$path"; then
      return 0
    fi
  done
  return 1
}

# get_new_workflow_files_from_pr: PR の **新規追加** ファイル一覧から workflow ファイルだけ抽出
# 入力: $1 = PR 番号
# 出力: 改行区切りで該当ファイルパス。該当なしは空出力
# 失敗: PR 番号未指定 / repo 取得失敗 / gh api 失敗 → 空出力 + return 1
get_new_workflow_files_from_pr() {
  local pr="${1:-}"
  if [ -z "$pr" ]; then
    return 1
  fi
  local repo
  repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null)
  if [ -z "$repo" ]; then
    return 1
  fi
  # gh api で /pulls/:n/files から status:"added" の filename を取得
  # --paginate でファイル数 > 30 でも全件取得
  gh api "repos/$repo/pulls/$pr/files" --paginate \
    --jq '.[] | select(.status == "added") | .filename' 2>/dev/null \
    | while IFS= read -r path; do
        [ -z "$path" ] && continue
        if is_workflow_file "$path"; then
          printf '%s\n' "$path"
        fi
      done
}