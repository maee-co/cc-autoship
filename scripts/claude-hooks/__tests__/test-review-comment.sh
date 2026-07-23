#!/bin/bash
# lib/review-comment.sh の純関数テスト
# - rc_extract_body_file_path: --body-file / -F のパス抽出
# - rc_read_body_file: 絶対 / 相対(cwd→PWD) / tilde / stdin(-) の本文解決
# - rc_has_review_heading: レビュー結果見出しの検知（SSoT 正規表現）
# - rc_resolve_detection_text: コマンド文字列 + body-file 本文の結合

# shellcheck source=../lib/review-comment.sh
source "$HOOKS_DIR/lib/review-comment.sh"

# 一時作業ディレクトリ
RC_TMP=$(mktemp -d)
trap 'rm -rf "$RC_TMP"' EXIT

# ============================================================
# rc_extract_body_file_path
# ============================================================
echo "review-comment: rc_extract_body_file_path（パス抽出）"

PATH_OUT=$(rc_extract_body_file_path 'gh pr comment 42 --body-file /tmp/review.md')
assert_eq "/tmp/review.md" "$PATH_OUT" "--body-file <path> を抽出"

PATH_OUT=$(rc_extract_body_file_path 'gh pr comment 42 --body-file=/tmp/review.md')
assert_eq "/tmp/review.md" "$PATH_OUT" "--body-file=<path> を抽出"

PATH_OUT=$(rc_extract_body_file_path 'gh pr comment 42 -F /tmp/review.md')
assert_eq "/tmp/review.md" "$PATH_OUT" "-F <path>（短縮形）を抽出"

PATH_OUT=$(rc_extract_body_file_path 'gh pr comment 42 -F=/tmp/review.md')
assert_eq "/tmp/review.md" "$PATH_OUT" "-F=<path> を抽出"

PATH_OUT=$(rc_extract_body_file_path 'gh pr comment 42 --body-file "/tmp/my review.md"')
assert_eq "/tmp/my review.md" "$PATH_OUT" "ダブルクォート付きパスのクォートを除去"

PATH_OUT=$(rc_extract_body_file_path "gh pr comment 42 --body-file '/tmp/x.md'")
assert_eq "/tmp/x.md" "$PATH_OUT" "シングルクォート付きパスのクォートを除去"

# --body inline には body-file がない → 抽出失敗（return 1 / 空出力）
if rc_extract_body_file_path 'gh pr comment 42 --body "## レビュー結果"' >/dev/null; then
  assert_eq "fail" "ok" "--body inline では body-file 抽出が失敗すべき"
else
  assert_eq "fail" "fail" "--body inline では body-file 抽出が失敗（return 1）"
fi

# {ISSUE-ID} 二次レビュー Major 2: inline --body 本文中の "--body-file /x" 言及を実フラグと誤認しない
if rc_extract_body_file_path 'gh pr comment 42 --body "次は --body-file /etc/hosts を使ってください"' >/dev/null; then
  assert_eq "fail" "ok" "inline 本文中の --body-file 言及は抽出すべきでない"
else
  assert_eq "fail" "fail" "inline 本文中の --body-file 言及はクォート内なので抽出しない（任意ファイル読み取り防止）"
fi

# 同上（シングルクォートで囲まれた本文）
if rc_extract_body_file_path "gh pr comment 42 --body '参考: -F /etc/passwd の形式'" >/dev/null; then
  assert_eq "fail" "ok" "inline 本文中の -F 言及は抽出すべきでない"
else
  assert_eq "fail" "fail" "シングルクォート本文内の -F 言及も抽出しない"
fi

# ============================================================
# rc_read_body_file
# ============================================================
echo "review-comment: rc_read_body_file（本文解決）"

# 絶対パス
echo "## レビュー結果 (abs)" > "$RC_TMP/abs.md"
CONTENT=$(rc_read_body_file "$RC_TMP/abs.md")
assert_contains "## レビュー結果 (abs)" "$CONTENT" "絶対パスのファイル本文を読める"

# 相対パス（cwd 優先）
mkdir -p "$RC_TMP/sub"
echo "## レビュー結果 (cwd)" > "$RC_TMP/sub/rel.md"
CONTENT=$(rc_read_body_file "sub/rel.md" "$RC_TMP")
assert_contains "## レビュー結果 (cwd)" "$CONTENT" "相対パスを cwd 基準で解決して読める"

