#!/bin/bash
# improvement-outbox.sh — 自己改善ループの即時 outbox writer（{ISSUE-ID} Phase 1a）
# 設計: docs/superpowers/specs/2026-07-06-dev-flow-self-improvement-loop-design.md §5.2
#
# 各書き手（/auto-merge 等）は checkout・ブランチ状態に依存せず常に成功する追記だけを行い、
# 週次で /repo-maintenance（Phase 1b）が outbox を 3 つの JSONL（pr-outcomes/backlog/ledger）へ
# 合流させて単一ライターでコミットする。これにより main 直接コミットブロック・並行追記競合を回避する。
# 本ファイルは追記 I/O + 純関数のみ。副作用は gitignore 済み .sessions/ 配下 outbox への append だけ。

# outbox パス（.sessions/ 配下・gitignore 済み）
# Args: sessions_dir
io_outbox_path() {
  echo "${1:-.sessions}/improvement-outbox.jsonl"
}

# JSON 1 行を outbox へ追記する。壊れた JSON は捨て、常に 0 を返す（非ブロッキング）。
# Args: sessions_dir json_line
io_append() {
  local sessions_dir="$1" line="$2" compact
  compact="$(printf '%s' "$line" | jq -c . 2>/dev/null)" || return 0
  [ -z "$compact" ] && return 0
  mkdir -p "$sessions_dir" 2>/dev/null || return 0
  printf '%s\n' "$compact" >> "$(io_outbox_path "$sessions_dir")" 2>/dev/null || true
  return 0
}

# 純関数: レビュー本文から判定ステータス（pass/要確認/fail）を抽出する。無ければ空。
# 判定行は太字（`**pass**` 等）で書かれる規約（review.md）。末尾の 1 件を採る。
# Args: review_body
io_extract_review_status() {
  printf '%s' "${1:-}" | grep -oE '\*\*(pass|要確認|fail)\*\*' | tail -1 | tr -d '*'
}

# 純関数: レビュー本文の 4 軸表から Critical/Major/Minor の指摘数を数える。
# 出力: "critical major minor"（表が無ければ "0 0 0"）。
# 指摘行 = `| N | <重要度> | <信頼度数値> | ...`（重要度セル + 信頼度が数値のセルの AND）。
# これにより見出し行・区切り行・散文中の "Critical/Major" 言及を誤カウントしない。
# Args: review_body
io_count_review_severities() {
  local body="${1:-}" c=0 mj=0 mn=0 line sev
  while IFS= read -r line; do
    printf '%s' "$line" | grep -qE '^\|[^|]*\|[[:space:]]*(Critical|Major|Minor)[[:space:]]*\|[[:space:]]*[0-9]+[[:space:]]*\|' || continue
    sev="$(printf '%s' "$line" | awk -F'|' '{gsub(/[[:space:]]/,"",$3); print $3}')"
    case "$sev" in
      Critical) c=$((c + 1)) ;;
      Major) mj=$((mj + 1)) ;;
      Minor) mn=$((mn + 1)) ;;
    esac
  done <<< "$body"
  echo "$c $mj $mn"
}

# 純関数: pr-outcome の JSON 行を構築する。
# Args: pr verdict review_status critical major minor ts
io_pr_outcome_json() {
  jq -nc \
    --arg pr "${1:-}" --arg verdict "${2:-}" --arg status "${3:-}" \
    --argjson critical "${4:-0}" --argjson major "${5:-0}" --argjson minor "${6:-0}" \
    --arg ts "${7:-}" \
    '{kind:"pr-outcome", pr:($pr|tonumber?), verdict:$verdict, review_status:$status,
      critical:$critical, major:$major, minor:$minor, ts:$ts}'
}

# レビュー本文から status/counts を抽出し pr-outcome を outbox に記録する（オーケストレーション）。
# 変数 `status` は zsh の read-only 特殊変数（$? 相当）と衝突するため使わない（{ISSUE-ID} の教訓）。
# Args: sessions_dir pr verdict review_body ts
io_record_pr_outcome() {
  local sessions_dir="$1" pr="$2" verdict="$3" review_body="$4" ts="$5"
  local rstatus c mj mn
  rstatus="$(io_extract_review_status "$review_body")"
  read -r c mj mn <<< "$(io_count_review_severities "$review_body")"
  io_append "$sessions_dir" "$(io_pr_outcome_json "$pr" "$verdict" "$rstatus" "$c" "$mj" "$mn" "$ts")"
}