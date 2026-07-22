#!/bin/bash
# command-match.sh のテスト
# {ISSUE-ID}: gh pr <subcommand> 検知の純関数。引用符内・echo/grep 引数の誤発火を防ぐ。

LIB="$HOOKS_DIR/lib/command-match.sh"

# shellcheck source=../lib/command-match.sh
source "$LIB"

# --- ヘルパー ---
# is_gh_pr_*_command / _cm_has_gh_pr_subcommand の真偽値を 0/1 で返す
# 可変長引数: match_check <func> <arg1> [arg2 ...]
match_check() {
  local func="$1"
  shift
  if "$func" "$@"; then
    echo "0"
  else
    echo "1"
  fi
}

# --- is_gh_pr_create_command: 正の検知 ---
echo "command-match: gh pr create 正の検知"

assert_eq "0" "$(match_check is_gh_pr_create_command 'gh pr create')" \
  "シンプルな gh pr create"

assert_eq "0" "$(match_check is_gh_pr_create_command 'gh pr create --title test --body body')" \
  "引数付き gh pr create"

assert_eq "0" "$(match_check is_gh_pr_create_command '  gh pr create  ')" \
  "前後空白付き gh pr create"

assert_eq "0" "$(match_check is_gh_pr_create_command 'gh  pr  create')" \
  "ワード間複数空白"

assert_eq "0" "$(match_check is_gh_pr_create_command 'cd /foo && gh pr create')" \
  "cd && gh pr create（&& 区切り）"

assert_eq "0" "$(match_check is_gh_pr_create_command 'gh pr create; echo done')" \
  "gh pr create; echo done（; 区切り）"

assert_eq "0" "$(match_check is_gh_pr_create_command 'echo before; gh pr create')" \
  "前段に他コマンド（; 区切り）"

assert_eq "0" "$(match_check is_gh_pr_create_command 'gh pr create || exit 1')" \
  "|| 区切り後の継続"

# --- is_gh_pr_create_command: 引用符内の誤発火回避 ---
echo "command-match: gh pr create 誤発火回避（引用符内）"

assert_eq "1" "$(match_check is_gh_pr_create_command 'echo "gh pr create を呼ぶ前のチェック"')" \
  "echo \"gh pr create ...\" は誤検知しない"

assert_eq "1" "$(match_check is_gh_pr_create_command "echo 'gh pr create'")" \
  "echo 'gh pr create' は誤検知しない"

assert_eq "1" "$(match_check is_gh_pr_create_command 'grep "gh pr create" scripts/')" \
  "grep \"gh pr create\" は誤検知しない"

assert_eq "1" "$(match_check is_gh_pr_create_command 'cat README.md | grep "gh pr create"')" \
  "cat ... | grep \"gh pr create\" は誤検知しない"

assert_eq "1" "$(match_check is_gh_pr_create_command 'gh issue comment 123 --body "gh pr create を実行してください"')" \
  "gh issue comment の --body に gh pr create を含むケース"

assert_eq "1" "$(match_check is_gh_pr_create_command 'awk "/gh pr create/ { print }" file')" \
  "awk pattern 内の gh pr create"

# --- is_gh_pr_create_command: 似て非なるコマンドを除外 ---
echo "command-match: gh pr create 似て非なるコマンドを除外"

assert_eq "1" "$(match_check is_gh_pr_create_command 'gh pr list')" \
  "gh pr list は検知しない"

assert_eq "1" "$(match_check is_gh_pr_create_command 'gh pr view 123')" \
  "gh pr view は検知しない"

assert_eq "1" "$(match_check is_gh_pr_create_command 'gh issue create --title test')" \
  "gh issue create は検知しない（gh pr ではない）"

assert_eq "1" "$(match_check is_gh_pr_create_command 'gh pr created')" \
  "gh pr created（存在しない、create の接頭辞） は検知しない"

# --- is_gh_pr_create_command: 空入力 ---
echo "command-match: gh pr create 空入力"

assert_eq "1" "$(match_check is_gh_pr_create_command '')" \
  "空文字列は false"

# --- is_gh_pr_comment_command: 正の検知 ---
echo "command-match: gh pr comment 正の検知"

assert_eq "0" "$(match_check is_gh_pr_comment_command 'gh pr comment 42 --body test')" \
  "シンプルな gh pr comment"

assert_eq "0" "$(match_check is_gh_pr_comment_command 'cd /foo && gh pr comment 42 --body test')" \
  "cd && gh pr comment"

# --- is_gh_pr_comment_command: 誤発火回避 ---
echo "command-match: gh pr comment 誤発火回避"

assert_eq "1" "$(match_check is_gh_pr_comment_command 'echo "gh pr comment 42 ..."')" \
  "echo \"gh pr comment\" は誤検知しない"

assert_eq "1" "$(match_check is_gh_pr_comment_command 'grep "gh pr comment" hooks/')" \
  "grep \"gh pr comment\" は誤検知しない"

# メンテナ 観測の実例: 別 hook の調査時に発火した複数行コマンド
COMPLEX_CMD='echo "=== pre-tool-use.sh の gh pr create 検知 ==="
grep -n "gh.*pr.*create\|gh pr create" scripts/claude-hooks/pre-tool-use.sh'
assert_eq "1" "$(match_check is_gh_pr_create_command "$COMPLEX_CMD")" \
  "メンテナ 観測の実例（echo + grep の組み合わせ）は誤検知しない"

# --- is_gh_pr_merge_command: 正の検知 ---
echo "command-match: gh pr merge 正の検知"

assert_eq "0" "$(match_check is_gh_pr_merge_command 'gh pr merge 42 --squash')" \
  "gh pr merge --squash"

assert_eq "0" "$(match_check is_gh_pr_merge_command 'gh pr merge')" \
  "gh pr merge 単体"

# --- is_gh_pr_merge_command: 誤発火回避 ---
echo "command-match: gh pr merge 誤発火回避"

assert_eq "1" "$(match_check is_gh_pr_merge_command 'gh pr list')" \
  "gh pr list は merge と無関係"

assert_eq "1" "$(match_check is_gh_pr_merge_command 'echo "gh pr merge done"')" \
  "echo \"gh pr merge\" は誤検知しない"

# --- bash -c / sh -c ラップ形: 引数の中身は実行されるため検知する ---
# bash -c "gh pr create" は二重引用符の中身が「リテラル文字列」ではなく「実行されるコマンド」。
# _cm_strip_quoted が中身を文字列扱いで削除すると gh pr create を取りこぼす（#N で実測）。
echo "command-match: bash -c / sh -c ラップ形の検知"

assert_eq "0" "$(match_check is_gh_pr_create_command 'bash -c "gh pr create --title x"')" \
  'bash -c "gh pr create" は実行されるため検知する'

assert_eq "0" "$(match_check is_gh_pr_create_command "bash -c 'gh pr create'")" \
  "bash -c 'gh pr create'（シングルクォート）も検知する"

assert_eq "0" "$(match_check is_gh_pr_create_command 'sh -c "gh pr create"')" \
  'sh -c "gh pr create" も検知する'

assert_eq "0" "$(match_check is_gh_pr_create_command 'bash -lc "gh pr create"')" \
  'bash -lc（結合フラグ -lc）も検知する'

assert_eq "0" "$(match_check is_gh_pr_create_command 'bash -euo pipefail -c "gh pr create"')" \
  'bash -euo pipefail -c（-c より前にフラグ・引数あり）も検知する'

assert_eq "0" "$(match_check is_gh_pr_create_command '/bin/bash -c "gh pr create"')" \
  '/bin/bash -c（パス接頭辞付き）も検知する'

assert_eq "0" "$(match_check is_gh_pr_create_command 'cd /foo && bash -c "gh pr create"')" \
  'cd /foo && bash -c "gh pr create"（&& の後段のラップ）も検知する'

assert_eq "0" "$(match_check is_gh_pr_create_command 'bash -c "cd .claude/worktrees/x && gh pr create"')" \
  'bash -c "cd worktree && gh pr create"（ラップ内で cd してから create）も検知する'

# 内側の入れ子引用符（"..." の中に '...'）: 展開後にシングルクォートを剥がしても検知が残る
CREATE_NESTED_QUOTE=$'bash -c "gh pr create --title \'my title\'"'
assert_eq "0" "$(match_check is_gh_pr_create_command "$CREATE_NESTED_QUOTE")" \
  'bash -c "gh pr create --title \x27...\x27"（入れ子引用符）も検知する'

# --- bash -c ラップ形: 誤発火回避（過剰マッチさせない・{ISSUE-ID}） ---
# echo "bash -c '...'" のように、ラップ形そのものが別コマンドの引用符リテラルの中にある場合は
# 実行されないため検知してはいけない（bash -c を command position でのみ展開することで担保）。
echo "command-match: bash -c ラップ形の誤発火回避"

FALSE_ECHO_DQ=$'echo "bash -c \'gh pr create\'"'
assert_eq "1" "$(match_check is_gh_pr_create_command "$FALSE_ECHO_DQ")" \
  'echo "bash -c \x27gh pr create\x27"（echo の引用符内）は検知しない'

FALSE_ECHO_SQ=$'echo \'bash -c "gh pr create"\''
assert_eq "1" "$(match_check is_gh_pr_create_command "$FALSE_ECHO_SQ")" \
  "echo 'bash -c \"gh pr create\"'（echo の引用符内）は検知しない"

FALSE_GREP=$'grep "bash -c \'gh pr create\'" file'
assert_eq "1" "$(match_check is_gh_pr_create_command "$FALSE_GREP")" \
  'grep "bash -c \x27gh pr create\x27" file（grep 引数内）は検知しない'

assert_eq "1" "$(match_check is_gh_pr_create_command 'bash -c "gh pr list"')" \
  'bash -c "gh pr list"（ラップ内は list で create ではない）は検知しない'

assert_eq "1" "$(match_check is_gh_pr_create_command 'bash -c "gh issue create"')" \
  'bash -c "gh issue create"（gh pr ではない）は検知しない'

# --- bash -c ラップ形: comment / merge も共通の _cm_strip_quoted 経由で同時に修正される ---
echo "command-match: bash -c ラップ形は comment / merge にも波及"

assert_eq "0" "$(match_check is_gh_pr_comment_command 'bash -c "gh pr comment 42 --body x"')" \
  'bash -c "gh pr comment" も検知する'

FALSE_COMMENT=$'echo "bash -c \'gh pr comment\'"'
assert_eq "1" "$(match_check is_gh_pr_comment_command "$FALSE_COMMENT")" \
  'echo "bash -c \x27gh pr comment\x27" は検知しない'

