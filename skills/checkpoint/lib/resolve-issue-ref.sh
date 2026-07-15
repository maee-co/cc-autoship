# shellcheck shell=bash
# checkpoint スキル: Issue 参照（GitHub 番号 / Linear ID）の判別・抽出ユーティリティ
#
# このファイルは source して使う純関数のみを提供する（副作用なし）。
# POSIX の case + パラメータ展開のみで実装し、bash / zsh / sh いずれで source されても
# 同一に動作する。BASH_REMATCH は使わない（zsh から source すると BASH_REMATCH が
# 機能せず番号が欠落する罠を回避するため。{ISSUE-ID} レビュー指摘1）。
# 大文字小文字無視は case の文字クラス `[Mm][Aa][Ee]` で行い、出力は常に `MAE-` に正規化する。
# {ISSUE-ID} → GitHub Issue 番号の実解決は Linear MCP 経由で SKILL.md 手順が行う。

# classify_issue_ref <ref>
#   入力を分類して stdout に出力:
#     - 数字のみ           → "github:<N>"
#     - MAE-<数字>（大小可） → "linear:MAE-<N>"（大文字に正規化）
#     - それ以外            → stderr にエラー、return 1
classify_issue_ref() {
  local ref="${1:-}" num
  # 数字のみ → GitHub Issue 番号
  case "$ref" in
    '') ;;
    *[!0-9]*) ;;            # 非数字を含む → 数字判定から外れ、MAE 判定へ
    *) printf 'github:%s\n' "$ref"; return 0 ;;
  esac
  # MAE-<数字>（大文字小文字無視・完全一致）→ Linear ID
  case "$ref" in
    [Mm][Aa][Ee]-*)
      num="${ref#*-}"        # 最初の '-' 以降（"114" / "12-34" 等）
      case "$num" in
        '' | *[!0-9]*) ;;    # MAE- の後が数字のみでない → 無効
        *) printf 'linear:MAE-%s\n' "$num"; return 0 ;;
      esac
      ;;
  esac
  printf 'error: 無効な Issue 参照: %s（例: 123 または {ISSUE-ID}）\n' "$ref" >&2
  return 1
}

# extract_issue_ref_from_branch <branch>
#   ブランチ名から Issue 参照を抽出して stdout に出力:
#     - (feat|fix)/MAE-<数字>... → "MAE-<N>"（大文字に正規化・先頭の数字列のみ）
#     - (feat|fix)/<数字>...     → "<N>"（後方互換: 素の GitHub 番号）
#     - 抽出不可                 → return 1
extract_issue_ref_from_branch() {
  local branch="${1:-}" rest num
  case "$branch" in
    feat/*) rest="${branch#feat/}" ;;
    fix/*)  rest="${branch#fix/}" ;;
    *) return 1 ;;
  esac
  case "$rest" in
    [Mm][Aa][Ee]-[0-9]*)
      num="${rest#*-}"        # "204-token-rotation"
      num="${num%%[!0-9]*}"   # 先頭の数字列のみ → "204"
      printf 'MAE-%s\n' "$num"
      return 0
      ;;
    [0-9]*)
      num="${rest%%[!0-9]*}"  # "120-foo" → "120"
      printf '%s\n' "$num"
      return 0
      ;;
  esac
  return 1
}