# 相対パス（cwd 解決不能 → PWD フォールバック）
echo "## レビュー結果 (pwd)" > "$RC_TMP/pwd-rel.md"
CONTENT=$(cd "$RC_TMP" && rc_read_body_file "pwd-rel.md" "/nonexistent-cwd-xyz")
assert_contains "## レビュー結果 (pwd)" "$CONTENT" "cwd 解決不能時は PWD でフォールバック"

# tilde 展開
TILDE_REL="rc-test-$$-tilde.md"
RC_HOME="$RC_TMP/home"
mkdir -p "$RC_HOME"
echo "## レビュー結果 (tilde)" > "$RC_HOME/$TILDE_REL"
CONTENT=$(HOME="$RC_HOME" rc_read_body_file "~/$TILDE_REL")
assert_contains "## レビュー結果 (tilde)" "$CONTENT" "~/ を \$HOME に展開して読める"
rm -f "$RC_HOME/$TILDE_REL"

# stdin マーカー（-）は読めないので失敗
if rc_read_body_file "-" >/dev/null 2>&1; then
  assert_eq "fail" "ok" "stdin マーカー(-) は読めず失敗すべき"
else
  assert_eq "fail" "fail" "stdin マーカー(-) は読めず失敗（return 1）"
fi

# 存在しないファイルは失敗
if rc_read_body_file "$RC_TMP/does-not-exist.md" >/dev/null 2>&1; then
  assert_eq "fail" "ok" "存在しないファイルは失敗すべき"
else
  assert_eq "fail" "fail" "存在しないファイルは失敗（return 1）"
fi

# ============================================================
# rc_has_review_heading
# ============================================================
echo "review-comment: rc_has_review_heading（見出し検知）"

if rc_has_review_heading "## レビュー結果
問題なし"; then
  assert_eq "ok" "ok" "## レビュー結果 を検知"
else
  assert_eq "ok" "fail" "## レビュー結果 を検知すべき"
fi

if rc_has_review_heading "## レビュー指摘修正結果"; then
  assert_eq "ok" "ok" "## レビュー指摘修正結果 を検知"
else
  assert_eq "ok" "fail" "## レビュー指摘修正結果 を検知すべき"
fi

if rc_has_review_heading "## 🤖 一次レビュー"; then
  assert_eq "ok" "ok" "## 🤖 一次レビュー（絵文字付き見出し）を検知"
else
  assert_eq "ok" "fail" "絵文字付き見出しを検知すべき"
fi

# rc_is_fix_result_heading: --fix（レビュー指摘修正結果）専用検知（#N 判断 1）
if rc_is_fix_result_heading "## レビュー指摘修正結果
| 1 | Minor | 90 | ..."; then assert_eq "ok" "ok" "## レビュー指摘修正結果 を --fix として検知"; else assert_eq "ok" "fail" "--fix 見出しを検知すべき"; fi
if rc_is_fix_result_heading "## 🤖 レビュー指摘修正結果"; then assert_eq "ok" "ok" "絵文字付き --fix 見出しも検知"; else assert_eq "ok" "fail" "絵文字付き --fix を検知すべき"; fi
if rc_is_fix_result_heading "## レビュー結果
判定: pass"; then assert_eq "ok" "fail" "通常レビューを --fix と誤検知してはいけない"; else assert_eq "ok" "ok" "## レビュー結果（通常）は --fix でない"; fi
if rc_is_fix_result_heading "## 🤖 一次レビュー"; then assert_eq "ok" "fail" "一次レビューを --fix と誤検知してはいけない"; else assert_eq "ok" "ok" "## 一次レビューは --fix でない"; fi