assert_eq "0" "$(match_check is_gh_pr_merge_command 'bash -c "gh pr merge 42 --squash"')" \
  'bash -c "gh pr merge" も検知する'

FALSE_MERGE=$'echo "bash -c \'gh pr merge\'"'
assert_eq "1" "$(match_check is_gh_pr_merge_command "$FALSE_MERGE")" \
  'echo "bash -c \x27gh pr merge\x27" は検知しない'

# --- 接頭辞ラップ + quote 字句解析すり抜け（{ISSUE-ID} / #N）---
# #N で単純 bash -c ラップは塞いだが、_cm_unwrap_shell_c の素朴な sed "([^"]*)" では
#   (a) エスケープ引用符 \" を境界と誤認して -c 引数を途中で打ち切る
#   (b) command position 前置詞が wrapper（env / command / sudo ...）を許容しない
# の 2 系統がすり抜けた（Codex 二次レビュー実証・origin/main・bash 3.2.57）。
# _cm_unwrap_shell_c を bash 3.2 互換の字句解析ループに置換して両方塞ぐ。
echo "command-match: 接頭辞ラップ + エスケープ引用符の検知"

# (a) エスケープ引用符: -c 引数内の \" を跨いで gh pr create を検知する
P1_ESCAPED=$'bash -c "echo \\"before\\"; gh pr create"'
assert_eq "0" "$(match_check is_gh_pr_create_command "$P1_ESCAPED")" \
  'bash -c "echo \x5c"before\x5c"; gh pr create"（エスケープ引用符）も検知する'

# シングルクォート複合（#N 時点で既に検知・回帰ロック）
assert_eq "0" "$(match_check is_gh_pr_create_command "bash -c 'echo before; gh pr create'")" \
  "bash -c 'echo before; gh pr create'（シングルクォート複合）も検知する"

# (b) 接頭辞ラップ: env / command / sudo bash -c
assert_eq "0" "$(match_check is_gh_pr_create_command 'env FOO=1 bash -c "gh pr create"')" \
  'env FOO=1 bash -c "gh pr create"（env 接頭辞）も検知する'

assert_eq "0" "$(match_check is_gh_pr_create_command 'command bash -c "gh pr create"')" \
  'command bash -c "gh pr create"（command 接頭辞）も検知する'

assert_eq "0" "$(match_check is_gh_pr_create_command 'sudo bash -c "gh pr create"')" \
  'sudo bash -c "gh pr create"（sudo 接頭辞）も検知する'

assert_eq "0" "$(match_check is_gh_pr_create_command "env FOO=1 bash -c 'gh pr create'")" \
  "env FOO=1 bash -c 'gh pr create'（env 接頭辞・シングルクォート）も検知する"

# 接頭辞ラップは comment / merge にも波及（共通の _cm_unwrap_shell_c 経由）
assert_eq "0" "$(match_check is_gh_pr_comment_command 'env FOO=1 bash -c "gh pr comment 42 --body x"')" \
  'env FOO=1 bash -c "gh pr comment" も検知する'

assert_eq "0" "$(match_check is_gh_pr_merge_command 'command bash -c "gh pr merge 42 --squash"')" \
  'command bash -c "gh pr merge" も検知する'

# 裸の環境変数代入接頭辞（FOO=1 bash -c ...）も実シェルでは bash を実行する
assert_eq "0" "$(match_check is_gh_pr_create_command 'FOO=1 bash -c "gh pr create"')" \
  'FOO=1 bash -c "gh pr create"（裸代入接頭辞）も検知する'

assert_eq "0" "$(match_check is_gh_pr_create_command 'A=1 B=2 bash -c "gh pr create"')" \
  'A=1 B=2 bash -c "gh pr create"（複数の裸代入接頭辞）も検知する'

# --- {ISSUE-ID}: 過剰マッチ回避（リテラル・非 wrapper 接頭辞・内側エスケープ） ---
echo "command-match: 接頭辞ラップの誤発火回避"

# 内側のエスケープ引用符に閉じた gh pr create は実行されない（bash -c 'echo "gh pr create"' 相当）
N5_INNER=$'bash -c "echo \\"gh pr create\\""'
assert_eq "1" "$(match_check is_gh_pr_create_command "$N5_INNER")" \
  'bash -c "echo \x5c"gh pr create\x5c""（内側引用符に閉じ、実行されない）は検知しない'

# wrapper 接頭辞そのものが別コマンドの引用符リテラル内にある場合は展開しない
N3_ENV_LITERAL=$'echo "env bash -c \'gh pr create\'"'
assert_eq "1" "$(match_check is_gh_pr_create_command "$N3_ENV_LITERAL")" \
  'echo "env bash -c \x27gh pr create\x27"（echo 引用符内の env ラップ）は検知しない'

# 非 wrapper コマンド接頭辞（echo は引数を実行しない）は unwrap しない
assert_eq "1" "$(match_check is_gh_pr_create_command 'echo bash -c "gh pr create"')" \
  'echo bash -c "gh pr create"（echo は非 wrapper）は検知しない'

assert_eq "1" "$(match_check is_gh_pr_create_command 'echo FOO=1 bash -c "gh pr create"')" \
  'echo FOO=1 bash -c "gh pr create"（echo は非 wrapper）は検知しない'

# env で始まるが別コマンド（envsubst）は wrapper 扱いしない（語境界）
assert_eq "1" "$(match_check is_gh_pr_create_command 'envsubst bash -c "gh pr create"')" \
  'envsubst bash -c ...（env 接頭辞だが別コマンド）は wrapper 扱いしない'

# --- コマンド置換 / バッククォート（実際に実行されるため検知する: C-1 対応） ---
echo "command-match: コマンド置換は検知する（C-1 対応）"

# bash の $(...) と `...` はコマンド置換で中身が実行される。文字列リテラル扱いで
# 削除すると main ブロックを迂回できるため、検知対象として扱う。
assert_eq "0" "$(match_check is_gh_pr_create_command 'PR_URL=$(gh pr create --title test)')" \
  'PR_URL=$(gh pr create) は実際に実行されるため検知する'

assert_eq "0" "$(match_check is_gh_pr_create_command 'echo "$(gh pr create --title test)"')" \
  'echo "$(gh pr create)" は実際に実行されるため検知する'

assert_eq "0" "$(match_check is_gh_pr_create_command 'echo `gh pr create`')" \
  'バッククォート内の gh pr create は実際に実行されるため検知する'

# 似て非なるケース: コマンド置換内の gh issue create は対象外
assert_eq "1" "$(match_check is_gh_pr_create_command 'PR_URL=$(gh issue create --title test)')" \
  '$(gh issue create) は gh pr create ではない'

# --- 複数行コマンド ---
echo "command-match: 複数行コマンド"

MULTILINE_CMD='echo "before"
gh pr create --title test'
assert_eq "0" "$(match_check is_gh_pr_create_command "$MULTILINE_CMD")" \
  "複数行コマンドの2行目に独立して現れる gh pr create を検知"

# --- Known limitations: 仕様上の検知制限（将来の誤修正を防ぐためテストで契約化） ---
# 引用符・コマンド置換の sed パターンは単一行限定で、複数行をまたぐ引用符は未対応
# （#N 対応案 B 相当・未実装）。ヒアドキュメントは {ISSUE-ID} / #N で解消済み
# （下記「ヒアドキュメント本体の除去」セクション参照）。
# 実用上、複数行をまたぐ引用符で gh pr create を実行する正規ケースは存在しないため、
# 多少誤検知（=ブロック）してもユーザーへの害は小さい（ブロック時は worktree への
# 誘導メッセージが出るだけで、引用符を外せばブロックは解ける）。
echo "command-match: known limitations（複数行引用符）"

MULTILINE_QUOTED='echo "line1
gh pr create
line3"'
assert_eq "0" "$(match_check is_gh_pr_create_command "$MULTILINE_QUOTED")" \
  "複数行ダブルクォート内に閉じ込められた gh pr create は known limitation で検知（過剰反応）"

# --- ヒアドキュメント本体の除去（{ISSUE-ID} / #N） ---
# 実観測: PR #N レビュー中に「コミットメッセージ本文の <<EOF ヒアドキュメント内に
# 書いたコマンド例」が実行セグメントとして誤検知され、無関係な PR への auto-merge を
# hook が促した。ヒアドキュメント本体は bash が実行しないため、_cm_strip_heredoc_bodies
# で除去してから判定する（旧 known limitation はここで解消）。
echo "command-match: ヒアドキュメント本体の除去（{ISSUE-ID} / #N）"

HEREDOC_CMD='cat <<EOF
gh pr create
EOF'
assert_eq "1" "$(match_check is_gh_pr_create_command "$HEREDOC_CMD")" \
  "ヒアドキュメント本体内の gh pr create は実行セグメントとして扱わない（{ISSUE-ID} で解消）"

HEREDOC_QUOTED_CMD="cat <<'EOF'
gh pr create
EOF"
assert_eq "1" "$(match_check is_gh_pr_create_command "$HEREDOC_QUOTED_CMD")" \
  "引用符付きデリミタ（<<'EOF'）のヒアドキュメント本体も同様に検知しない"

HEREDOC_DQUOTED_CMD='cat <<"EOF"
gh pr create
EOF'
assert_eq "1" "$(match_check is_gh_pr_create_command "$HEREDOC_DQUOTED_CMD")" \
  'ダブルクォート付きデリミタ（<<"EOF"）のヒアドキュメント本体も同様に検知しない'

HEREDOC_BS_CMD='cat <<\EOF
gh pr create
EOF'
assert_eq "1" "$(match_check is_gh_pr_create_command "$HEREDOC_BS_CMD")" \
  'バックスラッシュ付きデリミタ（<<\EOF）のヒアドキュメント本体も同様に検知しない'

# 実行コマンド自体（ヒアドキュメント演算子を持つ行そのもの）は引き続き検知する
HEREDOC_REAL_COMMIT='git commit -F - <<EOF
docs(infra): レビュー投稿手順を追記

投稿は次のコマンドで行う:

gh pr comment 123 --body "## レビュー結果"
EOF'
assert_eq "1" "$(match_check is_gh_pr_comment_command "$HEREDOC_REAL_COMMIT")" \
  "#N 実証そのもの: git commit -F - のヒアドキュメント本体内の gh pr comment 例を誤検知しない"
assert_eq "0" "$(match_check is_git_commit_command "$HEREDOC_REAL_COMMIT")" \
  "同じコマンドの git commit -F - 自体（実行される本体）は引き続き検知する"

