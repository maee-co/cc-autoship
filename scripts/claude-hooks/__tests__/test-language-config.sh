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

echo "language-config: auto-merge 判定コメントの文言（{ISSUE-ID} Phase 2a）"
assert_eq "## 🤖 /auto-merge verdict: ✅ Auto-mergeable"     "$(lc_am_heading ok en)" "am 見出し ok（en）"
assert_eq "## 🤖 /auto-merge 判定結果: ✅ 自動マージ可"       "$(lc_am_heading ok ja)" "am 見出し ok（ja・既存文言）"
assert_eq "## 🤖 /auto-merge verdict: ❌ Not auto-mergeable" "$(lc_am_heading ng en)" "am 見出し ng（en）"
assert_eq "## 🤖 /auto-merge 判定結果: ❌ 自動マージ不可"     "$(lc_am_heading ng ja)" "am 見出し ng（ja・既存文言）"
assert_eq "2. Scope (infra / single internal app)" "$(lc_am_condition scope en)" "am 条件ラベル（en）"
assert_eq "2. スコープ（infra / 単一内部アプリ）"    "$(lc_am_condition scope ja)" "am 条件ラベル（ja・既存文言）"
assert_eq "| Condition | Result |" "$(lc_am_condition table_header en)" "am 表ヘッダ（en）"
assert_eq "| 条件 | 結果 |"         "$(lc_am_condition table_header ja)" "am 表ヘッダ（ja・既存文言）"
assert_contains "Waiting for CI"           "$(lc_am_conclusion ok en)" "am 結論 ok（en）"
assert_eq "CI 完了を待って自動マージします。" "$(lc_am_conclusion ok ja)" "am 結論 ok（ja・既存文言）"
assert_contains "Manual merge"              "$(lc_am_conclusion ng en)" "am 結論 ng（en）"
assert_contains "メンテナの手動マージが必要です。" "$(lc_am_conclusion ng ja)" "am 結論 ng（ja・既存文言）"

echo "language-config: auto-merge の CI / マージ結果コメント（{ISSUE-ID} Phase 3）"
# 判定コメントだけが英語で、後続の CI / マージ結果が日本語のまま残っていた（v0.1.21 の
# リリース前 e2e で英語セッションを実測）。1 スレッドに 2 言語が混在するため lc_ に寄せる。
assert_contains "CI not configured"  "$(lc_am_step ci_skip en)"    "am CI 未設定（en）"
assert_contains "CI 未設定"           "$(lc_am_step ci_skip ja)"    "am CI 未設定（ja・既存文言）"
assert_contains "All checks passed"  "$(lc_am_step ci_pass en)"    "am CI 成功（en）"
assert_contains "全 check 成功"       "$(lc_am_step ci_pass ja)"    "am CI 成功（ja・既存文言）"
assert_contains "Failed / timed out" "$(lc_am_step ci_fail en)"    "am CI 失敗（en）"
assert_contains "失敗 / タイムアウト"  "$(lc_am_step ci_fail ja)"    "am CI 失敗（ja・既存文言）"
assert_contains "Merge failed"       "$(lc_am_step merge_fail en)" "am マージ失敗（en）"
assert_contains "マージ失敗"          "$(lc_am_step merge_fail ja)" "am マージ失敗（ja・既存文言）"
assert_contains "Merged"             "$(lc_am_step merge_ok en)"   "am マージ完了（en）"
assert_contains "マージ完了"          "$(lc_am_step merge_ok ja)"   "am マージ完了（ja・既存文言）"

# 見出しは全ステップで `## 🤖 /auto-merge ` 接頭辞を保つ（PR スレッド上の識別子）
for _k in ci_skip ci_pass ci_fail merge_fail merge_ok; do
  for _l in en ja; do
    assert_contains "## 🤖 /auto-merge " "$(lc_am_step "$_k" "$_l")" "am step 見出し接頭辞: $_k/$_l"
  done
done

# 可変部（CI 出力・マージ出力）は %s プレースホルダで受ける = 呼び出し側が printf で埋める。
# 埋め込み前に %s が残っていることを確認し、フォーマット崩れの回帰を防ぐ。
assert_contains "%s" "$(lc_am_step ci_fail en)"    "am CI 失敗は %s を持つ（en）"
assert_contains "%s" "$(lc_am_step ci_fail ja)"    "am CI 失敗は %s を持つ（ja）"
assert_contains "%s" "$(lc_am_step merge_fail en)" "am マージ失敗は %s を持つ（en）"
assert_contains "%s" "$(lc_am_step merge_fail ja)" "am マージ失敗は %s を持つ（ja）"
# 可変部を持たないステップに %s が紛れ込むと printf で欠落・誤展開する
for _k in ci_skip ci_pass merge_ok; do
  for _l in en ja; do
    case "$(lc_am_step "$_k" "$_l")" in
      *%s*) assert_eq "no-%s" "has-%s" "am step に不要な %s: $_k/$_l" ;;
      *)    assert_eq "ok" "ok" "am step に不要な %s なし: $_k/$_l" ;;
    esac
  done
done

# 未知キー / 言語省略時のフォールバック（呼び出し側が空コメントを投稿しないこと）
assert_contains "## 🤖 /auto-merge " "$(lc_am_step merge_ok)"  "am step は lang 省略で ja にフォールバック"
assert_eq ""                         "$(lc_am_step __unknown__ en)" "am step は未知キーで空を返す"

# --- zsh + set -u 下での source（{ISSUE-ID} 実測バグの回帰）---
# zsh には BASH_SOURCE が無い。set -u を敷いた親（auto-merge-criteria.sh）から source すると
# `${BASH_SOURCE[0]}` が unbound エラーになり **読み込みが途中で中断**して lc_* が未定義になる。
# hook は落ちず日本語へ無言フォールバックするだけなので、この回帰は出力を見ないと気付けない。
if command -v zsh >/dev/null 2>&1; then
  ZSH_SETU="$(zsh -c "set -u; source '$ROOT/claude-hooks/lib/language-config.sh'; declare -f lc_am_heading >/dev/null 2>&1 && echo DEFINED" 2>&1)"
  assert_contains "DEFINED" "$ZSH_SETU" "zsh + set -u でも lc_* が定義される（BASH_SOURCE unbound で中断しない）"
else
  echo "  - zsh 未インストールのため zsh + set -u 回帰テストはスキップ"
fi