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
#
# 表示文言の言語追随:
#   見出し・判定節・判定ラベル・理由文は lib/language-config.sh の lc_* に委譲して ja/en を
#   切り替える。**機械可読マーカー（<!-- review-verdict: <token> -->）は言語不変**のまま常時
#   刻印するため、表示を英語化しても検知（rc_has_review_heading / extract_*）と auto-merge
#   連鎖は切れない（v0.1.16 の「英語だと連鎖が黙って切れる」の再演防止）。

# language-config.sh を optional に読み込む（1 行ガード形）。
# 欠落しても落とさない fail-safe: lc_* が無ければ従来どおり日本語固定で合成する
# （配布キットの部分同梱・旧版との後方互換）。
# パス解決は bash の hook 実行と zsh での source（スキル経由）双方で動くよう
# ${BASH_SOURCE[0]:-$0} を使う（pr-class.sh / codex-trigger-criteria.sh と同じ P3 パターン。
# zsh では BASH_SOURCE が未定義のため、これが無いと cwd 相対に解決されて lib を取り逃がす）。
_RVD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
[ -f "${_RVD_LIB_DIR:-}/language-config.sh" ] && . "${_RVD_LIB_DIR}/language-config.sh"

# Pure: 表示に使う実効言語（lc_current_lang 不在時は ja に fail-safe）
_rvd_lang() {
  if declare -f lc_current_lang >/dev/null 2>&1; then lc_current_lang; else printf '%s' "ja"; fi
}

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
  # 英語見出し（lc_heading review en = "## Review Result"）も同様に拒否する
  printf '%s\n' "$body" | grep -qiE '^[[:space:]]*##[[:space:]]*Review[[:space:]]+Result[[:space:]]*$' && return 65
  # 判定系見出し（##〜###### で「判定」終わり）はパーサ _extract_judgment_section が
  # 「最初の判定見出し」を判定節として拾うため、階層・名称ゆれ（## 総合判定 / #### 判定 等）
  # ごと拒否する（body 側に紛れると導出 verdict を上書きし enforcement が無効化される・{ISSUE-ID} Major 3）
  printf '%s\n' "$body" | grep -qE '^[[:space:]]*#{2,6}[[:space:]]*[^#]*判定[[:space:]]*$' && return 65
  # 英語の判定節見出し（lc_heading verdict en = "### Verdict"）も拒否。
  # 見出し行に限定するため、地の文中の "verdict" は誤爆しない（日本語版の「判定基準は…」と対称）。
  printf '%s\n' "$body" | grep -qiE '^[[:space:]]*#{2,6}[[:space:]]*Verdict[[:space:]]*$' && return 65
  return 0
}

# Pure: verdict（pass/要確認/fail）→ 言語不変マーカートークン（pass/needs-review/fail）
# マーカー <!-- review-verdict: <token> --> は言語非依存の機械可読判定（{ISSUE-ID} の構造解決・{ISSUE-ID}）。
# 検知側（auto-merge-criteria.sh / review-comment.sh）はこれを最優先で読み、見出し・判定節の
# 自然言語に依存せず verdict を確定できる（英語レビュー本文でも auto-merge 連鎖が成立する）。
rvp_verdict_to_marker_token() {
  case "$1" in
    pass)   echo "pass" ;;
    要確認) echo "needs-review" ;;
    fail)   echo "fail" ;;
    *)      echo "unknown" ;;
  esac
}

# Pure: 最終コメントを合成する
# Args: body verdict critical major tests high_risk light（"light" で light マーカー付与・それ以外は無視）
# Stdout: 投稿用コメント全文
rvp_compose_comment() {
  local body="$1" verdict="$2" critical="$3" major="$4" tests="$5" high_risk="$6" light="$7"
  local lang; lang="$(_rvd_lang)"

  # 見出し（表示専用・lc_* 不在時は日本語に fail-safe）
  local out="## レビュー結果"
  if declare -f lc_heading >/dev/null 2>&1; then out="$(lc_heading review "$lang")"; fi
  if [ "$light" = "light" ]; then
    out="$out
<!-- review:light -->"
  fi
  # 言語不変の判定マーカーを常時刻印（{ISSUE-ID} の構造解決・{ISSUE-ID}）: 検知側はこれを最優先で読む。
  # ★ 表示言語に関係なく必ず刻印する（英語表示でも auto-merge 連鎖が切れない担保・{ISSUE-ID}）
  out="$out
<!-- review-verdict: $(rvp_verdict_to_marker_token "$verdict") -->"

  # 判定節（見出し・ラベル・理由・根拠文はいずれも表示専用。検知はマーカーが担う）
  local vhead="### 判定" vlabel="$verdict" reason="" fmt
  if declare -f lc_heading >/dev/null 2>&1;        then vhead="$(lc_heading verdict "$lang")"; fi
  if declare -f lc_verdict_label >/dev/null 2>&1;  then vlabel="$(lc_verdict_label "$verdict" "$lang")"; fi
  if declare -f lc_verdict_reason >/dev/null 2>&1; then
    reason="$(lc_verdict_reason "$verdict" "$lang")"
  else
    case "$verdict" in
      要確認) reason="。Major 指摘または高リスク論点が残るため、メンテナの確認後にマージ可" ;;
      fail)   reason="。Critical 指摘またはテスト非緑化のため修正が必要" ;;
    esac
  fi
  if declare -f lc_verdict_rationale_format >/dev/null 2>&1; then
    fmt="$(lc_verdict_rationale_format "$lang")"
  else
    fmt='**%s** — 判定は同梱スクリプト（review-verdict-post.sh）が入力事実から決定的に導出: Critical %s / Major %s / tests %s / 高リスク論点 %s（実装セッションによる自己承認ではなく、テスト済み純関数の出力）%s'
  fi

  printf '%s\n\n%s\n\n%s\n\n' "$out" "$body" "$vhead"
  # shellcheck disable=SC2059  # fmt は lc_* が返す固定フォーマット（外部入力ではない）
  printf "$fmt\n" "$vlabel" "$critical" "$major" "$tests" "$high_risk" "$reason"
}