# ヒアストリング（<<<）はヒアドキュメントではないため対象外（従来どおり動作）
HERESTRING_CMD='wc -l <<< "gh pr create"'
assert_eq "1" "$(match_check is_gh_pr_create_command "$HERESTRING_CMD")" \
  "ヒアストリング（<<<）は引用符内の文字列としてそのまま扱われ検知しない（従来どおり）"

# unquoted ヒアドキュメント本体内の $(...) は実際に展開・実行されるため、引き続き検知する
# （ヒアドキュメント本体の地の文除去が、実行される $(...) まで消し去らないことの回帰防止）
HEREDOC_CMDSUB_CMD='cat <<EOF
before
$(gh pr create --title x)
after
EOF'
assert_eq "0" "$(match_check is_gh_pr_create_command "$HEREDOC_CMDSUB_CMD")" \
  "unquoted ヒアドキュメント本体内の \$(...) は実際に実行されるため検知する（見逃し防止）"

# 引用符付きデリミタのヒアドキュメントは完全に inert なので、内部の \$(...) も展開されない
HEREDOC_QUOTED_CMDSUB_CMD="cat <<'EOF'
before
"'$(gh pr create --title x)
after
EOF'
assert_eq "1" "$(match_check is_gh_pr_create_command "$HEREDOC_QUOTED_CMDSUB_CMD")" \
  "引用符付きデリミタのヒアドキュメント本体内は \$(...) も含めて完全に inert（展開されない）"

# is_git_push_delete_non_main_command 側でも同様にヒアドキュメント本体を検知しない
HEREDOC_PUSH_CMD='git commit -m "message" <<EOF
git push --delete origin feat/foo
EOF'
assert_eq "1" "$(match_check is_git_push_delete_non_main_command "$HEREDOC_PUSH_CMD")" \
  "is_git_push_delete_non_main_command もヒアドキュメント本体内の git push --delete を検知しない"

# is_review_verdict_post_command 側の実観測ケース（review-verdict-post.sh 手順の docstring）
HEREDOC_RVP_CMD='git commit -F - <<EOF
Add docs describing review-verdict-post.sh usage:

bash "$RVP" 123 --critical 0 --major 0 --tests pass
EOF'
assert_eq "1" "$(match_check is_review_verdict_post_command "$HEREDOC_RVP_CMD")" \
  "is_review_verdict_post_command もヒアドキュメント本体内の説明文を誤検知しない"

# main 保護（is_worktree_cd_bypass）側: ヒアドキュメント本体内の偽装 cd テキストが
# バイパスを誤って許可しないことを確認する（本 PR で判明した副次的なセキュリティ強化）
HEREDOC_FAKE_CD_CMD='cat <<EOF
cd .claude/worktrees/fake
EOF
git commit -m "malicious on main"'
assert_eq "1" "$(match_check is_worktree_cd_bypass "$HEREDOC_FAKE_CD_CMD")" \
  "ヒアドキュメント本体内の偽装 cd テキストは worktree バイパスの根拠にならない（main 保護強化）"

# 実際の worktree cd バイパスは引き続き許可される（回帰防止）
REAL_WORKTREE_CD_CMD='cd .claude/worktrees/foo && git commit -m "x"'
assert_eq "0" "$(match_check is_worktree_cd_bypass "$REAL_WORKTREE_CD_CMD")" \
  "実際の cd .claude/worktrees/ の後の git commit は引き続きバイパスを許可する（回帰防止）"

# 1 行に複数のヒアドキュメントが連なる場合も出現順に本体を消費する
HEREDOC_MULTI_CMD='cat <<A <<B
gh pr create
A
gh pr comment 1 --body x
B'
assert_eq "1" "$(match_check is_gh_pr_create_command "$HEREDOC_MULTI_CMD")" \
  "1 行に連なる複数ヒアドキュメント（1つ目）の本体内も検知しない"
assert_eq "1" "$(match_check is_gh_pr_comment_command "$HEREDOC_MULTI_CMD")" \
  "1 行に連なる複数ヒアドキュメント（2つ目）の本体内も検知しない"

# --- Codex 二次レビュー指摘（PR #N）: ヒアドキュメント演算子検出の過検知による
# --- fail-open 回帰の再発防止（3 件・すべて「実コマンドが誤って本体扱いで消えて
# --- 見逃される」class の回帰） ---
echo "command-match: ヒアドキュメント演算子検出の fail-open 回帰防止（Codex 二次レビュー）"

# 指摘1: ヒアストリング << < の 2 文字目を独立したヒアドキュメント演算子として
# 誤再検出し、後続の実コマンドを本体として飲み込んでいた（旧実装のみ再現）
HERESTRING_THEN_COMMIT='grep foo <<<"$data"
git commit -m "x"'
assert_eq "0" "$(match_check is_git_commit_command "$HERESTRING_THEN_COMMIT")" \
  "ヒアストリング（<<<）の直後の実 git commit を見逃さない（fail-open 回帰防止）"

# 指摘2: 算術展開 \$((1<<2)) の shift 演算子をヒアドキュメント演算子と誤認していた
ARITH_SHIFT_THEN_COMMIT='x=$((1<<2))
git commit -m "x"'
assert_eq "0" "$(match_check is_git_commit_command "$ARITH_SHIFT_THEN_COMMIT")" \
  "算術展開 \$((1<<2)) の直後の実 git commit を見逃さない（fail-open 回帰防止）"

ARITH_NESTED_THEN_COMMIT='x=$((a + (b<<c)))
git commit -m "x"'
assert_eq "0" "$(match_check is_git_commit_command "$ARITH_NESTED_THEN_COMMIT")" \
  "ネストした grouping 括弧を含む算術展開でも shift 演算子を誤認しない"

BARE_ARITH_THEN_COMMIT='((1<<2))
git commit -m "x"'
assert_eq "0" "$(match_check is_git_commit_command "$BARE_ARITH_THEN_COMMIT")" \
  "\$ なしの算術評価コマンド ((1<<2)) でも shift 演算子を誤認しない"

# 指摘3: 非 wordchar を含むデリミタ（EOF-X）を語の途中（EOF）で打ち切って
# 誤ったデリミタで終端行を探し続け、入力末尾まで本体として飲み込んでいた
NONWORD_DELIM_CMD='cat <<EOF-X
filler line
EOF-X
git commit -m "x"'
assert_eq "0" "$(match_check is_git_commit_command "$NONWORD_DELIM_CMD")" \
  "記号入りデリミタ（EOF-X）でも正しい終端行を認識し、後続の実 git commit を見逃さない"
assert_eq "1" "$(match_check is_gh_pr_create_command "$(cat <<'FIXTURE'
cat <<EOF-X
gh pr create
EOF-X
echo after
FIXTURE
)")" \
  "記号入りデリミタの本体内の gh pr create は正しく検知しない（過検知側も維持）"

# 回帰防止: << の直後に > が続く（同一行での追加リダイレクト）・空白なしで
# 複数ヒアドキュメントが連続する場合も従来どおり動作する
HEREDOC_REDIRECT_CMD='cat <<EOF >file
gh pr create
EOF
echo after'
assert_eq "1" "$(match_check is_gh_pr_create_command "$HEREDOC_REDIRECT_CMD")" \
  "ヒアドキュメント演算子の直後に > リダイレクトが続いても本体を正しく認識する"

ADJACENT_MULTI_HEREDOC_CMD='cat<<A<<B
x1
A
x2
B
git commit -m "x"'
assert_eq "0" "$(match_check is_git_commit_command "$ADJACENT_MULTI_HEREDOC_CMD")" \
  "空白なしで連続する複数ヒアドキュメント（cat<<A<<B）の後の実 git commit を見逃さない"

# --- サブコマンド allowlist（m-1 / ERE 注入対策） ---
# _cm_has_gh_pr_subcommand に直接 ERE メタ文字を渡しても任意マッチに展開されない
echo "command-match: サブコマンド allowlist（ERE 注入対策）"

assert_eq "1" "$(match_check _cm_has_gh_pr_subcommand 'gh pr create' '.*')" \
  "sub='.*' は allowlist 外で false（ERE 注入されない）"

assert_eq "1" "$(match_check _cm_has_gh_pr_subcommand 'gh pr create' 'create|merge')" \
  "sub='create|merge' は allowlist 外で false（OR メタ文字の悪用を弾く）"

assert_eq "1" "$(match_check _cm_has_gh_pr_subcommand 'gh pr create' 'foo')" \
  "sub='foo' は未知サブコマンドで false"

# allowlist 内の値は通常通り判定される
assert_eq "0" "$(match_check _cm_has_gh_pr_subcommand 'gh pr view 1' 'view')" \
  "sub='view' は allowlist 内で正常検知"

assert_eq "0" "$(match_check _cm_has_gh_pr_subcommand 'gh pr close 1' 'close')" \
  "sub='close' は allowlist 内で正常検知"

# --- resolve_target_branch: -C <path> の対象ブランチ解決（B-1 / {ISSUE-ID} P3）---
# 実 git の rev-parse 呼び出しは _cm_git_rev_parse_branch を関数差し替えで stub する。
# command-match.sh を source した後に同名関数を再定義すると、resolve_target_branch /
# cm_git_danger_targets_main の内部呼び出しも stub 経由になる（本番コードは不変）。
echo "command-match: resolve_target_branch（-C 対象ブランチ解決・rev-parse stub）"

_cm_git_rev_parse_branch() {
  local dir="$1"
  case "$dir" in
    *worktrees*) echo "feat/wt-dummy" ;;
    "") echo "feat/cwd-dummy" ;;
    *) echo "main" ;;
  esac
}

assert_eq "feat/wt-dummy" "$(resolve_target_branch 'git -C /repo/.claude/worktrees/feat-x commit -m x')" \
  "resolve_target_branch: -C worktree パスは worktree の実ブランチを返す"

assert_eq "main" "$(resolve_target_branch 'git -C /repo commit -m x')" \
  "resolve_target_branch: -C main リポジトリパスは main を返す"

assert_eq "feat/cwd-dummy" "$(resolve_target_branch 'git commit -m x')" \
  "resolve_target_branch: -C 無しは CWD の実ブランチを返す"

assert_eq "main" "$(resolve_target_branch 'git -C=/repo commit -m x')" \
  "resolve_target_branch: -C=<path> 形式（= 区切り）も抽出できる"

assert_eq "feat/wt-dummy" "$(resolve_target_branch 'git -C /repo/.claude/worktrees/feat-x push origin feat-x')" \
  "resolve_target_branch: push でも -C worktree パスを正しく解決する"

