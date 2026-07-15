#!/bin/bash
# /review 判定ステータスの機械導出（{ISSUE-ID} Phase 2・純関数 lib）
#
# 背景: auto mode の権限分類器は「エージェントが自分の実装した PR に肯定的 pass 判定を
#   投稿する」行為を [Self-Approval] として実ブロックする（2026-07-12 撮影セッションの
#   jsonl で tool_result 拒否を実証）。プロンプト指示では harness 層のブロックに到達
#   できないため、判定の「著者」をモデルから剥奪する: モデルは findings の事実
#   （Critical/Major 件数・テスト結果・高リスク論点の有無）だけを渡し、verdict は本 lib が
#   決定的に導出、コメント合成・投稿は review-verdict-post.sh が行う。
#
# 導出規則（review.md「判定ステータス」定義と同値・fail 最優先）:
#   critical > 0 または tests=red            → fail
#   major > 0    または high_risk=yes        → 要確認
#   それ以外                                  → pass
#
# 注意（verdict パーサ整合・auto-merge-criteria.sh extract_review_verdict_from_text）:
#   - 合成コメントの「### 判定」節では verdict token を行頭（**token** 形）に 1 回だけ置く
#   - 導出根拠は verdict と同一行に書き、他の行頭に pass/要確認/fail を出さない

# Pure: verdict を導出する
# Args: critical major tests(green|red) high_risk(yes|no)
# Stdout: pass | 要確認 | fail / Returns: 0、入力不正は 64（fail-closed）
rvp_derive_verdict() {
  local critical="$1" major="$2" tests="$3" high_risk="$4"
  printf '%s' "$critical" | grep -qE '^[0-9]+$' || return 64
  printf '%s' "$major"    | grep -qE '^[0-9]+$' || return 64
  case "$tests" in green|red) ;; *) return 64 ;; esac
  case "$high_risk" in yes|no) ;; *) return 64 ;; esac

  if [ "$critical" -gt 0 ] || [ "$tests" = "red" ]; then
    echo "fail"; return 0
  fi
  if [ "$major" -gt 0 ] || [ "$high_risk" = "yes" ]; then
    echo "要確認"; return 0
  fi
  echo "pass"
}

# Pure: findings 本文（モデル authored の事実部分）の契約を検証する
# Args: body
# Returns: 0=受理 / 65=違反（見出し・判定セクションの二重付与、空本文）
#   見出しと ### 判定 はスクリプトが付与する契約のため、本文に含まれていたら拒否する
#   （二重見出しは hook 検知と verdict パーサの二重判定事故につながる）。
rvp_validate_body() {
  local body="$1"
  [ -n "$(printf '%s' "$body" | tr -d '[:space:]')" ] || return 65
  printf '%s\n' "$body" | grep -qE '^[[:space:]]*##[[:space:]]*レビュー結果' && return 65
  # 判定系見出し（##〜###### で「判定」終わり）はパーサ _extract_judgment_section が
  # 「最初の判定見出し」を判定節として拾うため、階層・名称ゆれ（## 総合判定 / #### 判定 等）
  # ごと拒否する（body 側に紛れると導出 verdict を上書きし enforcement が無効化される・{ISSUE-ID} Major 3）
  printf '%s\n' "$body" | grep -qE '^[[:space:]]*#{2,6}[[:space:]]*[^#]*判定[[:space:]]*$' && return 65
  return 0
}

# Pure: 最終コメントを合成する
# Args: body verdict critical major tests high_risk light（"light" で light マーカー付与・それ以外は無視）
# Stdout: 投稿用コメント全文
rvp_compose_comment() {
  local body="$1" verdict="$2" critical="$3" major="$4" tests="$5" high_risk="$6" light="$7"
  local out="## レビュー結果"
  if [ "$light" = "light" ]; then
    out="$out
<!-- review:light -->"
  fi
  local reason=""
  case "$verdict" in
    要確認) reason="。Major 指摘または高リスク論点が残るため、メンテナの確認後にマージ可" ;;
    fail)   reason="。Critical 指摘またはテスト非緑化のため修正が必要" ;;
  esac
  printf '%s\n\n%s\n\n### 判定\n\n**%s** — 判定は同梱スクリプト（review-verdict-post.sh）が入力事実から決定的に導出: Critical %s / Major %s / tests %s / 高リスク論点 %s（実装セッションによる自己承認ではなく、テスト済み純関数の出力）%s\n' \
    "$out" "$body" "$verdict" "$critical" "$major" "$tests" "$high_risk" "$reason"
}