# 言語不変マーカー（{ISSUE-ID} Phase 3）: レビュー本文がセッション言語で書かれるようになったため、
# 英語セッションの --fix コメントは日本語見出しを持たない。見出し文字列に依存した検知のままだと
# 「--fix なのに通常レビュー扱い（= auto-merge を促す）」に無言で倒れる（#N と同型の連鎖事故）。
# 通常レビューの <!-- review-verdict: ... --> と対になるマーカーで、言語に依らず区別する。
if rc_is_fix_result_heading "## Review Fix Results
<!-- review-fix-result -->
| 1 | Minor | 90 | ..."; then assert_eq "ok" "ok" "英語 --fix をマーカーで検知"; else assert_eq "ok" "fail" "マーカー付き英語 --fix を検知すべき"; fi
if rc_is_fix_result_heading "<!--   review-fix-result   -->"; then assert_eq "ok" "ok" "マーカー内の空白ゆらぎを許容"; else assert_eq "ok" "fail" "空白ゆらぎを許容すべき"; fi
# マーカーが無い英語 --fix は検知できない（既知の制限。テンプレートがマーカーを必ず出す前提）
if rc_is_fix_result_heading "## Review Fix Results"; then assert_eq "ok" "fail" "マーカー無しの英語見出しは検知対象外"; else assert_eq "ok" "ok" "マーカー無し英語見出しは非検知（既知の制限）"; fi
# 通常レビューのマーカーを --fix と取り違えない（両者は排他）
if rc_is_fix_result_heading "## Review Result
<!-- review-verdict: pass -->"; then assert_eq "ok" "fail" "通常レビューのマーカーを --fix と誤検知してはいけない"; else assert_eq "ok" "ok" "review-verdict マーカーは --fix でない"; fi

# post-tool-use-auto-merge-after-review.sh は rc_has_review_heading を **前段ゲート**に使い、
# 一致しなければ即 exit 0 する。その後段でようやく rc_is_fix_result_heading の分岐に入る。
# 日本語の `## レビュー指摘修正結果` は RC_REVIEW_HEADING_PATTERN の `レビュー指摘修正結果` に
# 一致するため前段を通過できるが、英語見出し + マーカーだけだと前段で弾かれ、--fix 分岐に
# 到達しない = 再 /review リマインドが無言で出なくなる。前段でもマーカーを通すこと。
if rc_has_review_heading "## Review Fix Results
<!-- review-fix-result -->"; then assert_eq "ok" "ok" "英語 --fix も前段ゲート（rc_has_review_heading）を通過する"; else assert_eq "ok" "fail" "英語 --fix が前段ゲートで弾かれると再 /review リマインドが消える"; fi

# 見出しなし（本文中の言及）は検知しない
if rc_has_review_heading "レビュー結果について議論したいです"; then
  assert_eq "nodetect" "detect" "見出しなしの本文は検知しないべき"
else
  assert_eq "nodetect" "nodetect" "見出しなしの本文は検知しない（偽陽性防止）"
fi

# {ISSUE-ID} Phase B（spec ケース 15）: light 版レビューコメント（見出し不変 + マーカー）が検知される。
# 見出しを `## レビュー結果` のまま維持し、2 行目に `<!-- review:light -->` を置く設計が
# /auto-merge チェーンの見出し検知を壊さないことを固定する（#N/#N と同型のチェーン不発を防ぐ）。
LIGHT_REVIEW_COMMENT="## レビュー結果
<!-- review:light -->

**サマリ**: light レビュー完了。指摘なし。"
if rc_has_review_heading "$LIGHT_REVIEW_COMMENT"; then
  assert_eq "ok" "ok" "light 版コメント（## レビュー結果 + <!-- review:light -->）を検知（チェーン不発防止）"
else
  assert_eq "ok" "fail" "light 版コメントの見出しを検知すべき（マーカーが検知を壊さない）"
fi

# ============================================================
# rc_resolve_detection_text
# ============================================================
echo "review-comment: rc_resolve_detection_text（結合）"

# --body inline: コマンド文字列に見出しが含まれる → そのまま検知対象に
DETECT=$(rc_resolve_detection_text 'gh pr comment 42 --body "## レビュー結果\n問題なし"')
if rc_has_review_heading "$DETECT"; then
  assert_eq "ok" "ok" "--body inline の見出しを検知対象テキストに含む"
else
  assert_eq "ok" "fail" "--body inline の見出しを検知できるべき"
fi

# --body-file: コマンドにはパスしかないが、本文を読んで検知できる
echo "## レビュー結果
Critical 0 / Major 0" > "$RC_TMP/bodyfile.md"
DETECT=$(rc_resolve_detection_text "gh pr comment 42 --body-file $RC_TMP/bodyfile.md")
if rc_has_review_heading "$DETECT"; then
  assert_eq "ok" "ok" "--body-file の本文を読んで見出しを検知できる"