# --- cm_git_danger_targets_main: -C 対応の main/master 対象判定（穴の封鎖・B-1）---
echo "command-match: cm_git_danger_targets_main（main/master 対象判定・穴の封鎖）"

_cm_git_rev_parse_branch() {
  local dir="$1"
  case "$dir" in
    *worktrees*) echo "feat/dummy" ;;
    *) echo "main" ;;
  esac
}

assert_eq "0" "$(match_check cm_git_danger_targets_main 'git -C /repo commit -m x' 'commit')" \
  "git -C <main repo path> commit は main を対象と判定する（穴の封鎖の核心）"

assert_eq "1" "$(match_check cm_git_danger_targets_main 'git -C /repo/.claude/worktrees/feat-x commit -m x' 'commit')" \
  "git -C <worktree path> commit は main を対象と判定しない（worktree 誤ブロック解消）"

assert_eq "0" "$(match_check cm_git_danger_targets_main 'git commit -m x' 'commit')" \
  "-C 無し git commit は CWD（stub: main）を対象と判定する"

assert_eq "0" "$(match_check cm_git_danger_targets_main 'git -C /repo push origin main' 'push')" \
  "git -C <main repo path> push は main を対象と判定する"

assert_eq "1" "$(match_check cm_git_danger_targets_main 'git -C /repo/.claude/worktrees/feat-x push origin feat-x' 'push')" \
  "git -C <worktree path> push は main を対象と判定しない"

assert_eq "1" "$(match_check cm_git_danger_targets_main 'git status' 'commit')" \
  "commit/push を含まないコマンドは対象と判定しない"

assert_eq "1" "$(match_check cm_git_danger_targets_main '' 'commit')" \
  "空コマンドは対象と判定しない"

# 複合コマンド: セグメント単位で -C を独立解決する（worktree 側は素通し・main 側だけブロック対象）
assert_eq "0" "$(match_check cm_git_danger_targets_main 'git -C /repo/.claude/worktrees/feat-x status && git -C /repo commit -m x' 'commit')" \
  "複合コマンド: 後段セグメントの -C <main> commit を正しく検知する"

# --- Critical 回帰ガード: stacked -C（複数 -C の合成・実 git セマンティクス）---
# 実 git は `git -C a -C b` で「後段の -C（絶対パス）が前段を上書き / 相対パスは連結」する。
# 旧実装は (1) 危険コマンド判定アンカーの -C グループが `?`（0 or 1）で stacked -C を
# 「commit/push コマンド」と認識できず、(2) _cm_extract_dash_c_path が先頭 -C のみ抽出して
# いたため、`git -C <見せかけ worktree> -C <本物 main> commit` で見せかけ worktree を
# 先頭に置くと main への commit がブロックを迂回できた（Critical・{ISSUE-ID} P3 再レビュー）。
echo "command-match: cm_git_danger_targets_main stacked -C 合成（Critical・再レビュー）"

_cm_git_rev_parse_branch() {
  local dir="$1"
  case "$dir" in
    *worktrees*) echo "feat/wt-dummy" ;;
    "") echo "feat/cwd-dummy" ;;
    *) echo "main" ;;
  esac
}

# 見せかけ worktree を先頭に置いても、後段の絶対 -C が対象を main へ上書きするため検知する
assert_eq "0" "$(match_check cm_git_danger_targets_main 'git -C /repo/.claude/worktrees/feat-x -C /repo commit -m x' 'commit')" \
  "stacked -C: 見せかけ worktree の後の絶対 -C <main> commit を検知する（バイパス封鎖の核心）"

assert_eq "0" "$(match_check cm_git_danger_targets_main 'git -C /repo/.claude/worktrees/feat-x -C /repo push origin main' 'push')" \
  "stacked -C: push でも後段の絶対 -C <main> を検知する"

# 相対 -C の連結: 実 git 同様、前段の結果に連結される（worktree を指すため素通し）
assert_eq "1" "$(match_check cm_git_danger_targets_main 'git -C /repo/.claude/worktrees -C feat-x commit -m x' 'commit')" \
  "stacked -C: 相対パスは連結され worktree を指すため main と誤判定しない（過剰ブロック防止）"

# 最後が worktree を指すなら（main → worktree の順）通過する
assert_eq "1" "$(match_check cm_git_danger_targets_main 'git -C /repo -C /repo/.claude/worktrees/feat-x commit -m x' 'commit')" \
  "stacked -C: 後段の絶対 -C が worktree を指すなら（前段 main を上書き）通過する"

# --- Critical 回帰ガード: _cm_extract_dash_c_path の位置アンカー（B-1 修正レビュー指摘）---
# `git commit -C HEAD -m x`（--reuse-message の短縮形。--amend -C HEAD は一般操作）の
# `-C HEAD` はサブコマンド側フラグであり、対象 dir 変更ではない。旧実装はこれを
# 無条件にパスとして抽出し `git -C HEAD rev-parse` が失敗 → fail-open "unknown" →
# main 不一致 → main ブロックを迂回できる穴になっていた（旧実装 d919ff07 は
# ブロックしていたため退行）。
# stub: dir="" (CWD) → "main" / dir="HEAD"（旧実装が誤ってパスとして抽出した場合の
# 実 git 呼び出し失敗を模した "unknown"） / *worktrees* → worktree ブランチ。
# HEAD と "" を明確に区別できる stub にすることで、旧実装なら HEAD 誤抽出 → "unknown" →
# 未検知（Red）、新実装なら "" → CWD 実解決 → main 検知（Green）を判別できる。
echo "command-match: _cm_extract_dash_c_path / resolve_target_branch の位置アンカー（Critical・穴の再発防止）"

_cm_git_rev_parse_branch() {
  local dir="$1"
  case "$dir" in
    *worktrees*) echo "feat/wt-dummy" ;;
    "") echo "main" ;;
    HEAD) echo "unknown" ;;
    *) echo "main" ;;
  esac
}

assert_eq "main" "$(resolve_target_branch 'git commit -C HEAD -m x')" \
  "resolve_target_branch: サブコマンド側の -C HEAD はパス誤認せず CWD ブランチ（main）を返す（Critical）"

assert_eq "main" "$(resolve_target_branch 'git commit --amend -C HEAD')" \
  "resolve_target_branch: --amend -C HEAD も同様に CWD ブランチを返す（一般操作・誤ブロック防止）"

assert_eq "0" "$(match_check cm_git_danger_targets_main 'git commit -C HEAD -m x' 'commit')" \
  "cm_git_danger_targets_main: git commit -C HEAD -m x は CWD（stub: main）を対象と正しく判定する（穴の封鎖の核心。旧実装は HEAD をパス誤認し fail-open で未検知だった）"

# stacked -C の合成解決（実 git セマンティクス・Critical 再レビュー）
assert_eq "/repo" "$(_cm_extract_dash_c_path 'git -C /repo/.claude/worktrees/feat-x -C /repo commit -m x')" \
  "_cm_extract_dash_c_path: 後段の絶対 -C が前段を上書きする（stacked -C 合成）"

assert_eq "/repo/.claude/worktrees/feat-x" "$(_cm_extract_dash_c_path 'git -C /repo/.claude/worktrees -C feat-x commit -m x')" \
  "_cm_extract_dash_c_path: 相対 -C は前段の結果に連結される（実 git と同じ規則）"

assert_eq "main" "$(resolve_target_branch 'git -C /repo/.claude/worktrees/feat-x -C /repo commit -m x')" \
  "resolve_target_branch: stacked -C は最終ディレクトリ（main）を解決する（バイパス封鎖）"

# --- Important 回帰ガード: 引用符内の区切り/コマンドを誤検知しない（B-1 修正レビュー指摘）---
# `cm_git_danger_targets_main` が生の cmd を無条件にセグメント分割していたため、
# `git commit -m "not real; git push origin main"` の引用符内 `; git push` を
# 誤ってセグメント分割・検知していた。{ISSUE-ID} 統合後は
# 「クォート認識セグメント分割 → 実トークン化」の順で処理するため、
# 引用符内の区切り文字が独立セグメントとして現れない。
echo "command-match: cm_git_danger_targets_main 引用符内の誤検知回避（Important）"

assert_eq "1" "$(match_check cm_git_danger_targets_main 'git commit -m "not real; git push origin main"' 'push')" \
  "引用符内の '; git push origin main' はセグメント分割前に除去され push として誤検知しない（Important 回帰ガード）"

assert_eq "0" "$(match_check cm_git_danger_targets_main 'git commit -m "not real; git push origin main"' 'commit')" \
  "同コマンドは実際に main への git commit であるため commit 側では正しく検知する（引用符除去後も本体は残る）"

# --- {ISSUE-ID} 統合: cm_git_danger_targets_main も実トークン化パイプラインで判定する ---
# main 側の is_git_commit_command と同じ「bash -c 展開 + クォート認識分割 +
# 実トークン化」を cm_git_danger_targets_main が内部で使うことの検証（マージ統合時に追加）。
# 引用符分割サブコマンド・bash -c ラップのどちらも -C 解決付き判定に到達する。
echo "command-match: cm_git_danger_targets_main の {ISSUE-ID} 統合（引用符分割・bash -c）"

assert_eq "0" "$(match_check cm_git_danger_targets_main 'git "commit" -m x' 'commit')" \
  "{ISSUE-ID} 統合: git \"commit\"（引用符分割サブコマンド）もトークン化で復元して CWD（stub: main）を検知する"

assert_eq "0" "$(match_check cm_git_danger_targets_main 'git p"u"sh origin main' 'push')" \
  "{ISSUE-ID} 統合: git p\"u\"sh（語の途中で分割）も push として検知する"

assert_eq "0" "$(match_check cm_git_danger_targets_main 'bash -c "git commit -m x"' 'commit')" \
  "{ISSUE-ID} 統合: bash -c \"git commit\" ラップも展開して CWD（stub: main）を検知する"

assert_eq "1" "$(match_check cm_git_danger_targets_main 'echo "git commit -m done"' 'commit')" \
  "{ISSUE-ID} 統合: echo の引数値としての git commit は誤検知しない"

# --- Minor 回帰ガード: -C 指定ありで実ブランチ解決不能なら fail-closed（B-1 修正レビュー指摘）---
echo "command-match: cm_git_danger_targets_main の -C 解決不能時 fail-closed（Minor）"

_cm_git_rev_parse_branch() {
  local dir="$1"
  case "$dir" in
    *worktrees*) echo "feat/dummy" ;;
    *nonexistent*) echo "unknown" ;;
    *) echo "main" ;;
  esac
}

