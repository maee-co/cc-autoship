#!/usr/bin/env bash
# language-config.sh — 言語設定の純関数ライブラリ（{ISSUE-ID} → {ISSUE-ID} で native 追随に再設計）
#
# 有効言語（ja | en）の SSoT は **本家 Claude Code の言語設定**（~/.claude/settings.json の
# ".language"）に一本化する。Claude Code は起動時にこの値から「Always respond in <lang>」を
# system prompt に注入するため、モデルの応答/コミット/PR/レビュー言語はこの native 設定が
# 決定的に担う。cc-autoship は独自の言語値を持たず、native 設定に **追随** して bash 側の
# 表示文言（見出し・判定ラベル）だけを ja/en に切り替える。
#
# 優先順位（lc_current_lang）:
#   1. CC_AUTOSHIP_LANG（ja|en の明示 override）… native 設定が無い Codex/CI 用の逃げ道（案B）
#   2. ~/.claude/settings.json の .language … 日本語→ja / それ以外の非空→en（cc-autoship は ja/en のみ対応）
#   3. ja（fallback）… ファイル欠落・未設定・jq 不在は ja に fail-safe
#
# 設計（{ISSUE-ID} の構造解決・spec 2026-07-18-cc-autoship-language-config-design.md / {ISSUE-ID} で追随化）:
#   - 機械が読む判定は言語不変マーカー <!-- review-verdict: <token> --> が担う（Phase 0 で実装済み）。
#   - 本 lib の lc_heading / lc_verdict_label は **表示専用**の文言であり、検知には使わない。
#   - lc_lang_declaration は SessionStart hook が additionalContext に出す宣言文（native と一致するため競合しない）。
#
# 純関数ライブラリ。テストは scripts/claude-hooks/__tests__/test-language-config.sh。
#
# 公開関数:
#   - lc_current_lang                    : 有効言語（ja|en）。override > native > ja
#   - lc_lang_declaration <lang>         : SessionStart hook 用の有効言語宣言文
#   - lc_heading <kind> <lang>           : 表示専用の見出し文言（機械検知には使わない）
#   - lc_verdict_label <status> <lang>   : 表示専用の判定ラベル（機械検知はマーカーが担う）

# 直接実行した場合のみ strict mode を有効化する（source 時は親の設定を尊重）
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -uo pipefail
fi

# lc_current_lang: 有効言語（ja|en）を返す。優先順位は override > native > ja。
#   1. CC_AUTOSHIP_LANG が ja|en のときのみ override として採用（未知値・空は無視して次段へ）。
#   2. 本家 ~/.claude/settings.json の .language を ja/en にマップ（日本語→ja / 非空それ以外→en）。
#      参照先は CC_AUTOSHIP_NATIVE_SETTINGS で上書き可能（テスト容易性）。
#   3. いずれも解決できなければ ja（fail-safe）。
lc_current_lang() {
  # 1. 明示 override（Codex/CI 用・案B）
  case "${CC_AUTOSHIP_LANG:-}" in
    ja|en) printf '%s' "${CC_AUTOSHIP_LANG}"; return ;;
  esac

  # 2. 本家 Claude Code の言語設定に追随
  local native_file="${CC_AUTOSHIP_NATIVE_SETTINGS:-${HOME:-}/.claude/settings.json}"
  local native=""
  if [ -f "$native_file" ] && command -v jq >/dev/null 2>&1; then
    native="$(jq -r '.language // empty' "$native_file" 2>/dev/null || printf '')"
  fi

  # 3. マッピング（cc-autoship は ja/en のみ対応。日本語系→ja / それ以外の非空→en / 空→ja）
  case "$native" in
    ""|日本語|Japanese|japanese|ja|JA|jp|JP) printf '%s' "ja" ;;
    *)                                       printf '%s' "en" ;;
  esac
}

# lc_lang_declaration: SessionStart hook が additionalContext に出す有効言語の宣言文。
#   native の「Always respond in <lang>」と一致するため競合しない。commit/PR/review scope を明示する。
# 入力: $1 = lang（ja|en・省略時 ja）
lc_lang_declaration() {
  local lang="${1:-ja}"
  case "$lang" in
    en) printf '%s' "Language: en — respond, commit, and write issues / PRs / reviews in English." ;;
    *)  printf '%s' "言語: ja — 応答・コミット・Issue / PR・レビューはすべて日本語で行う。" ;;
  esac
}

# lc_heading: 表示専用の見出し文言（レビュー等）。
#   機械検知は言語不変マーカーが担うため、この文言は表示のためだけに使う（検知に依存させない）。
# 入力: $1 = kind（現状 review のみ）, $2 = lang（ja|en）
lc_heading() {
  local kind="${1:-review}" lang="${2:-ja}"
  case "${kind}:${lang}" in
    review:en) printf '%s' "## Review Result" ;;
    *)         printf '%s' "## レビュー結果" ;;
  esac
}

# lc_verdict_label: 表示専用の判定ラベル。
#   機械検知はマーカー（<!-- review-verdict: <token> -->）が担うため、これは表示専用。
#   ja/en 双方のトークン（要確認 / needs-review）を受け付け、指定言語のラベルに正規化する。
# 入力: $1 = status（pass|要確認|fail|needs-review）, $2 = lang（ja|en）
lc_verdict_label() {
  local status="${1:-}" lang="${2:-ja}"
  case "${status}:${lang}" in
    pass:en)                   printf '%s' "pass" ;;
    要確認:en|needs-review:en) printf '%s' "needs-review" ;;
    fail:en)                   printf '%s' "fail" ;;
    pass:*)                    printf '%s' "pass" ;;
    要確認:*|needs-review:*)   printf '%s' "要確認" ;;
    fail:*)                    printf '%s' "fail" ;;
    *)                         printf '%s' "$status" ;;
  esac
}