else
  assert_eq "ok" "fail" "--body-file の本文から見出しを検知すべき"
fi
# 検知対象は body-file 本文に限定される（コマンド文字列は混ぜない＝パス名誤検知防止）
assert_not_contains "gh pr comment" "$DETECT" "body-file 読込時の検知対象にコマンド文字列を混ぜない"

# --body-file（相対 + cwd）でも読める
echo "## レビュー結果 (rel)" > "$RC_TMP/sub/relbody.md"
DETECT=$(rc_resolve_detection_text "gh pr comment 7 --body-file sub/relbody.md" "$RC_TMP")
if rc_has_review_heading "$DETECT"; then
  assert_eq "ok" "ok" "--body-file 相対パス(cwd)でも本文を読んで検知"
else
  assert_eq "ok" "fail" "--body-file 相対パスで検知すべき"
fi

# body-file マーカー（codex 自己投稿）も検知対象テキストに乗る
echo "<!-- codex-secondary-review:PR#N -->
## レビュー結果" > "$RC_TMP/codex-self.md"
DETECT=$(rc_resolve_detection_text "gh pr comment 42 --body-file $RC_TMP/codex-self.md")
assert_contains "codex-secondary-review:" "$DETECT" "body-file 内の自己投稿マーカーも検知対象に乗る"

# {ISSUE-ID} 二次レビュー Major 1: パス名に見出し文字列が含まれても本文が見出しでなければ誤検知しない
mkdir -p "$RC_TMP/heading-name"
echo "ただのお礼コメントです" > "$RC_TMP/heading-name/## レビュー結果.md"
DETECT=$(rc_resolve_detection_text "gh pr comment 42 --body-file \"$RC_TMP/heading-name/## レビュー結果.md\"")
if rc_has_review_heading "$DETECT"; then
  assert_eq "nodetect" "detect" "パス名に見出し文字列が含まれても本文が見出しでなければ検知しないべき"
else
  assert_eq "nodetect" "nodetect" "パス名の見出し文字列では誤検知しない（検知対象は本文限定）"
fi

# {ISSUE-ID} 二次レビュー Major 2: inline 本文中の --body-file 言及で任意ファイルを読まない
echo "## レビュー結果（このファイルは読まれてはいけない）" > "$RC_TMP/should-not-read.md"
DETECT=$(rc_resolve_detection_text "gh pr comment 42 --body \"参照: --body-file $RC_TMP/should-not-read.md を使う\"")
assert_not_contains "読まれてはいけない" "$DETECT" "inline 本文中の --body-file 言及ではファイルを読まない"
assert_contains "gh pr comment 42" "$DETECT" "inline ケースの検知対象はコマンド文字列のまま"

# body-file が読めない場合はコマンド文字列にフォールバック（false negative 回避）
DETECT=$(rc_resolve_detection_text "gh pr comment 42 --body-file /nonexistent/zzz.md")
assert_contains "gh pr comment 42" "$DETECT" "読めない body-file ではコマンド文字列にフォールバック"
if rc_has_review_heading "$DETECT"; then
  assert_eq "nodetect" "detect" "読めない body-file では見出し検知しないべき"
else
  assert_eq "nodetect" "nodetect" "読めない body-file では見出し検知しない"
fi

# --- 言語不変マーカーで英語見出しも検知（#N の構造解決・{ISSUE-ID}）---
echo "review-comment: 言語不変判定マーカー検知（#N・{ISSUE-ID}）"
if rc_has_review_heading "## Review Result
<!-- review-verdict: pass -->
English review body"; then
  assert_eq "detect" "detect" "rc_has_review_heading: 英語見出し+マーカーを検知"
else
  assert_eq "detect" "nodetect" "rc_has_review_heading: 英語見出し+マーカーを検知（FAIL）"
fi
# マーカー無しの日本語見出しは従来どおり検知（後方互換）
if rc_has_review_heading "## レビュー結果
本文"; then
  assert_eq "detect" "detect" "rc_has_review_heading: 日本語見出しは従来どおり検知"
else
  assert_eq "detect" "nodetect" "rc_has_review_heading: 日本語見出し（FAIL）"
fi