assert_eq "0" "$(match_check cm_git_danger_targets_main 'git -C /nonexistent/path commit -m x' 'commit')" \
  "-C 指定ありで実ブランチ解決不能（unknown）は fail-closed でブロック側に倒す（Minor）"

# --- is_worktree_cd_bypass: danger_re デフォルトが -C 形式も検知する（C-3 の -C 版）---
echo "command-match: is_worktree_cd_bypass danger_re デフォルトの -C 拡張"

assert_eq "1" "$(match_check is_worktree_cd_bypass 'git -C /repo commit -m x ; cd .claude/worktrees/foo')" \
  "C-3 の -C 版: -C commit が先にあれば cd が後にあってもバイパス不可（danger_re 拡張）"

assert_eq "0" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && git -C /repo/.claude/worktrees/foo commit -m x')" \
  "cd が先にあれば -C 形式の commit があってもバイパス可（正当な worktree 遷移）"

# --- C-6 回帰ガード: worktree へ cd した後の -C <main> 上書き（Critical・再レビュー）---
# `cd .claude/worktrees/foo && git -C /repo commit` は cd で ambient cwd が worktree に
# なるが、後段の `-C /repo` がそのコマンド単体の対象を main へ上書きする。旧実装は
# 「cd worktree が先にある」だけで残り全セグメントをバイパス扱いにしていたため、
# cd の後に -C <main> を置くと main への commit が通っていた（C-6・{ISSUE-ID} P3 再レビュー）。
echo "command-match: is_worktree_cd_bypass C-6（cd worktree 後の -C main 上書き封鎖）"

assert_eq "1" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && git -C /repo commit -m x')" \
  "C-6: cd worktree の後でも -C <main> commit はバイパス不可（対象が main へ上書きされる）"

assert_eq "1" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && git -C /repo push origin main')" \
  "C-6: cd worktree の後の -C <main> push もバイパス不可"

# 正当ケース: cd worktree 後の -C 無し commit / -C worktree commit は引き続きバイパス可
assert_eq "0" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && git commit -m x && git push')" \
  "C-6 正当ケース: cd worktree 後の -C 無し commit/push は引き続きバイパス可（過剰ブロック防止）"

# --- C-8: bash -c ラップ内の正当な worktree cd（#N・P6 クリーンラン レポート 2）---
# `bash -c '<script>'` は <script> が実行本体なのに、引用符除去で cd セグメントが
# 不可視になり正当な worktree コミットが誤ブロックされていた。全体が単一の
# bash|sh|zsh -c 呼び出しかつ単純クォートの場合に限り 1 段 unwrap して再帰判定する。
echo "command-match: is_worktree_cd_bypass C-8（bash -c ラップの unwrap・#N）"

assert_eq "0" "$(match_check is_worktree_cd_bypass "bash -c 'cd .claude/worktrees/x && git commit -m x'")" \
  "C-8: bash -c 単一ラップ内の cd worktree && commit はバイパス可"

assert_eq "0" "$(match_check is_worktree_cd_bypass 'sh -c "cd .claude/worktrees/x && git push origin feat/x"')" \
  "C-8: sh -c 二重引用符ラップも同様にバイパス可"

assert_eq "0" "$(match_check is_worktree_cd_bypass "bash -lc 'cd .claude/worktrees/x && git commit -m x'")" \
  "C-8: -lc 形式（オプション結合）も unwrap する"

assert_eq "1" "$(match_check is_worktree_cd_bypass "bash -c 'git commit -m x'")" \
  "C-8 防御: ラップ内に cd worktree が無ければ従来どおりブロック"

assert_eq "1" "$(match_check is_worktree_cd_bypass "bash -c 'echo \"cd .claude/worktrees/x\" && git commit -m x'")" \
  "C-8 防御: 内側の C-1（引用符内 cd 偽装）は再帰判定で引き続きブロック"

assert_eq "1" "$(match_check is_worktree_cd_bypass "echo \"bash -c 'cd .claude/worktrees/x'\" && git commit -m x")" \
  "C-8 防御: 外側が echo（bash -c が引用符内の文字列）は unwrap しない"

assert_eq "1" "$(match_check is_worktree_cd_bypass "bash -c 'cd .claude/worktrees/x && git commit -m x' && git push origin main")" \
  "C-8 防御: 閉じクォート後に別コマンドが続く場合は unwrap せず保守的にブロック"

assert_eq "1" "$(match_check is_worktree_cd_bypass "bash -c 'cd .claude/worktrees/x && git -C /repo commit -m x'")" \
  "C-8 防御: 内側の C-6（-C main 上書き）も再帰判定で引き続きブロック"

# --- C-9: cd パストラバーサルが worktree ホワイトリストを素通りする穴の封鎖（#N） ---
# `cd .claude/worktrees/../../..` は `.claude/worktrees/` を含むが、末尾の `..` で
# worktree の外（main checkout 等）へ抜けるため、後続の commit は main で実行される。
# `..` パスセグメントを含む cd は worktree 遷移と認めず、保守的にブロック側へ倒す。
echo "command-match: is_worktree_cd_bypass C-9（cd パストラバーサル封鎖・#N）"

assert_eq "1" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/../../.. && git commit -m x')" \
  "C-9: .claude/worktrees/ 後の ../../.. で外へ抜ける cd はバイパス不可"

assert_eq "1" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo/../../.. && git push origin main')" \
  "C-9: worktree 名の後に ../../.. が続くトラバーサルもバイパス不可"

assert_eq "1" "$(match_check is_worktree_cd_bypass 'cd /repo/.claude/worktrees/x/../../../.. && git commit -m x')" \
  "C-9: 絶対パス + トラバーサルもバイパス不可"

assert_eq "1" "$(match_check is_worktree_cd_bypass "bash -c 'cd .claude/worktrees/../../.. && git commit -m x'")" \
  "C-9 防御: bash -c ラップ内のトラバーサルも再帰判定でブロック"

assert_eq "0" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && git commit -m x')" \
  "C-9 回帰: .. を含まない素直な worktree cd は従来どおりバイパス可"

assert_eq "0" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/feat/{ISSUE-ID}-x && git push origin feat/x')" \
  "C-9 回帰: 深い階層の素直な worktree パスもバイパス可"

# --- C-9b: worktree 遷移後に外へ出る cd/pushd を前置バイパスとして封鎖（#N Critical・敵対レビュー） ---
# found_worktree_cd=1 が立った後でも、後続の cd/pushd で worktrees の外（main checkout 等）へ
# 出れば、そこで実行される git commit/push は main に効く。正当な worktree cd を 1 つ前置して
# C-9 の単一セグメント判定を迂回する攻撃（`cd wt && cd ../../.. && git commit`）を封鎖する。
echo "command-match: is_worktree_cd_bypass C-9b（worktree 遷移後の外抜け cd 封鎖・#N）"

assert_eq "1" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && cd .claude/worktrees/../../.. && git commit -m x')" \
  "C-9b: 正当 worktree cd を前置しても、後続の .. 外抜け cd はバイパス不可"

assert_eq "1" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && cd .. && git commit -m x')" \
  "C-9b: worktree 後の cd .. はバイパス不可"

assert_eq "1" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && cd /tmp/main && git commit -m x')" \
  "C-9b: worktree 後の絶対パス cd（worktrees 外）はバイパス不可"

assert_eq "1" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo ; cd ~ ; git commit -m x')" \
  "C-9b: worktree 後の cd ~ はバイパス不可"

assert_eq "1" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && cd - && git commit -m x')" \
  "C-9b: worktree 後の cd - はバイパス不可"

assert_eq "1" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && pushd /tmp && git commit -m x')" \
  "C-9b: worktree 後の pushd はバイパス不可"

assert_eq "1" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && popd && git commit -m x')" \
  "C-9b: worktree 後の popd はバイパス不可"

# 回帰: worktree 配下に留まる移動は維持（過剰ブロック防止）
assert_eq "0" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && cd src && git commit -m x')" \
  "C-9b 回帰: worktree 内の相対 cd（.. なし）は維持されバイパス可"

assert_eq "0" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && cd ./src/lib && git commit -m x')" \
  "C-9b 回帰: worktree 内の ./ 相対 cd もバイパス可"

assert_eq "0" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && cd .claude/worktrees/bar && git commit -m x')" \
  "C-9b 回帰: 別 worktree への cd（.. なし）はバイパス可"

# --- C-9c: 変数展開 cd による前置バイパスの封鎖（#N Critical・敵対レビュー2巡目） ---
# `cd $HOME` 等の変数展開は任意ディレクトリ（worktrees 外）へ展開されうるため、worktrees
# 配下に留まる静的保証がない。found 後の変数 cd も、変数を含む worktrees パスの初期検出も、
# 安全側でブロックへ倒す（`$(...)` は _cm_strip_for_bypass で既に除去済み・別経路）。
echo "command-match: is_worktree_cd_bypass C-9c（変数展開 cd の前置バイパス封鎖・#N）"

assert_eq "1" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && cd $HOME && git commit -m x')" \
  "C-9c: worktree 後の cd \$HOME はバイパス不可"

assert_eq "1" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && cd $HOME/repo && git commit -m x')" \
  "C-9c: worktree 後の cd \$HOME/repo はバイパス不可"

assert_eq "1" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && d=/main && cd $d && git commit -m x')" \
  "C-9c: 変数代入 + cd \$d の外抜けはバイパス不可"

assert_eq "1" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && cd "${MAIN}" && git push origin main')" \
  "C-9c: worktree 後の cd \${MAIN} はバイパス不可"

assert_eq "1" "$(match_check is_worktree_cd_bypass 'cd $HOME/.claude/worktrees/x && git commit -m x')" \
  "C-9c: 変数を含む worktrees パスの初期検出も安全側でブロック"

assert_eq "0" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && cd src/lib && git commit -m x')" \
  "C-9c 回帰: 変数を含まない worktree 内相対 cd は従来どおりバイパス可"

# --- C-9d: プレフィックス付き cd による前置バイパスの封鎖（#N Critical・敵対レビュー3巡目） ---
# `command cd` / `builtin cd` / `\cd` / `X= cd` / `eval "cd .."` は cd を実行して worktrees の
# 外へ出るが、セグメント先頭が literal cd でないため肯定列挙の escape 検出をすり抜けていた。
# found 後は「worktree 内滞在を保証できる素直な cd 以外の cwd 変更」を保守デフォルトで降ろす。
echo "command-match: is_worktree_cd_bypass C-9d（プレフィックス付き cd の前置バイパス封鎖・#N）"

