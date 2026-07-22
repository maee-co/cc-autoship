#!/usr/bin/env bash
# lib/language-config.sh（言語設定の純関数・{ISSUE-ID} → {ISSUE-ID} で native 追随に再設計）のユニットテスト。
#
# 有効言語の SSoT は native Claude Code の言語設定（~/.claude/settings.json .language）。
# 優先順位は override（CC_AUTOSHIP_LANG・Codex/CI 用）> native（日本語→ja/非空→en）> ja。
# 表示文言（見出し・判定ラベル）と機械検知（マーカー）を分離する設計を検証する。
#
# native 参照先は CC_AUTOSHIP_NATIVE_SETTINGS で上書きし、実マシンの $HOME に依存しない
# 決定的テストにする。
#
# runner 規約: test-runner.sh が PASS/FAIL/ERRORS と assert_* / 色変数を注入して source する。
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT/claude-hooks/lib/language-config.sh"

# native 設定の fixture（JSON）を用意する
LC_FIXD=$(mktemp -d)
printf '%s\n' '{"language":"日本語"}'   > "$LC_FIXD/ja.json"
printf '%s\n' '{"language":"English"}'  > "$LC_FIXD/en.json"
printf '%s\n' '{"language":"Francais"}' > "$LC_FIXD/other.json"
printf '%s\n' '{"theme":"dark"}'        > "$LC_FIXD/nolang.json"
LC_MISSING="$LC_FIXD/does-not-exist.json"

echo "language-config: native 追随（override 無し・lc_current_lang）"
assert_eq "ja" "$(unset CC_AUTOSHIP_LANG; CC_AUTOSHIP_NATIVE_SETTINGS="$LC_FIXD/ja.json" lc_current_lang)"     "native=日本語 → ja"
assert_eq "en" "$(unset CC_AUTOSHIP_LANG; CC_AUTOSHIP_NATIVE_SETTINGS="$LC_FIXD/en.json" lc_current_lang)"     "native=English → en"
assert_eq "en" "$(unset CC_AUTOSHIP_LANG; CC_AUTOSHIP_NATIVE_SETTINGS="$LC_FIXD/other.json" lc_current_lang)"  "native=非日本語 → en"
assert_eq "ja" "$(unset CC_AUTOSHIP_LANG; CC_AUTOSHIP_NATIVE_SETTINGS="$LC_FIXD/nolang.json" lc_current_lang)" "native に .language 無し → ja"
assert_eq "ja" "$(unset CC_AUTOSHIP_LANG; CC_AUTOSHIP_NATIVE_SETTINGS="$LC_MISSING" lc_current_lang)"          "native ファイル欠落 → ja"

echo "language-config: override（CC_AUTOSHIP_LANG・Codex/CI 用・案B）が native に優先"
assert_eq "en" "$(CC_AUTOSHIP_LANG=en CC_AUTOSHIP_NATIVE_SETTINGS="$LC_FIXD/ja.json" lc_current_lang)" "override en は native=日本語 に優先"
assert_eq "ja" "$(CC_AUTOSHIP_LANG=ja CC_AUTOSHIP_NATIVE_SETTINGS="$LC_FIXD/en.json" lc_current_lang)" "override ja は native=English に優先"

echo "language-config: 未知・空・インジェクション様 override は無視して native/ja へ fall through"
assert_eq "ja" "$(CC_AUTOSHIP_LANG='' CC_AUTOSHIP_NATIVE_SETTINGS="$LC_MISSING" lc_current_lang)"                "空 override → fall through → ja"
assert_eq "en" "$(CC_AUTOSHIP_LANG=fr CC_AUTOSHIP_NATIVE_SETTINGS="$LC_FIXD/en.json" lc_current_lang)"           "未知 override → fall through → native(en)"
assert_eq "ja" "$(CC_AUTOSHIP_LANG='ja; rm -rf /' CC_AUTOSHIP_NATIVE_SETTINGS="$LC_MISSING" lc_current_lang)"    "インジェクション様 override → fall through → ja"

rm -rf "$LC_FIXD"

echo "language-config: 言語宣言文（lc_lang_declaration・SessionStart hook 用）"
assert_contains "English" "$(lc_lang_declaration en)" "en 宣言に English"
assert_contains "日本語"  "$(lc_lang_declaration ja)" "ja 宣言に 日本語"
assert_contains "日本語"  "$(lc_lang_declaration)"    "既定は ja 宣言"

echo "language-config: 表示専用の見出し・判定ラベル（機械検知はマーカーが担う）"
assert_eq "## Review Result" "$(lc_heading review en)" "見出し en"
assert_eq "## レビュー結果"   "$(lc_heading review ja)" "見出し ja"
assert_eq "needs-review" "$(lc_verdict_label 要確認 en)"       "判定ラベル 要確認→needs-review（en）"
assert_eq "要確認"       "$(lc_verdict_label 要確認 ja)"       "判定ラベル 要確認（ja）"
assert_eq "pass"         "$(lc_verdict_label pass en)"         "判定ラベル pass（en）"
assert_eq "needs-review" "$(lc_verdict_label needs-review en)" "判定ラベル needs-review（en・冪等）"