assert_eq "1" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && command cd .. && git commit -m x')" \
  "C-9d: worktree 後の command cd .. はバイパス不可"

assert_eq "1" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && builtin cd .. && git commit -m x')" \
  "C-9d: worktree 後の builtin cd .. はバイパス不可"

assert_eq "1" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && \cd .. && git commit -m x')" \
  "C-9d: worktree 後の バックスラッシュ cd .. はバイパス不可"

assert_eq "1" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && X= cd .. && git commit -m x')" \
  "C-9d: worktree 後の 代入プレフィックス cd .. はバイパス不可"

assert_eq "1" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && eval "cd .." && git commit -m x')" \
  "C-9d: worktree 後の eval cd .. はバイパス不可"

assert_eq "1" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && command cd $HOME && git commit -m x')" \
  "C-9d: プレフィックス + 変数展開の複合もバイパス不可"

# 回帰: cwd を変えない無害なコマンドは found 維持（過剰ブロック防止）
assert_eq "0" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && echo done && git commit -m x')" \
  "C-9d 回帰: worktree 後の echo（cwd 不変）は維持されバイパス可"

assert_eq "0" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && git status && git commit -m x')" \
  "C-9d 回帰: worktree 後の git status（cwd 不変）も維持されバイパス可"

assert_eq "0" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && cd src && git commit -m x')" \
  "C-9d 回帰: worktree 内の素直な cd は維持されバイパス可"

# --- C-9e: 過剰ブロック誤爆の解消（引数の cd 系トークンで誤ブロックしない・#N 敵対4巡目 Major） ---
# _cm_seg_may_change_cwd をコマンド位置限定にし、無害コマンドの引数に cd/eval/exec/source/. が
# 含まれても found を降ろさない（grep cd / rg exec / git add . 等の頻出コマンドの誤ブロック解消）。
# プレフィックス経由の cd 実行（command/env cd）検出は維持する。
echo "command-match: is_worktree_cd_bypass C-9e（引数の cd 系トークンで誤ブロックしない・#N）"

assert_eq "0" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && echo "starting cd now" && git commit -m x')" \
  "C-9e: echo の引数に cd を含んでも維持されバイパス可"

assert_eq "0" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && grep -rn cd src && git commit -m x')" \
  "C-9e: grep -rn cd の引数 cd で誤ブロックしない"

assert_eq "0" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && rg eval && git commit -m x')" \
  "C-9e: rg eval の引数 eval で誤ブロックしない"

assert_eq "0" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && git add . -v && git commit -m x')" \
  "C-9e: git add . -v の単独ドットで誤ブロックしない"

assert_eq "0" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && git add . && git commit -m x')" \
  "C-9e: git add .（超頻出）で誤ブロックしない"

# プレフィックス検出は維持（C-9d 相当が引き続きブロック）
assert_eq "1" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && command cd .. && git commit -m x')" \
  "C-9e 維持: command cd .. は引き続きバイパス不可（コマンド位置の cd 検出は残る）"

assert_eq "1" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && env cd .. && git commit -m x')" \
  "C-9e 維持: env cd .. も引き続きバイパス不可"

# --- C-9f: Codex 二次レビュー検出のバイパス封鎖（代入値の / 判定漏れ・CDPATH・#N） ---
# Codex 二次レビューが敵対4巡をすり抜けた 2 経路を検出（bash 実測で rc=0 再現済み）:
#   (1) 代入プレフィックスの値に `/` を含むと（X=/tmp cd ..）代入判定 `!= */*` で除外され
#       第 1 実コマンドの cd を見逃す → 代入判定を identifier= の正規表現に修正
#   (2) CDPATH 設定時に裸相対 cd（cd core）が worktrees 外（CDPATH 配下）へ移動しうる →
#       CDPATH 設定セグメントを cwd 変更扱いにして found を降ろす
echo "command-match: is_worktree_cd_bypass C-9f（代入値の / と CDPATH バイパス封鎖・Codex #N）"

assert_eq "1" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && X=/tmp cd ../../.. && git commit -m x')" \
  "C-9f: X=/tmp cd ..（代入値に / 含む）はバイパス不可"

assert_eq "1" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && X=/tmp command cd ../../.. && git commit -m x')" \
  "C-9f: X=/tmp command cd .. もバイパス不可"

assert_eq "1" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && CDPATH=/Users/dev/Works && cd core && git commit -m x')" \
  "C-9f: CDPATH=/x && cd core（裸相対が CDPATH で外へ）はバイパス不可"

assert_eq "1" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && export CDPATH=/tmp && cd core && git commit -m x')" \
  "C-9f: export CDPATH + cd core もバイパス不可"

assert_eq "1" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && CDPATH=/tmp cd core && git commit -m x')" \
  "C-9f: CDPATH=/tmp cd core（同セグメント）もバイパス不可"

assert_eq "0" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && git add . && git commit -m x')" \
  "C-9f 回帰: git add . は引き続き誤ブロックしない"

# --- gh_pr_create_head_branch: --head 値の抽出（B-2 / {ISSUE-ID} P3）---
# `gh pr create --head <branch>` があれば pre-tool-use-gh-pr-create.sh がその値で
# main/master 判定できるよう、--head の値を抽出する純関数。
echo "command-match: gh_pr_create_head_branch（--head 値の抽出）"

assert_eq "feat/x" "$(gh_pr_create_head_branch 'gh pr create --head feat/x --base main -R owner/repo')" \
  "スペース区切り --head <val> を抽出する"

assert_eq "feat/x" "$(gh_pr_create_head_branch 'gh pr create --head=feat/x --base main -R owner/repo')" \
  "= 区切り --head=<val> も抽出する"

assert_eq "main" "$(gh_pr_create_head_branch 'gh pr create --head main --base main')" \
  "--head main（誤用値）もそのまま抽出する（main/master 判定は呼び出し側の責務）"

assert_eq "" "$(gh_pr_create_head_branch 'gh pr create --title t --body b')" \
  "--head が無ければ空文字を返す"

assert_eq "" "$(gh_pr_create_head_branch '')" \
  "空コマンドは空文字を返す"

assert_eq "" "$(gh_pr_create_head_branch 'gh pr list --head feat/x')" \
  "gh pr create 以外のサブコマンドの --head は拾わない（gh pr create セグメント限定）"

assert_eq "" "$(gh_pr_create_head_branch 'gh pr create --title "--head feat/x" --body b')" \
  "引用符内の偽装 --head は本物として抽出しない（quote-aware トークナイザで 1 トークンにまとまる・誤爆防止）"

assert_eq "" "$(gh_pr_create_head_branch 'echo "--head foo" && gh pr create --title t')" \
  "無関係なセグメントに現れる --head は拾わない（gh pr create セグメント内のみ検索）"

assert_eq "feat/x" "$(gh_pr_create_head_branch 'cd /repo && gh pr create --head feat/x --title t')" \
  "cd と併記された複合コマンドでも gh pr create セグメントの --head を正しく抽出する"

# --- gh_pr_create_head_branch: 3 バイパスの回帰ガード（B-2 追加修正・Critical・{ISSUE-ID} P3）---
# レビュー指摘: 旧実装は _cm_strip_quoted（引用符の中身を丸ごと削除）を値抽出に転用しており、
# 以下 3 バイパスが成立していた。quote-aware トークナイザへの書き換えで生値を正しく保持する
# （main/master 判定自体は cm_normalize_head_branch / cm_is_main_or_master_branch の責務）。
echo "command-match: gh_pr_create_head_branch 3 バイパス回帰ガード（引用符/フォーク/大文字）"

# 1. 引用符バイパス: --head "main" の中身が削除されて次トークン(--base)を誤取得しないこと
assert_eq "main" "$(gh_pr_create_head_branch 'gh pr create --head "main" --base main -R owner/repo')" \
  "引用符バイパス回帰ガード: --head \"main\" は中身の main を正しく抽出する（次トークン --base を誤取得しない）"

assert_eq "main" "$(gh_pr_create_head_branch "gh pr create --head 'main' --base main -R owner/repo")" \
  "引用符バイパス回帰ガード: --head 'main'（シングルクォート）も同様に main を正しく抽出する"

assert_eq "main" "$(gh_pr_create_head_branch 'gh pr create --head=main --base main')" \
  "= 区切りの --head=main も引き続き main を抽出する"

# 2. フォーク構文バイパス: --head owner:main は生値としてそのまま返す
#    （main/master 判定側の cm_normalize_head_branch がコロン以降を取り出す・後続テスト）
assert_eq "owner:main" "$(gh_pr_create_head_branch 'gh pr create --head owner:main --base main')" \
  "フォーク構文バイパス回帰ガード: --head owner:main は生値 owner:main をそのまま返す（正規化は呼び出し側）"

# 3. 大文字バイパス: --head MAIN は生値としてそのまま返す（正規化は呼び出し側）
assert_eq "MAIN" "$(gh_pr_create_head_branch 'gh pr create --head MAIN --base main')" \
  "大文字バイパス回帰ガード: --head MAIN は生値 MAIN をそのまま返す（正規化は呼び出し側）"

assert_eq "master" "$(gh_pr_create_head_branch 'gh pr create --head master --base main')" \
  "--head master も引き続き生値を正しく抽出する"

# 引用符で囲まれた feature ブランチも正しく抽出できる（quote-aware トークナイザの正の検証）
assert_eq "feat/x" "$(gh_pr_create_head_branch 'gh pr create --head "feat/x" --base main')" \
  "引用符で囲まれた feature ブランチ --head \"feat/x\" も正しく抽出する"

assert_eq "owner:feat/x" "$(gh_pr_create_head_branch 'gh pr create --head owner:feat/x --base main')" \
  "フォーク構文の feature ブランチ --head owner:feat/x も生値のまま抽出する"

# --- 4. 重複 --head の last-wins（Critical 回帰ガード・{ISSUE-ID} P3 再レビュー）---
# gh は Cobra/pflag ベースで、文字列フラグを繰り返すと後段の値が前段を上書きする
# （実機で確認済み）。旧実装は最初の --head を採用していたため、無害な --head を
# 先頭に置いて実際の main 指定を後段に隠すバイパスが成立していた。
echo "command-match: gh_pr_create_head_branch 重複 --head last-wins（Critical・再レビュー）"

assert_eq "main" "$(gh_pr_create_head_branch 'gh pr create --head feat/decoy-safe --head main --base main --title t')" \
  "重複 --head: 無害な先頭 --head の後に --head main があれば main（後勝ち）を採用する（バイパス封鎖）"

assert_eq "feat/safe" "$(gh_pr_create_head_branch 'gh pr create --head main --head feat/safe --base main --title t')" \
  "重複 --head: 逆順（main → feature）も後勝ちで feat/safe を採用する（過剰ブロック防止）"

assert_eq "main" "$(gh_pr_create_head_branch 'gh pr create --head=feat/decoy --head main --base main')" \
  "重複 --head: = 区切りとスペース区切りの混在でも後勝ち（main）を採用する"

# --- {ISSUE-ID} 統合: bash -c ラップの中の --head も抽出する（マージ統合時に追加）---
# is_gh_pr_create_command（検知側）は {ISSUE-ID} で bash -c "gh pr create ..." を検知する。
# 値抽出側が bash -c を展開しないと「検知はされるが --head が見えず CWD フォールバック」
# の非対称が生まれ、worktree CWD からの --head main 誤用が素通りする（fail-closed 統合）。
echo "command-match: gh_pr_create_head_branch の bash -c 展開（{ISSUE-ID} 統合）"

assert_eq "main" "$(gh_pr_create_head_branch "bash -c 'gh pr create --head main --base main'")" \
  "bash -c ラップ（シングルクォート）内の --head main も抽出する（検知側 {ISSUE-ID} と対称）"

assert_eq "feat/x" "$(gh_pr_create_head_branch 'bash -c "gh pr create --head feat/x --base main"')" \
  "bash -c ラップ（ダブルクォート）内の --head feat/x も抽出する"

assert_eq "" "$(gh_pr_create_head_branch 'echo "bash -c \"gh pr create --head main\""')" \
  "別コマンドの引用符リテラル内の bash -c は command position でないため展開・抽出しない"

# --- cm_normalize_head_branch: フォーク構文の defork + 小文字化（B-2 追加修正）---
echo "command-match: cm_normalize_head_branch（フォーク構文 defork + 小文字化）"

assert_eq "main" "$(cm_normalize_head_branch 'owner:main')" \
  "フォーク構文 owner:main はコロン以降（ブランチ部）main を取り出す"

assert_eq "main" "$(cm_normalize_head_branch 'MAIN')" \
  "大文字 MAIN は小文字化して main を返す"

assert_eq "main" "$(cm_normalize_head_branch 'Owner:MAIN')" \
  "フォーク構文 + 大文字の組み合わせも defork + 小文字化して main を返す"

assert_eq "feat/x" "$(cm_normalize_head_branch 'feat/x')" \
  "フォーク構文・大文字を含まない通常のブランチ名はそのまま返す（小文字化のみ適用）"

assert_eq "" "$(cm_normalize_head_branch '')" \
  "空文字は空文字を返す"

# --- cm_is_main_or_master_branch: 正規化込みの main/master 判定（B-2 追加修正）---
echo "command-match: cm_is_main_or_master_branch（正規化込み main/master 判定）"

assert_eq "0" "$(match_check cm_is_main_or_master_branch 'main')" \
  "main はそのまま main/master 対象と判定する"

assert_eq "0" "$(match_check cm_is_main_or_master_branch 'MAIN')" \
  "大文字 MAIN も main/master 対象と判定する（大文字バイパス封鎖）"

assert_eq "0" "$(match_check cm_is_main_or_master_branch 'owner:main')" \
  "フォーク構文 owner:main も main/master 対象と判定する（フォーク構文バイパス封鎖）"

assert_eq "0" "$(match_check cm_is_main_or_master_branch 'Owner:MAIN')" \
  "フォーク構文 + 大文字の組み合わせも main/master 対象と判定する"

assert_eq "0" "$(match_check cm_is_main_or_master_branch 'master')" \
  "master も main/master 対象と判定する"

assert_eq "0" "$(match_check cm_is_main_or_master_branch 'MASTER')" \
  "大文字 MASTER も main/master 対象と判定する"

assert_eq "0" "$(match_check cm_is_main_or_master_branch 'owner:master')" \
  "フォーク構文 owner:master も main/master 対象と判定する"

assert_eq "1" "$(match_check cm_is_main_or_master_branch 'feat/x')" \
  "feature ブランチは main/master 対象ではないと判定する"

assert_eq "1" "$(match_check cm_is_main_or_master_branch 'owner:feat/x')" \
  "フォーク構文の feature ブランチも main/master 対象ではないと判定する"

assert_eq "1" "$(match_check cm_is_main_or_master_branch '')" \
  "空文字は main/master 対象ではないと判定する"
# --- {ISSUE-ID}: サブコマンド自体の引用符分割バイパス ---
# 旧実装は _cm_strip_quoted がクォート内容を丸ごと削除していたため、
# `gh pr "create"` は `gh pr ` になり `^gh...create` アンカーに一致しなかった。
# 実トークン化（_cm_tokenize_line）でクォートを除去しつつ隣接語を結合することで、
# サブコマンド自体が引用符で分割されていても本来の語として復元して検知する。
echo "command-match: {ISSUE-ID} 引用符分割サブコマンドのバイパス検知"

assert_eq "0" "$(match_check is_gh_pr_create_command 'gh pr "create" --title x')" \
  "gh pr \"create\" --title x（サブコマンド全体を二重引用符で囲む）を検知する"

assert_eq "0" "$(match_check is_gh_pr_create_command "gh pr 'create' --title x")" \
  "gh pr 'create' --title x（単一引用符）を検知する"

assert_eq "0" "$(match_check is_gh_pr_create_command 'gh pr c"reate" --title x')" \
  "gh pr c\"reate\" --title x（語の途中で分割）を検知する"

assert_eq "0" "$(match_check is_gh_pr_merge_command 'gh pr "merge"')" \
  "gh pr \"merge\" を検知する"

# --- {ISSUE-ID}: 回帰防止 — 引用符分割検知を導入しても既存の誤発火回避は壊れない ---
echo "command-match: {ISSUE-ID} 回帰防止（引用符分割検知後も誤発火しない）"

assert_eq "1" "$(match_check is_gh_pr_create_command 'echo "gh pr \"create\" みたいな文字列"')" \
  "echo の引数値としての 'gh pr \"create\"' 相当の文字列は誤検知しない"

assert_eq "1" "$(match_check is_gh_pr_create_command 'grep "gh pr create" scripts/')" \
  "grep \"gh pr create\" は前段の追加検証後も誤検知しない（既存ケースの再確認）"

# クォート内のエスケープされた区切り文字（\|）を誤ってセグメント区切りと解釈しない
# （実トークン化導入に伴い _cm_segment_command もクォート認識セグメント分割に変更したための回帰防止）
assert_eq "1" "$(match_check is_gh_pr_create_command 'grep -n "gh.*pr.*create\|gh pr create" scripts/claude-hooks/pre-tool-use.sh')" \
  "クォート内のエスケープされたパイプ（\\|）はセグメント区切りと誤認しない"

# --- {ISSUE-ID}: git commit / git push の引用符分割バイパス検知 ---
# pre-tool-use.sh の main ブロックが生の grep（クォート未対応）で判定していたため、
# サブコマンド自体を引用符で分割すると main 上でも検知されなかった。
echo "command-match: {ISSUE-ID} git commit / git push の引用符分割検知"

assert_eq "0" "$(match_check is_git_commit_command 'git "commit" -m x')" \
  "git \"commit\" -m x を検知する"

assert_eq "0" "$(match_check is_git_commit_command 'git c"ommi"t -m x')" \
  "git c\"ommi\"t -m x（語の途中で分割）を検知する"

assert_eq "0" "$(match_check is_git_push_command 'git p"u"sh origin main')" \
  "git p\"u\"sh origin main を検知する"

assert_eq "0" "$(match_check is_git_push_command "git push origin 'main'")" \
  "git push origin 'main'（引数側の引用符）も通常通り検知する"

# 回帰防止: git commit / git push の誤発火回避（echo/grep の引数値としての出現は無視）
echo "command-match: {ISSUE-ID} git commit / git push 回帰防止"

assert_eq "1" "$(match_check is_git_commit_command 'echo "git commit -m done"')" \
  "echo \"git commit ...\" は誤検知しない"

assert_eq "1" "$(match_check is_git_push_command 'grep "git push" scripts/')" \
  "grep \"git push\" は誤検知しない"

assert_eq "1" "$(match_check is_git_commit_command 'gh pr comment 1 --body "please run git commit"')" \
  "gh pr comment の --body に git commit を含むケースは誤検知しない"

# --- {ISSUE-ID}: is_git_push_delete_non_main_command（--delete/-d 例外判定の引用符分割耐性） ---
echo "command-match: {ISSUE-ID} git push delete 例外の引用符分割耐性"

assert_eq "0" "$(match_check is_git_push_delete_non_main_command 'git p"u"sh origin --delete feat/123')" \
  "git p\"u\"sh origin --delete feat/123（push が引用符分割）でも feature 削除として検知する"

assert_eq "1" "$(match_check is_git_push_delete_non_main_command 'git push origin --delete "main"')" \
  "git push origin --delete \"main\"（削除対象が引用符分割）は main 削除として除外されない（= ブロック対象のまま）"

assert_eq "1" "$(match_check is_git_push_delete_non_main_command 'git push origin feat/123')" \
  "--delete/-d を含まない通常 push は対象外（false）"

# --- {ISSUE-ID}: is_worktree_cd_bypass の danger_re 引用符分割耐性（C-3 再燃防止） ---
# git commit が引用符分割されていると danger_re の素朴なマッチが反応せず、
# 後続の cd .claude/worktrees/ でバイパス成立と誤判定していた回帰の防止。
echo "command-match: {ISSUE-ID} is_worktree_cd_bypass の引用符分割耐性（C-3 再燃防止）"

assert_eq "1" "$(match_check is_worktree_cd_bypass 'git "commit" -m x ; cd .claude/worktrees/foo')" \
  "git \"commit\" -m x が先、cd worktree が後でも danger_re が検知しバイパス不可のまま"

assert_eq "1" "$(match_check is_worktree_cd_bypass 'git p"u"sh origin main ; cd .claude/worktrees/foo')" \
  "git p\"u\"sh origin main が先、cd worktree が後でも danger_re が検知しバイパス不可のまま"

# 正当なケース（cd worktree が先）は従来通りバイパス可
assert_eq "0" "$(match_check is_worktree_cd_bypass 'cd .claude/worktrees/foo && git "commit" -m x')" \
  "cd worktree が先で後段が引用符分割されたコマンドでも正当なバイパスは維持される"

# --- {ISSUE-ID}: パフォーマンス回帰テスト（批判的レビュー指摘対応） ---
# 旧実装（bash の ${var:i:1} を 1 文字ずつ読む手書きループ）は文字列長に対して O(n^2) に
# 劣化し、この hook が全 Bash 実行のたびに走る性質上、長いコミットメッセージ・ヒアドキュメント
# 経由の PR 本文で実害あるレイテンシになっていた（実測: 32,000 文字で約 2〜4.5 秒）。
# awk（substr が線形）への処理委譲でこれを解消したことの回帰ガード。
echo "command-match: {ISSUE-ID} パフォーマンス回帰（大きな入力でも高速に完了する）"

# Args: $1 = 予算秒数, $2以降 = 実行するコマンドと引数
# Returns: 0 = 予算内に完了, 1 = 予算超過
_cm_test_within_budget() {
  local budget="$1"
  shift
  local start end elapsed
  start=$(date +%s.%N)
  "$@" > /dev/null 2>&1
  end=$(date +%s.%N)
  elapsed=$(awk -v s="$start" -v e="$end" 'BEGIN{print e - s}')
  awk -v e="$elapsed" -v b="$budget" 'BEGIN{exit (e < b) ? 0 : 1}'
}

# 40,000 文字の引用符付き長大引数（旧実装なら数秒〜要する規模）
_cm_test_long_body=$(printf 'a %.0s' $(seq 1 20000))
_cm_test_long_cmd="git commit -m \"${_cm_test_long_body}\""

assert_eq "0" "$(match_check _cm_test_within_budget 2 is_git_commit_command "$_cm_test_long_cmd")" \
  "40,000 文字規模の引用符付き引数でも 2 秒以内に完了する（O(n^2) 回帰ガード）"

# --- is_review_verdict_post_command（#N Phase 2） ---
echo "command-match: is_review_verdict_post_command"
if is_review_verdict_post_command 'bash scripts/claude-hooks/review-verdict-post.sh 2 --critical 0'; then
  PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} RVP: repo 相対実行を検知"
else
  FAIL=$((FAIL + 1)); ERRORS+=("RVP: repo 相対実行を検知"); echo -e "  ${RED}✗${NC} RVP: repo 相対実行を検知"
fi
if is_review_verdict_post_command 'bash "/Users/x/.claude/plugins/cache/m/cc-autoship/0.1.9/scripts/claude-hooks/review-verdict-post.sh" 7'; then
  PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} RVP: cache 絶対パス（引用符）を検知"
else
  FAIL=$((FAIL + 1)); ERRORS+=("RVP: cache 絶対パス（引用符）を検知"); echo -e "  ${RED}✗${NC} RVP: cache 絶対パス（引用符）を検知"
fi
if is_review_verdict_post_command 'echo review-verdict-post.sh'; then
  FAIL=$((FAIL + 1)); ERRORS+=("RVP: echo 引数は非検知"); echo -e "  ${RED}✗${NC} RVP: echo 引数は非検知"
else
  PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} RVP: echo 引数は非検知"
fi

# --- is_review_verdict_post_command: 変数実行の検知 + 代入の非検知 ---
# review.md「レビュー結果のコメント」の locator は次の 2 行を必ず含む:
#   REL="scripts/claude-hooks/review-verdict-post.sh"   ← 代入（投稿前）
#   bash "$RVP" <PR#> --critical N --major N ...        ← 実行本体
# 従来はパス一致のみだったため、代入行に誤マッチして「投稿前に /auto-merge を促す」
# false positive を出す一方、スクリプト名が現れない実行本体は取りこぼしていた
# （＝ 発火は代入行への誤マッチだけに依存していた）。両者は表裏一体で、FP のみ
# 潰すと発火経路が消えて /auto-merge チェーンが死ぬため、同時に検証する。
echo "command-match: is_review_verdict_post_command（変数実行 / 代入・{ISSUE-ID}）"

# 実行本体（変数経由）は検知する = false negative の修正
if is_review_verdict_post_command 'bash "$RVP" 1694 --critical 0 --major 0 --tests green --high-risk yes --body-file /tmp/f.md'; then
  PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} RVP: 変数実行（\$RVP）を検知"
else
  FAIL=$((FAIL + 1)); ERRORS+=("RVP: 変数実行（\$RVP）を検知"); echo -e "  ${RED}✗${NC} RVP: 変数実行（\$RVP）を検知"
fi
if is_review_verdict_post_command 'bash "${RVP}" 7 --critical 1 --major 2 --tests red --high-risk no --body-file /tmp/x.md'; then
  PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} RVP: 変数実行（\${RVP} 形）を検知"
else
  FAIL=$((FAIL + 1)); ERRORS+=("RVP: 変数実行（\${RVP} 形）を検知"); echo -e "  ${RED}✗${NC} RVP: 変数実行（\${RVP} 形）を検知"
fi
# 変数名は review.md 依存にしない（locator を書き換えても検知が壊れないこと）
if is_review_verdict_post_command 'bash "$VERDICT_SCRIPT" 42 --critical 0 --major 0 --tests green --high-risk no --body-file /tmp/b.md'; then
  PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} RVP: 変数名非依存で検知"
else
  FAIL=$((FAIL + 1)); ERRORS+=("RVP: 変数名非依存で検知"); echo -e "  ${RED}✗${NC} RVP: 変数名非依存で検知"
fi

# 代入だけの行は検知しない = false positive の修正
if is_review_verdict_post_command 'REL="scripts/claude-hooks/review-verdict-post.sh"'; then
  FAIL=$((FAIL + 1)); ERRORS+=("RVP: 代入（REL=）は非検知"); echo -e "  ${RED}✗${NC} RVP: 代入（REL=）は非検知"
else
  PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} RVP: 代入（REL=）は非検知"
fi
if is_review_verdict_post_command 'RVP="${CLAUDE_PLUGIN_ROOT}/scripts/claude-hooks/review-verdict-post.sh"'; then
  FAIL=$((FAIL + 1)); ERRORS+=("RVP: 代入（RVP=）は非検知"); echo -e "  ${RED}✗${NC} RVP: 代入（RVP=）は非検知"
else
  PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} RVP: 代入（RVP=）は非検知"
fi
# review.md の locator 前半（locate のみ・実行なし）をそのまま流しても発火しないこと
if is_review_verdict_post_command 'REL="scripts/claude-hooks/review-verdict-post.sh"
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/$REL" ]; then
  RVP="${CLAUDE_PLUGIN_ROOT}/$REL"
elif [ -f "./$REL" ]; then
  RVP="./$REL"
fi'; then
  FAIL=$((FAIL + 1)); ERRORS+=("RVP: locator の locate 部のみは非検知"); echo -e "  ${RED}✗${NC} RVP: locator の locate 部のみは非検知"
else
  PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} RVP: locator の locate 部のみは非検知"
fi

# 読み取り参照は検知しない（既存挙動の回帰ガード）
if is_review_verdict_post_command 'ls -l scripts/claude-hooks/review-verdict-post.sh'; then
  FAIL=$((FAIL + 1)); ERRORS+=("RVP: ls 参照は非検知"); echo -e "  ${RED}✗${NC} RVP: ls 参照は非検知"
else
  PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} RVP: ls 参照は非検知"
fi
if is_review_verdict_post_command 'grep -n foo scripts/claude-hooks/review-verdict-post.sh'; then
  FAIL=$((FAIL + 1)); ERRORS+=("RVP: grep 参照は非検知"); echo -e "  ${RED}✗${NC} RVP: grep 参照は非検知"
else
  PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} RVP: grep 参照は非検知"
fi
# フラグ署名が揃わない別スクリプトの bash 実行を巻き込まない
if is_review_verdict_post_command 'bash other-tool.sh --critical 0'; then
  FAIL=$((FAIL + 1)); ERRORS+=("RVP: 署名不一致の bash 実行は非検知"); echo -e "  ${RED}✗${NC} RVP: 署名不一致の bash 実行は非検知"
else
  PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} RVP: 署名不一致の bash 実行は非検知"
fi

# 起動シグネチャは「実行」に限る: 説明文・コミットメッセージ中の擬似コマンド行を拾わない。
# 実観測: 本修正のコミットメッセージ本文に解説として書いた
#   bash "$RVP" <PR#> --critical N --major N --tests ...
# が git commit -F - のコマンド文字列に含まれ、署名検知が誤発火した（PR 番号は別行の
# 実例から拾われ、無関係な PR への /auto-merge を促した）。実起動は PR 番号が必ず
# 裸の整数で第 1 引数に来る（review-verdict-post.sh の usage）ため、それを要求して弾く。
if is_review_verdict_post_command 'bash "$RVP" <PR#> --critical N --major N --tests green|red --high-risk yes|no --body-file <path>'; then
  FAIL=$((FAIL + 1)); ERRORS+=("RVP: 解説中の擬似コマンド（<PR#> プレースホルダ）は非検知"); echo -e "  ${RED}✗${NC} RVP: 解説中の擬似コマンド（<PR#> プレースホルダ）は非検知"
else
  PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} RVP: 解説中の擬似コマンド（<PR#> プレースホルダ）は非検知"
fi
if is_review_verdict_post_command 'bash "$RVP" $PR_NUM --critical 0 --major 0 --tests green'; then
  FAIL=$((FAIL + 1)); ERRORS+=("RVP: PR 番号が変数の擬似コマンドは非検知"); echo -e "  ${RED}✗${NC} RVP: PR 番号が変数の擬似コマンドは非検知"
else
  PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} RVP: PR 番号が変数の擬似コマンドは非検知"
fi

# 性能ガード: 本関数は hook から全 Bash 呼び出しごとに呼ばれる。署名走査を無条件に
# 走らせるとセグメント分割 + awk 起動が二重になり、無関係なコマンドでもコストが 2 倍に
# なる（実測: 120 行コマンドで 257ms → 506ms）。--critical を含まない大半のコマンドは
# 走査前に落ちること（＝ 早期リターンが効いていること）を所要時間で担保する。
_RVP_BIG=$(printf 'echo line-%s aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' $(seq 1 120))
_RVP_T0=$(date +%s)
is_review_verdict_post_command "$_RVP_BIG" || true
_RVP_T1=$(date +%s)
if [ $((_RVP_T1 - _RVP_T0)) -le 1 ]; then
  PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} RVP: --critical なしの大きなコマンドは走査せず即断（性能ガード）"
else
  FAIL=$((FAIL + 1)); ERRORS+=("RVP: --critical なしの大きなコマンドは走査せず即断（性能ガード）"); echo -e "  ${RED}✗${NC} RVP: --critical なしの大きなコマンドは走査せず即断（性能ガード）"
fi
unset _RVP_BIG _RVP_T0 _RVP_T1