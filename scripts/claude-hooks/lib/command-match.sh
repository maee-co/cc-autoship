#!/usr/bin/env bash
# Bash コマンド文字列から「実際に gh pr <subcommand> / git commit / git push が実行される」かを
# 判定する純関数群。
#
# {ISSUE-ID}: post-tool-use-pr-created.sh が grep -qE 'gh pr create' で単純検知していたため、
#   echo "gh pr create" や grep "gh pr create" file で誤発火していた。
#   ここで引用符・コマンド置換を除去 + セグメント分割で「コマンド本体としての出現」を判定する。
#
# {ISSUE-ID}: 上記の引用符除去は「クォート区間の中身を丸ごと削除する」実装だったため、
#   サブコマンド自体を引用符で分割する（git "commit" / gh p"u"sh 等）と検知を回避できた
#   （旧 `_cm_strip_quoted` が "commit" の中身を消して `git  -m x` になり、
#     `^git...commit` アンカーに一致しなくなる）。
#   実シェルは `git "commit"` を「commit という 1 ワード」にトークン化するため、
#   本ファイルは以下の 2 段構成に変更した:
#     1. `_cm_segment_command`: クォートの内側にある `;`/`&`/`|` を区切り文字と誤認しない
#        「クォート認識セグメント分割」（旧実装は素朴な文字列置換で、`grep "a\|b"` のような
#        クォート内のエスケープ済みパイプまで誤って分割していた）
#     2. `_cm_tokenize_line`: 各セグメントを実トークン化（クォート除去 + 隣接クォートのグルー
#        結合）してから語順アンカーマッチする
#   これにより、クォートで分割されたサブコマンドも本来のワードとして復元されて検知される。
#
# 想定する誤発火パターン（すべて false を返す）:
#   echo "gh pr create を呼ぶ前のチェック"
#   grep "gh pr create" scripts/...
#   cat README.md | grep "gh pr create"
#   gh issue comment 123 --body "gh pr create を実行してください"
#   awk '/gh pr create/ { ... }'
#
# 想定する正の検知（すべて true を返す）:
#   gh pr create --title ...
#   cd .claude/worktrees/foo && gh pr create
#   gh pr create; echo done
#   echo "before"; gh pr create
#   gh pr "create" --title ...        ({ISSUE-ID}: 引用符分割サブコマンド)
#   git "commit" -m x / git p"u"sh origin main も同様にトークン化で復元される
#   gh pr -R o/r merge N / gh pr --repo o/r merge N
#                                      ({ISSUE-ID} / {ISSUE-ID}: pr とサブコマンドの間の -R/--repo)
#
# コマンド置換（$(...) / `...`）の扱い:
#   bash はコマンド置換の中身をサブシェルで「実行」する。`PR_URL=$(gh pr create)` や
#   `echo "$(gh pr create)"` は実際に gh pr create が走るため、検知対象にする。
#   実装: $(...) / `...` の中身を改行で囲んで「独立セグメント」として残し、
#   セグメント分割後に通常の検知ロジックで拾う（C-1 / Codex 二次レビュー対応）。
#
# 制限（Known limitations）:
#   1. （{ISSUE-ID} / {ISSUE-ID} で解消）ヒアドキュメント本体（<<EOF ... EOF）は _cm_strip_heredoc_bodies
#      が実行セグメント化される前に除去する。デリミタが引用符付き（<<'EOF' / <<"EOF" / <<\EOF）
#      なら本体は完全に inert なので丸ごと除去し、素の <<EOF は本体の地の文を除去しつつ、
#      内部の $(...) / `...`（unquoted ヒアドキュメントは実際に展開・実行されるため）だけは
#      温存して後段の抽出に委ねる。ヒアストリング（<<<）・1 行に連なる複数ヒアドキュメント
#      （cat <<A <<B）は区別済み。デリミタ語は [A-Za-z0-9_]+ のみ対応し、それ以外の記号を
#      含む語は未検出のまま安全側（旧来どおり過検知）にフォールバックする。
#   2. 改行をまたぐ引用符（"line1\n...\nline2"）は単一行扱いで除去できない（行単位処理のため）。
#      ヒアドキュメントと異なり本 Issueのスコープ外（対応案 B 相当・未実装）。
#   3. ネストした引用符・$(...) は最外側しか除去・展開しない
#   2/3 は「実行コマンドとして gh pr create / git commit / git push を含むケース」では
#   発生しない構造であり、多少の過検知（=ブロック）はユーザー害が小さい（引用符を外せば抜けられる）。
#   詳細とテスト契約: __tests__/test-command-match.sh の "known limitations" セクション
#
# 公開関数:
#   is_gh_pr_create_command  <command>
#   is_gh_pr_comment_command <command>
#   is_gh_pr_merge_command   <command>
#   is_git_commit_command    <command>
#   is_git_push_command      <command>
#   resolve_target_branch <command>          (B-1 / {ISSUE-ID} P3)
#   cm_git_danger_targets_main <command> <commit|push>  (B-1 / {ISSUE-ID} P3)
#   gh_pr_create_head_branch <command>       (B-2 / {ISSUE-ID} P3。値抽出は quote-aware・B-2 追加修正)
#   cm_normalize_head_branch <raw_head_value>            (B-2 追加修正 / {ISSUE-ID} P3)
#   cm_is_main_or_master_branch <raw_head_value>         (B-2 追加修正 / {ISSUE-ID} P3)
#
# 返値: 0 = 検知、1 = 非検知

# bash -c / sh -c ラップ形の "-c 引数" を展開する。
# bash -c "gh pr create" の引用符の中身は「リテラル文字列」ではなく「実行されるコマンド」。
# _cm_strip_quoted は文字列リテラルを削除する設計のため、展開しないと gh pr create を
# 取りこぼす（{ISSUE-ID} で additionalContext ブロックが出なかった実測原因）。
# $(...) / `...` と同様「実際に実行されるコード」として中身を改行で囲んで残す。
#
# 素朴な sed "([^"]*)" では (a) エスケープ引用符 \" を境界と誤認して -c 引数を途中で
# 打ち切り、(b) command position 前置詞が wrapper（env / command ...）を許容しない、の
# 2 系統がすり抜けた（{ISSUE-ID} / Codex 二次レビュー実証・bash 3.2.57）。字句解析ループで
# 「実際に実行される -c 引数」を正確に切り出す（元は bash 3.2 互換の手書きループだったが、
# 文字列長に対して O(n^2) に劣化する性能回帰があったため awk 実装に移行した・{ISSUE-ID}。
# 状態機械のロジック自体は変更していない）。
#
# command position 限定（過剰マッチ回避が要）:
#   shell（bash/sh/zsh/dash）が実行コマンド本体（行頭 or ; & | ( 改行 の直後、あるいは
#   既知 wrapper 接頭辞の直後）にあるときだけ展開する。echo "bash -c 'gh pr create'" の
#   ように引用符リテラルの中にある bash -c は実行されないため展開しない（リテラル領域は
#   字句解析でそのまま複写しスキップする）。echo bash -c "..." のような非 wrapper 接頭辞も
#   展開しない（echo は引数を実行しないため）。
# 対応形:
#   - shell 直呼び: bash -c / sh -c / zsh -c / dash -c、結合フラグ（-lc 等）、-c 前の
#     フラグ・引数（-euo pipefail -c）、パス接頭辞（/bin/bash）
#   - 接頭辞ラップ: env VAR=... / command / sudo / exec / xargs 等の既知 wrapper
#   - エスケープ引用符: -c 引数内の \" / \\ を跨いで正しい閉じ引用符まで切り出す
#   - double / single 両方の引用符
# 既知の制限（未対応・safe 側 or 稀な形）:
#   - 多段ネスト（bash -c "bash -c '...'"）は最外側のみ展開
#   - バッククォート / $(...) 内の bash -c は本関数では展開せず _cm_strip_quoted の
#     コマンド置換展開に委ねる
#   - 直接ラップ（env FOO=1 gh pr create のように bash -c を介さない wrapper）は本関数の
#     対象外（unwrap ではなくセグメント側の別ギャップ）
# 恒等性: bash -c 構文が command position に無い入力に対しては 1 文字ずつそのまま複写する
#   （＝恒等変換）。既存の引用符リテラル削除・$(...) 展開・複数行/ヒアドキュメント過検知は
#   _cm_strip_quoted 側の sed が従来どおり処理する（本関数の変更では挙動不変）。
# 注意: 本関数は _cm_strip_for_bypass には適用しない。bash -c はサブシェルであり、その中の
#   cd は親シェルの cwd を変えないため、worktree バイパス判定では中身を "残して" はならない
#   （$(...) / `...` を _cm_strip_for_bypass で削除するのと同じ理由。C-4 / C-5 と同型）。
#   例外（C-8・{ISSUE-ID}）: is_worktree_cd_bypass の入口では「コマンド全体が単一の bash -c
#   呼び出し」の場合に限り 1 段 unwrap する。この形では内側の cd と危険コマンドが**同じ
#   サブシェル**を共有するため cd が実効する（`bash -c 'cd wt' && git commit` のように
#   閉じクォート後に別コマンドが続く形は unwrap しない = C-4/C-5 の原則は維持）。

# コマンドを実行する透過 wrapper（この直後の shell -c は実際に実行される）。
# env の VAR=val / -flag 引数、sudo の -u user 等は shell 名まで読み飛ばす。
_CM_WRAPPER_RE='^(/[^[:space:]]*/)?(env|command|sudo|doas|exec|xargs|nice|ionice|nohup|time|stdbuf|setsid|timeout)$'
# 実行コマンド本体として扱う shell 名（任意の /path/ 接頭辞を許容）。
_CM_SHELL_RE='^(/[^[:space:]]*/)?(bash|sh|zsh|dash)$'
# -c フラグ（結合形 -lc / -euoc 等も可）。
_CM_C_FLAG_RE='^-[a-zA-Z]*c$'
# 環境変数代入の接頭辞（FOO=1 bash -c ... のように bash を実行する）。
_CM_ASSIGN_RE='^[A-Za-z_][A-Za-z0-9_]*='
# リテラルのバックスラッシュ 1 文字（$'\\' は ANSI-C。'\' 直書きは SC1003 誤検知になる）。
_CM_BS=$'\\'

# command position の 1 箇所から [wrapper*] shell [flags] -Xc <quoted> を試行し、
# マッチすれば -c 引数の中身を展開する（{ISSUE-ID} / {ISSUE-ID} 続報: 性能回帰の修正）。
#
# 実装ノート（性能・{ISSUE-ID}）: 旧実装は bash の `${var:i:1}` を 1 文字ずつ読む手書き
# 字句解析ループだった。`_cm_tokenize_line` / `_cm_segment_command` の docstring が
# 明記するとおり、bash の `${var:i:1}` は文字列長に対して O(n) かかる実装のため、
# 1 文字ずつ読むだけのループでも全体で O(n^2) に劣化する（実測: 32,000 文字で約 2〜4.5 秒）。
# この関数は `_cm_expand_command_substitution` 経由で is_gh_pr_*/is_git_* のほぼ全経路から
# 無条件に呼ばれる（"bash -c" を含まない通常コマンドでも実行される）ため、hook 全体の
# レイテンシに直結していた（回帰: {ISSUE-ID} / {ISSUE-ID} で bash 手書きループとして再実装された）。
# `_cm_tokenize_line` と同じ理由で awk（substr が O(1) ランダムアクセス）に処理を委譲し、
# 全体を O(n) にする。ロジック（状態機械）は旧 bash 実装と完全に同一（1:1 移植）。
_cm_unwrap_shell_c() {
    printf '%s' "$1" | awk -v RS='\003' -v sq="'" \
        -v shell_re="$_CM_SHELL_RE" \
        -v wrapper_re="$_CM_WRAPPER_RE" \
        -v cflag_re="$_CM_C_FLAG_RE" \
        -v assign_re="$_CM_ASSIGN_RE" '
    function is_space(c) {
        return (c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\v" || c == "\f")
    }
    function is_sep(c) {
        return (c == sq || c == "\"" || c == ";" || c == "&" || c == "|" || c == "(" || c == ")" || c == "`")
    }
    function is_reset_sep(c) {
        return (c == ";" || c == "&" || c == "|" || c == "(" || c == "\n")
    }
    # command position から [wrapper*] shell [flags] -Xc <quoted> を試行する。
    # 成功時: RESULT_CONTENT に -c 引数の中身、RESULT_LEN に消費文字数を設定し 1 を返す。
    # 失敗時: 0 を返す（RESULT_* は不定・呼び出し側は参照しないこと）。
    function try_match_shellc(s, start,    n, j, saw_wrapper, shell_found, c_found, tok, tstart, cc, c, q, content) {
        n = length(s)
        j = start
        saw_wrapper = 0
        shell_found = 0

        # 前置詞トークン（wrapper + その引数）を shell 名まで読み飛ばす
        while (j <= n) {
            while (j <= n && is_space(substr(s, j, 1))) j++
            if (j > n) return 0
            c = substr(s, j, 1)
            if (is_sep(c)) return 0

            tstart = j
            while (j <= n) {
                cc = substr(s, j, 1)
                if (is_sep(cc) || is_space(cc)) break
                j++
            }
            tok = substr(s, tstart, j - tstart)

            if (tok ~ shell_re) { shell_found = 1; break }
            if (tok ~ wrapper_re) { saw_wrapper = 1; continue }
            # 裸の環境変数代入接頭辞（FOO=1 bash -c ...）も bash を実行するため許容する
            if (tok ~ assign_re) { saw_wrapper = 1; continue }
            # shell でも wrapper でも代入でもない先頭トークン（echo 等）→ unwrap しない
            if (!saw_wrapper) return 0
            # wrapper の引数（VAR=val / -flag / 値）とみなし読み飛ばす
        }
        if (!shell_found) return 0

        # shell の後、-Xc フラグまでフラグ・引数を読み飛ばす
        c_found = 0
        while (j <= n) {
            while (j <= n && is_space(substr(s, j, 1))) j++
            if (j > n) return 0
            c = substr(s, j, 1)
            if (is_sep(c)) return 0

            tstart = j
            while (j <= n) {
                cc = substr(s, j, 1)
                if (is_sep(cc) || is_space(cc)) break
                j++
            }
            tok = substr(s, tstart, j - tstart)
            if (tok ~ cflag_re) { c_found = 1; break }
        }
        if (!c_found) return 0

        # -Xc の後は空白 + 引用符
        while (j <= n && is_space(substr(s, j, 1))) j++
        if (j > n) return 0
        q = substr(s, j, 1)
        if (q != sq && q != "\"") return 0
        j++

        # 引用符の中身を切り出す（double は \\ / \" エスケープを跨いで正しい閉じ引用符を探す）
        content = ""
        if (q == "\"") {
            while (j <= n) {
                cc = substr(s, j, 1)
                if (cc == "\\" && (j + 1) <= n) {
                    content = content cc substr(s, j + 1, 1)
                    j += 2
                    continue
                }
                if (cc == "\"") break
                content = content cc
                j++
            }
        } else {
            # single quote: 中身はリテラル（エスケープ解釈なし）
            while (j <= n) {
                cc = substr(s, j, 1)
                if (cc == sq) break
                content = content cc
                j++
            }
        }
        if (j > n) return 0   # 閉じ引用符が無い（未終端）→ 未マッチ
        j++   # 閉じ引用符を消費

        RESULT_CONTENT = content
        RESULT_LEN = j - start
        return 1
    }
    {
        s = $0
        n = length(s)
        out = ""
        i = 1
        at_cmd = 1
        while (i <= n) {
            c = substr(s, i, 1)
            # コマンド区切り → 次は command position
            if (is_reset_sep(c)) {
                out = out c
                at_cmd = 1
                i++
                continue
            }
            # 空白は command position を維持したまま複写する
            if (is_space(c)) {
                out = out c
                i++
                continue
            }
            # command position で shell -c ラップを試行（成功時のみ中身を展開）
            if (at_cmd && try_match_shellc(s, i)) {
                out = out "\n" RESULT_CONTENT "\n"
                i = i + RESULT_LEN
                at_cmd = 0
                continue
            }
            at_cmd = 0
            # 引用符リテラルは中身を command position 走査せずそのまま複写する
            if (c == sq) {
                out = out c
                i++
                while (i <= n) {
                    cc = substr(s, i, 1)
                    out = out cc
                    i++
                    if (cc == sq) break
                }
            } else if (c == "\"") {
                out = out c
                i++
                while (i <= n) {
                    cc = substr(s, i, 1)
                    if (cc == "\\" && (i + 1) <= n) {
                        out = out cc substr(s, i + 1, 1)
                        i += 2
                        continue
                    }
                    out = out cc
                    i++
                    if (cc == "\"") break
                }
            } else {
                out = out c
                i++
            }
        }
        printf "%s", out
    }'
}

# ヒアドキュメント本体を実行セグメントとして誤検知しないよう除去する。
#
# 背景: bash はヒアドキュメント本体（<<EOF ... EOF）を「実行」しない。にもかかわらず
# _cm_segment_command は改行を区切りとしてセグメント分割するため、本体中に書かれた
# 「コマンド例」（コミットメッセージの説明文・ドキュメント片）が実行セグメントとして
# 誤検知されていた（実観測 / {ISSUE-ID}: `git commit -F - <<EOF` の本体に書いた
# `gh pr comment 123 --body "..."` が is_gh_pr_comment_command を誤発火させ、
# post-tool-use-auto-merge-after-review.sh が無関係な PR への auto-merge を促した）。
#
# 除去ルール:
#   - デリミタが引用符付き（<<'EOF' / <<"EOF" / <<\EOF）: 本体は展開が一切起きない
#     完全な inert テキストのため、本体全体を破棄する。
#   - デリミタが素の場合（<<EOF）: 本体はパラメータ展開・コマンド置換（$(...) / `...`）を
#     受ける（実際に実行されうる。C-1 と同じ理由）。そのため本体の地の文は破棄しつつ、
#     $(...) / `...` の出現だけは温存し、抽出自体は後段の
#     _cm_expand_command_substitution / _cm_strip_for_bypass の sed に委ねる（責務分離）。
#   - ヒアストリング（<<<）はヒアドキュメントではないため対象外（素通し）。
#   - 引用符の内側にある `<<` はヒアドキュメント演算子として扱わない（quote-aware）。
#   - 1 行に複数のヒアドキュメントが連なる場合（`cat <<A <<B`）は出現順に本体を消費する
#     （FIFO キュー）。
#   - `<<-` は本体各行・終端行の先頭タブを除去してから終端語と照合する。
#   - デリミタ語は `[A-Za-z0-9_]+` のみ対応する（allowlist ではなく、パターン外の記号を
#     含む語は検出せず素通しする安全側フォールバック＝旧来どおりの過検知が残るのみで、
#     新たな見逃しにはならない）。
#   - ネストした $(...) ・複数行にまたがる $(...) は非対応（既存の限界 {ISSUE-ID} と同じ近似）。
#
# 実装ノート（性能）: _cm_unwrap_shell_c / _cm_tokenize_line と同じ理由で、bash の
# 手書き文字ループは長い入力で O(n^2) に劣化するため awk（substr が O(1)）に処理を委譲する
# （実測: 約 33,000 文字のヒアドキュメント入力で約 30ms）。
_cm_strip_heredoc_bodies() {
    awk -v RS='\003' -v sq="'" -v dq='"' '
    # 有効な語境界（空白・改行・既知のシェルメタ文字・別ヒアドキュメント演算子の開始）。
    # デリミタ語の直後がこれ以外なら「語の途中で打ち切った」ことを意味するため、
    # ヒアドキュメントとして確定せず素通しする（Codex 二次レビュー指摘 3 対応）。
    function is_boundary(c) {
        return (c == "" || c == " " || c == "\t" || c == "\n" || c == ";" || c == "&" || c == "|" || c == "(" || c == ")" || c == "<" || c == ">")
    }
    # 空白・改行・シェルメタ文字・引用符・$・バックスラッシュ以外はすべて語の一部として
    # 許容する（`EOF-X` / `END.MARKER` のような記号入りデリミタを正しく読み切るため。
    # `[A-Za-z0-9_]` のみに限定していた旧実装は非対応文字の手前で語を打ち切ってしまい、
    # 実デリミタと不一致の終端語で本体を検索し続け、入力末尾まで本体扱いで飲み込む
    # fail-open 回帰があった（Codex 二次レビュー指摘 3）。
    function is_wordchar(c) {
        return (c !~ /[ \t\n;&|()<>`$'"'"'"\\]/)
    }
    {
        s = $0
        n = length(s)
        out = ""
        i = 1
        state = 0   # 0=通常 1=ダブルクォート内 2=シングルクォート内
        pend_n = 0
        arith_depth = 0   # $((...)) / ((...)) 算術展開スコープの深さ（0 = スコープ外）
        while (i <= n) {
            c = substr(s, i, 1)
            # クォート追跡は _cm_segment_command と同じ簡易モデル（エスケープ非対応）に
            # 揃える。ここで異なる境界を認識すると後段のセグメント分割と食い違いが生じる。
            if (state == 1) {
                out = out c
                if (c == dq) state = 0
                i++
                continue
            }
            if (state == 2) {
                out = out c
                if (c == sq) state = 0
                i++
                continue
            }
            if (c == dq) { state = 1; out = out c; i++; continue }
            if (c == sq) { state = 2; out = out c; i++; continue }

            # 算術展開 $((...)) / ((...)) のスコープ内では << は shift 演算子であり
            # ヒアドキュメントではない（Codex 二次レビュー指摘 2: `x=$((1<<2))` の誤認）。
            # スコープは "((" の出現で開始し、対応する ")" が閉じるまで維持する
            # （ネストした grouping 括弧 `(b<<c)` にも対応するため深さで管理する）。
            if (arith_depth > 0) {
                if (c == "(") { arith_depth++; out = out c; i++; continue }
                if (c == ")") { arith_depth--; out = out c; i++; continue }
                out = out c
                i++
                continue
            }
            if (c == "(" && substr(s, i+1, 1) == "(") {
                arith_depth = 2
                out = out c substr(s, i+1, 1)
                i += 2
                continue
            }

            # ヒアドキュメント演算子の検出。
            if (c == "<" && substr(s, i+1, 1) == "<") {
                # 連続する "<" の長さを数える。ヒアストリング（<<<）や不正な連続入力は
                # ヒアドキュメントではないため、長さ 2 の場合のみ以降の解析に進む
                # （Codex 二次レビュー指摘 1: 旧実装は <<< の 2 文字目を独立した通常の
                #   "<<" 演算子として再検出し、後続の実コマンドを本体として飲み込んでいた）。
                run_len = 0
                while (substr(s, i + run_len, 1) == "<") run_len++
                if (run_len != 2) {
                    out = out substr(s, i, run_len)
                    i += run_len
                    continue
                }

                j = i + 2
                strip_tabs = 0
                if (substr(s, j, 1) == "-") { strip_tabs = 1; j++ }
                while (j <= n) {
                    cc = substr(s, j, 1)
                    if (cc == " " || cc == "\t") { j++ } else break
                }
                word = ""
                quoted = 0
                matched = 0
                if (j <= n) {
                    cc = substr(s, j, 1)
                    if (cc == sq) {
                        k = j + 1
                        while (k <= n && substr(s, k, 1) != sq) { word = word substr(s, k, 1); k++ }
                        if (k <= n) {
                            nxt = substr(s, k+1, 1)
                            if (is_boundary(nxt)) { j = k + 1; matched = 1; quoted = 1 }
                        }
                    } else if (cc == dq) {
                        k = j + 1
                        while (k <= n && substr(s, k, 1) != dq) { word = word substr(s, k, 1); k++ }
                        if (k <= n) {
                            nxt = substr(s, k+1, 1)
                            if (is_boundary(nxt)) { j = k + 1; matched = 1; quoted = 1 }
                        }
                    } else if (cc == "\\") {
                        k = j + 1
                        while (k <= n && is_wordchar(substr(s, k, 1))) { word = word substr(s, k, 1); k++ }
                        if (word != "") {
                            nxt = substr(s, k, 1)
                            if (is_boundary(nxt)) { j = k; matched = 1; quoted = 1 }
                        }
                    } else if (is_wordchar(cc)) {
                        k = j
                        while (k <= n && is_wordchar(substr(s, k, 1))) { word = word substr(s, k, 1); k++ }
                        nxt = substr(s, k, 1)
                        if (is_boundary(nxt)) { j = k; matched = 1 }
                    }
                }
                if (matched && word != "") {
                    # 演算子自体（<<EOF 等）は行のテキストとしてそのまま残す
                    out = out substr(s, i, j - i)
                    pend_n++
                    pend_word[pend_n] = word
                    pend_strip[pend_n] = strip_tabs
                    pend_quoted[pend_n] = quoted
                    i = j
                    continue
                }
                # 有効なヒアドキュメント演算子として解釈できなければ通常文字として継続
            }

            if (c == "\n") {
                out = out c
                i++
                # この行に演算子があったヒアドキュメントの本体を出現順（FIFO）に消費する
                while (pend_n > 0) {
                    w = pend_word[1]
                    st = pend_strip[1]
                    qd = pend_quoted[1]
                    for (k = 1; k < pend_n; k++) {
                        pend_word[k] = pend_word[k+1]
                        pend_strip[k] = pend_strip[k+1]
                        pend_quoted[k] = pend_quoted[k+1]
                    }
                    pend_n--

                    while (i <= n) {
                        le = i
                        while (le <= n && substr(s, le, 1) != "\n") le++
                        line = substr(s, i, le - i)
                        cand = line
                        if (st) { sub(/^\t+/, "", cand) }
                        if (cand == w) {
                            # 終端行: 消費して終了（内容は破棄）
                            i = le
                            if (i <= n) i++
                            break
                        }
                        # 本体行: 素のデリミタ（unquoted）のみ $(...) / `...` を温存する
                        # （unquoted ヒアドキュメントは実際に展開・実行されるため C-1 と同じ扱い）
                        if (!qd) {
                            tmp = line
                            while ((pos = match(tmp, /(`[^`]*`|\$\([^)]*\))/)) > 0) {
                                out = out substr(tmp, pos, RLENGTH) "\n"
                                tmp = substr(tmp, pos + RLENGTH)
                            }
                        }
                        i = le
                        if (i <= n) { i++ } else { break }  # 終端未検出のまま EOF（不正形式）
                    }
                }
                continue
            }

            out = out c
            i++
        }
        printf "%s", out
    }'
}

# コマンド置換の中身を「実際に実行される独立セグメント」として展開する。
# - バッククォート `...`:   中身を改行で囲んで残す（コマンド置換、実際に実行される）
# - コマンド置換 $(...):    中身を改行で囲んで残す（実際に実行される）
# クォート自体の除去（リテラル文字列の処理）はここでは行わない。
# クォート除去・語のグルー結合は後段の _cm_tokenize_line が担う。
# ネストには対応しない。
_cm_expand_command_substitution() {
    # shellcheck disable=SC2016
    # $(...) と `...` は中身を改行付きで残す。bash はこれらの中身を実行するため、
    # 文字列リテラル扱いで削除してしまうと main ブロックを迂回できる経路になる（C-1）。
    # ヒアドキュメント本体の除去は $(...) / `...` 展開の**前**に行う。
    # 本体地の文が実行セグメントとして誤検知されるのを防ぎつつ、unquoted ヒアドキュメント
    # 内の $(...) / `...`（実際に実行される）は _cm_strip_heredoc_bodies が温存するため、
    # このあとの sed 抽出で通常どおり拾われる。
    _cm_unwrap_shell_c "$1" \
        | _cm_strip_heredoc_bodies \
        | sed -E 's/`([^`]*)`/\n\1\n/g' \
        | sed -E 's/\$\(([^)]*)\)/\n\1\n/g'
}

# 後方互換のため維持（cm_strip_quoted 経由で外部公開）。
# {ISSUE-ID} 以前は「クォート内容を丸ごと削除する」実装だったが、サブコマンドの引用符分割を
# 検知できなかったため、実トークン化ベースに変更した。
# 処理順序は _cm_segment_starts_with と揃える（コマンド置換展開 → クォート認識セグメント分割 →
# 各セグメントをトークン化）。順序を逆にする（先にトークン化してからセグメント分割）と、
# クォート内のエスケープ済み区切り文字（例: grep "a\|b" の `\|`）を保護できなくなる。
_cm_strip_quoted() {
    local expanded
    expanded=$(_cm_expand_command_substitution "$1")
    local segmented
    segmented=$(_cm_segment_command "$expanded")

    local result=()
    while IFS= read -r _seg; do
        result+=("$(_cm_tokenize_line "$_seg")")
    done <<< "$segmented"

    local IFS=$'\n'
    printf '%s' "${result[*]}"
}

# 実シェルの単語分割 + クォート除去を模倣する 1 行トークナイザ。
#
# 目的: 「サブコマンド語がクォートで分割されているか（git "commit" / gh p"u"sh）」と
#       「別コマンドの引数値としてクォート文字列が渡されているか（echo "gh pr create"）」を
#       区別して正しく判定できるようにする。
#
# ルール（bash の word splitting + quote removal と同じ):
#   - クォート外の空白/タブは語区切り
#   - 語の内部では "..." / '...' / 生文字 を連結できる
#       git "commit"     -> 1 語 "commit"（git の次の語）
#       gh p"u"sh        -> 1 語 "push"
#       echo "gh pr create" -> echo という語の次に "gh pr create" という 1 語
#         （空白を含む 1 語だが、先頭語 echo とは別語のまま。既存の「セグメント先頭からの
#           アンカーマッチ」ロジックと組み合わせることで、danger word が echo の引数側に
#           あるケースは誤検知しない）
#   - コマンド置換 $(...) / `...` は呼び出し前に _cm_expand_command_substitution で
#     独立セグメント化済みという前提（本関数はクォート除去のみ担当）
#
# 引数: $1 = 1 行分のコマンド文字列（改行を含まない想定）
# 出力: クォート除去 + 語区切りを単一スペースに正規化した文字列
#
# 実装ノート（性能・{ISSUE-ID} 批判的レビュー指摘対応）: bash の `${var:i:1}` は文字列長に対して
# O(n) かかる実装であるため（実測: 1 文字ずつ ${var:i:1} を読むだけのループでも 32,000 文字で
# 約 2.4 秒。`cur+=` の連結方法をどう変えても、この読み取り自体がボトルネックのため解消しない）、
# bash の手書きループでは長い引数（長いコミットメッセージ・ヒアドキュメント経由の PR 本文等）で
# 実害あるレイテンシになる。この hook は Bash 実行のたびに走るため、`substr()` が長さに対して
# 線形な awk（gawk / BWK awk とも）にトークナイズ処理を委譲し O(n) にする
#（実測: 同条件で 32,000 文字 約 0.04 秒、100,000 文字でも 0.3 秒未満）。
# ロジック（状態機械）は元の bash 実装と同一: クォート外の空白/タブが語区切り、
# "..." / '...' は中身のみを直前の語に連結（クォート自体は出力に含めない）。
_cm_tokenize_line() {
    printf '%s' "$1" | awk -v RS='\003' -v sq="'" '
    {
        n = length($0)
        out = ""
        cur = ""
        has_content = 0
        state = 0  # 0=通常 1=ダブルクォート内 2=シングルクォート内
        i = 1
        while (i <= n) {
            c = substr($0, i, 1)
            if (state == 1) {
                if (c == "\"") { state = 0 } else { cur = cur c }
                i++
                continue
            }
            if (state == 2) {
                if (c == sq) { state = 0 } else { cur = cur c }
                i++
                continue
            }
            if (c == "\"") { state = 1; has_content = 1; i++; continue }
            if (c == sq)    { state = 2; has_content = 1; i++; continue }
            if (c == " " || c == "\t") {
                if (has_content) {
                    out = (out == "" ? cur : out " " cur)
                    cur = ""
                    has_content = 0
                }
                i++
                continue
            }
            cur = cur c
            has_content = 1
            i++
        }
        if (has_content) out = (out == "" ? cur : out " " cur)
        print out
    }'
}

# コマンドを実行セグメントに分割（;, &&, ||, |, &, 改行 で区切る）。
#
# {ISSUE-ID}: 旧実装は `cmd="${cmd//|/$'\n'}"` のような素朴な文字列置換だったため、
#   クォート内のエスケープされたパイプ（例: grep "a\|b" の `\|`）まで区切り文字として
#   誤って分割していた（実トークン化を導入しクォート内容を保持するようにした結果、
#   この既存の弱点が新たに露出した）。
#   本実装はクォート区間（"..." / '...'）の内側にある区切り文字を無視する
#   「クォート認識セグメント分割」に変更し、クォート内の `;`/`&`/`|` を誤爆させない。
#
# 実装ノート（性能・{ISSUE-ID} 批判的レビュー指摘対応）: bash の `${var:i:1}` は文字列長に対して
# O(n) かかる実装であるため、1 文字ずつ読む手書きループはどう `cur+=` を最適化しても
# O(n^2) から脱却できない（実測: 32,000 文字で約 2 秒）。`substr()` が線形な awk に処理を
# 委譲し O(n) にする（`_cm_tokenize_line` と同じ理由・実測は同関数コメント参照）。
# ロジック（状態機械）は元の bash 実装と同一で、クォート文字自体は出力にそのまま残す
#（クォート除去は後段の `_cm_tokenize_line` の責務）。入力に含まれ得る実改行
#（`_cm_expand_command_substitution` が $(...) / `...` の中身を独立セグメント化するために
#  挿入したもの）を awk のレコード分割に食わせないよう `RS` に制御文字（\003）を使い、
# 全体を 1 レコードとして読んでから、改行自体を区切り文字の一つとして自前で処理する。
_cm_segment_command() {
    printf '%s' "$1" | awk -v RS='\003' -v sq="'" '
    {
        n = length($0)
        seg = ""
        state = 0  # 0=通常 1=ダブルクォート内 2=シングルクォート内
        i = 1
        while (i <= n) {
            c = substr($0, i, 1)
            if (state == 1) {
                seg = seg c
                if (c == "\"") state = 0
                i++
                continue
            }
            if (state == 2) {
                seg = seg c
                if (c == sq) state = 0
                i++
                continue
            }
            if (c == "\"") { state = 1; seg = seg c; i++; continue }
            if (c == sq)    { state = 2; seg = seg c; i++; continue }
            if (c == "\n") { print seg; seg = ""; i++; continue }
            nc = (i < n) ? substr($0, i + 1, 1) : ""
            if (c == "&" && nc == "&") { print seg; seg = ""; i += 2; continue }
            if (c == "|" && nc == "|") { print seg; seg = ""; i += 2; continue }
            if (c == ";" || c == "|" || c == "&") { print seg; seg = ""; i++; continue }
            seg = seg c
            i++
        }
        print seg
    }'
}

# 公開: コマンド文字列から引用符・コマンド置換を処理した結果を出力する
# pre-tool-use-gh-pr-create.sh の worktree バイパス判定で使う（C-2 対応）。
cm_strip_quoted() {
    _cm_strip_quoted "$1"
}

# 公開: コマンド文字列を実行セグメントに分割した結果を出力する
# pre-tool-use-gh-pr-create.sh の worktree バイパス判定で使う（C-2 対応）。
cm_segment_command() {
    _cm_segment_command "$1"
}

# コマンドの実行セグメント群から「語順シーケンスがセグメント先頭に現れるか」を判定する
# 共通ヘルパー（{ISSUE-ID}: is_gh_pr_* / is_git_* で共有）。
#
# 引数: $1 = command, $2 = 語順の ERE（例: 'gh[[:space:]]+pr[[:space:]]+create'）
# 判定: コマンド置換展開 → クォート認識セグメント分割 → 各セグメントを実トークン化 →
#       セグメント先頭が語順 ERE にアンカーマッチするか
_cm_segment_starts_with() {
    local cmd="$1"
    local word_re="$2"

    [ -z "$cmd" ] && return 1
    [ -z "$word_re" ] && return 1

    local expanded
    expanded=$(_cm_expand_command_substitution "$cmd")
    local segmented
    segmented=$(_cm_segment_command "$expanded")

    while IFS= read -r seg; do
        local tokenized
        tokenized=$(_cm_tokenize_line "$seg")
        if [[ "$tokenized" =~ ^${word_re}([[:space:]]|$) ]]; then
            return 0
        fi
    done <<< "$segmented"

    return 1
}

# gh pr の永続フラグ（cobra/pflag の persistent flag）。`pr` とサブコマンドの間・後どちらにも
# 置ける（実測 {ISSUE-ID}: `gh pr -R o/r view N` は成功。`gh pr --help` の FLAGS 欄に -R/--repo、
# INHERITED FLAGS に --help）。値を取る -R/--repo とその値、値を取らない --help のみを対象と
# する。それ以外の未知フラグ（サブコマンド固有のフラグ。例: `create` の `-t`）は対象外のまま
# 安全側（非検知）に倒す — `gh pr -t merge create` のように「フラグ値がたまたまサブコマンド名
# と同じ」形を誤検知しないため（そもそも `-t` は `pr` 直下の有効フラグではなく、サブコマンドの
# 後でしか意味を持たない実行不能な形であり、真の `create` 呼び出しは `gh pr create -t merge`
# のように sub が pr に隣接するため既存ロジックで検知できる）。
#
# -R は pflag の shorthand flag のため、値を「区切りなしで連結」できる（実測: `gh pr -Ro/r
# view N` も成功 = `-R o/r` / `-R=o/r` と同じ意味）。当初 `-R[[:space:]]+…` / `-R=…` の
# 2 パターンのみだったため `gh pr -Ro/r merge N`（連結形）が非検知のまま残っていた
# （light レビューで実 gh バイナリに対して実測し発覚）。`-R[[:space:]]*[^[:space:]]+`
# 1 本に統合し、空白区切り・連結・`=` 区切りの 3 形を一括でカバーする（`=value` も
# `[^[:space:]]+` の一部として自然に飲み込まれる）。--repo は long flag のため連結形が
# 存在しない（実測: `gh pr --repoowner/repo` は `unknown flag` でエラー）。
_CM_GH_PR_FLAG_RE='-R[[:space:]]*[^[:space:]]+|--repo([[:space:]]+|=)[^[:space:]]+|--help'

# gh pr <sub> の実行を判定
# 引数: $1 = command, $2 = subcommand
# サブコマンドは allowlist で固定（ERE 注入対策、m-1）。
# {ISSUE-ID}: `gh pr <sub>` の隣接のみを要求していたため `gh pr -R o/r merge N` /
# `gh pr --repo o/r merge N` のようにサブコマンド前にフラグが挟まる形を検知できなかった
# （5 hook が共用する検知漏れ。`is_gh_pr_merge_command` 等のゲートを CLI から迂回できた）。
# `_CM_GH_PR_FLAG_RE` に一致するフラグ塊を 0 個以上許容してからサブコマンドに到達するかを
# 判定する（フラグの後ろ・前どちらの隣接パターンも同じ ERE でカバーする）。
_cm_has_gh_pr_subcommand() {
    local cmd="$1"
    local sub="$2"

    [ -z "$cmd" ] && return 1
    [ -z "$sub" ] && return 1

    # サブコマンド allowlist: 想定外の値が来た場合は false（ERE 注入回避）
    case "$sub" in
        create|comment|merge|view|list|edit|close|reopen|ready|review|diff|checkout|status|checks) ;;
        *) return 1 ;;
    esac

    _cm_segment_starts_with "$cmd" "gh[[:space:]]+pr[[:space:]]+((${_CM_GH_PR_FLAG_RE})[[:space:]]+)*${sub}"
}

is_gh_pr_create_command() {
    _cm_has_gh_pr_subcommand "$1" "create"
}

is_gh_pr_comment_command() {
    _cm_has_gh_pr_subcommand "$1" "comment"
}

is_gh_pr_merge_command() {
    _cm_has_gh_pr_subcommand "$1" "merge"
}

# review-verdict-post.sh（判定の機械導出 + 投稿・{ISSUE-ID} Phase 2）の実行を検知する。
# after-review hook が「レビュー結果コメント投稿」として /auto-merge チェーンに繋ぐための matcher。
# bash 前置あり/なし・任意のパス前置（repo 相対 / plugin cache 絶対 / 変数展開後の絶対パス）に対応。
# 引用符内・echo/grep 引数での出現はセグメント判定（_cm_segment_starts_with）が除外する。
# review-verdict-post.sh の「起動シグネチャ」で検知する。
#
# review.md「レビュー結果のコメント」の locator は locate 後に **変数実行** する:
#   REL="scripts/claude-hooks/review-verdict-post.sh"   # 代入（投稿前）
#   bash "$RVP" <PR#> --critical N --major N --tests ... # 実行本体
# 実行本体のコマンド文字列にはスクリプト名が現れないため、パス一致では検知できない。
# 逆に代入行はパス一致してしまう。結果、従来の実装は「代入行への誤マッチ」だけで発火し、
# 実行そのものは一度も検知していなかった（投稿前に /auto-merge を促す false positive と、
# 実行を取りこぼす false negative が表裏一体で同居）。
#
# そこでパスの表現方法（リテラル / 変数 / plugin cache の絶対パス）に依存しない
# **スクリプト固有のフラグ組**で同定する。判定に使う 3 つは review-verdict-post.sh の
# 必須引数であり、他のコマンドが同時に持つことはない。
_cm_has_verdict_post_signature() {
    local cmd="$1"
    [ -z "$cmd" ] && return 1

    local expanded
    expanded=$(_cm_expand_command_substitution "$cmd")
    local segmented
    segmented=$(_cm_segment_command "$expanded")

    while IFS= read -r seg; do
        local tokenized
        tokenized=$(_cm_tokenize_line "$seg")
        # 実行セグメントに限る。PR 番号は **裸の整数** で第 1 引数に来ることを要求し、
        # 解説・コミットメッセージ中の擬似コマンド（bash "$RVP" <PR#> --critical N …）を弾く
        # — heredoc / 引用符内の説明文もコマンド文字列としてセグメント化されるため
        #   （実観測: 本修正のコミットメッセージ本文が自身の検知を誤発火させた）。
        [[ "$tokenized" =~ ^bash[[:space:]]+[^[:space:]]+[[:space:]]+[0-9]+([[:space:]]|$) ]] || continue
        [[ "$tokenized" == *--critical* ]] || continue
        [[ "$tokenized" == *--major* ]] || continue
        [[ "$tokenized" == *--tests* ]] || continue
        return 0
    done <<< "$segmented"

    return 1
}

is_review_verdict_post_command() {
    # 形 1: リテラルパス実行。[^[:space:]=]* で代入（REL="…/review-verdict-post.sh"）を弾く
    #       — `=` を許すと [^[:space:]]* が `REL="scripts/claude-hooks/` を飲み込んで誤マッチする
    if _cm_segment_starts_with "$1" "(bash[[:space:]]+)?[^[:space:]=]*review-verdict-post\.sh"; then
        return 0
    fi
    # 形 2: 変数経由実行（review.md の正規テンプレ）。フラグ署名で同定する。
    #
    # 本関数は hook から **全 Bash 呼び出しごと** に呼ばれる。署名走査は
    # セグメント分割 + セグメント毎の awk 起動を伴い、形 1 の走査と合わせて
    # コストが 2 倍になる（実測: 120 行コマンドで 257ms → 506ms）。
    # --critical を含まないコマンド（＝ ほぼ全て）は O(n) の文字列一致で先に落とし、
    # 走査は候補だけに絞る。
    case "$1" in
        *--critical*) ;;
        *) return 1 ;;
    esac
    _cm_has_verdict_post_signature "$1"
}

# ============================================================
# B-2 追加修正: gh_pr_create_head_branch の堅牢化（--head 値抽出バイパス封鎖・{ISSUE-ID} P3）
# ============================================================
#
# セキュリティ修正（Critical・実機再現済み）: 旧実装は「実行コマンドとしての
# gh pr create 検知」用の _cm_strip_quoted（引用符の中身を丸ごと削除する関数）を
# 値抽出に転用していたため、以下 3 つのバイパスが成立していた:
#
#   1. 引用符バイパス: `--head "main"` / `--head 'main'`
#      → _cm_strip_quoted が "main" の中身ごと削除し `--head  --base ...` になり、
#        正規表現 --head[[:space:]]+([^[:space:]]+) が次トークン（--base 等）を
#        head 値と誤取得 → main と不一致 → CWD main でも通過してしまう
#   2. フォーク構文バイパス: `--head <owner>:main`（gh 公式の user:branch 構文）
#      → 抽出値 "owner:main" が "main" と文字列不一致で回避
#   3. 大文字バイパス: `--head MAIN` → "main" と大文字小文字不一致で回避
#
# 修正方針: _cm_strip_quoted に一切依存しない専用の quote-aware パーサを新設する。
#   - _cm_unwrap_subshells: $(...) / `...` の中身を独立セグメントとして展開する
#     （_cm_strip_quoted の前半 2 ステップのみを流用。引用符リテラルには触れない）
#   - _cm_segment_quote_aware: ; && || | & 改行 をセグメント区切りとして分割するが、
#     '...' / "..." の中にある区切り文字はセグメント境界として扱わない（quote-aware）。
#     これにより `--title "a;b" --head main` のような「引用符内に疑似デリミタを
#     仕込んで本物の --head を隣接セグメントへ追いやる」種類の取りこぼしを防ぐ
#     （引用符の中身を保持したまま分割するため、_cm_strip_quoted＋naive segment の
#     組み合わせで起きうる「セグメント境界のズレ」が構造的に発生しない）
#   - _cm_tokenize_quoted: 1 セグメントを空白区切りでトークン化する。'...' / "..."
#     で囲まれた区間は区切らず、囲む引用符のみを剥がして中身を保持する
#     （中身は削除しない・バイパス修正の核）。これにより:
#       * `--head "main"` → トークン ["--head","main"] を正しく分離
#       * `--title "--head feat/x"` → 引用符内はまるごと 1 トークンになるため
#         `--head` という独立トークンが現れず、偽の --head を誤認しない
#
# フォーク構文の defork・大文字小文字の正規化は値抽出そのものではなく判定側の
# 責務に分離した（cm_normalize_head_branch / cm_is_main_or_master_branch。後述）。
# gh_pr_create_head_branch 自体は従来どおり「生値をそのまま返す」契約を維持する
# （テスト契約: --head main（誤用値）もそのまま抽出し main/master 判定は呼び出し側）。
#
# 注: {ISSUE-ID}（引用符でサブコマンド自体 `gh "pr" create` を割るバイパス）は
#   is_gh_pr_create_command 側（実トークン化）が検知を担う。検知ゲートが素通りする
#   ケースは本関数の呼び出し自体に到達しない（本関数のセグメントマッチは
#   `^gh pr create` の素の語順のみを見る）。

# バッククォート / $(...) の中身を改行で囲んで展開する。
# 引用符リテラル（'...' / "..."）はここでは一切変更しない（中身を保持したまま
# _cm_segment_quote_aware に渡し、値抽出まで一貫して内容を保持するため）。
# {ISSUE-ID}/{ISSUE-ID} 統合: bash -c / sh -c ラップの中身も _cm_unwrap_shell_c で先に展開する。
# is_gh_pr_create_command（検知側）は _cm_expand_command_substitution 経由で
# `bash -c "gh pr create ..."` を検知するため、値抽出側だけ展開しないと
# 「検知はされるが --head が抽出できず CWD フォールバックに落ちる」非対称が生まれ、
# worktree CWD からの `bash -c 'gh pr create --head main'`（--head main 誤用）が
# 素通りしてしまう。検知側と同じ展開を適用して対称にする（fail-closed）。
_cm_unwrap_subshells() {
    # shellcheck disable=SC2016
    # ヒアドキュメント本体の除去を _cm_expand_command_substitution と
    # 同じ位置（bash -c 展開の後・$(...) / `...` 抽出の前）に揃える（対称性の維持）。
    _cm_unwrap_shell_c "$1" \
        | _cm_strip_heredoc_bodies \
        | sed -E 's/`([^`]*)`/\n\1\n/g' \
        | sed -E 's/\$\(([^)]*)\)/\n\1\n/g'
}

# 引用符を尊重してコマンドをセグメント分割する（--head 値抽出専用・quote-aware）。
# _cm_segment_command と異なり、'...' / "..." の中にある区切り文字
# （; && || | & 改行）はセグメント境界として扱わない。$(...) / `...` の展開は
# 呼び出し側で _cm_unwrap_subshells を先に適用しておく前提（責務分離）。
_cm_segment_quote_aware() {
    local s="$1"
    local -a segs=()
    local cur=""
    local i=0 len=${#s}
    local in_squote=0 in_dquote=0
    local ch next

    while [ "$i" -lt "$len" ]; do
        ch="${s:i:1}"

        if [ "$in_squote" = "1" ]; then
            cur+="$ch"
            [ "$ch" = "'" ] && in_squote=0
            i=$((i + 1))
            continue
        fi
        if [ "$in_dquote" = "1" ]; then
            cur+="$ch"
            [ "$ch" = '"' ] && in_dquote=0
            i=$((i + 1))
            continue
        fi

        case "$ch" in
            "'")
                in_squote=1
                cur+="$ch"
                ;;
            '"')
                in_dquote=1
                cur+="$ch"
                ;;
            ';')
                segs+=("$cur"); cur=""
                ;;
            $'\n')
                segs+=("$cur"); cur=""
                ;;
            '&')
                next="${s:i+1:1}"
                if [ "$next" = "&" ]; then
                    segs+=("$cur"); cur=""
                    i=$((i + 2))
                    continue
                fi
                segs+=("$cur"); cur=""
                ;;
            '|')
                next="${s:i+1:1}"
                if [ "$next" = "|" ]; then
                    segs+=("$cur"); cur=""
                    i=$((i + 2))
                    continue
                fi
                segs+=("$cur"); cur=""
                ;;
            *)
                cur+="$ch"
                ;;
        esac
        i=$((i + 1))
    done
    segs+=("$cur")

    local seg
    for seg in "${segs[@]}"; do
        printf '%s\n' "$seg"
    done
}

# 引用符を尊重して 1 セグメントをトークン分割する（--head 値抽出専用）。
# シングル/ダブルクォートで囲まれた区間は空白で分割せず、囲む引用符のみを除去して
# 中身を保持する（_cm_strip_quoted と異なり中身を削除しない・バイパス修正の核）。
# エスケープ文字・ネストした引用符の完全な shell 互換は目指さない
# （gh pr create の --head 値抽出という限定用途に十分な近似実装）。
_cm_tokenize_quoted() {
    local s="$1"
    local -a tokens=()
    local cur="" ch
    local in_squote=0 in_dquote=0 have_token=0
    local i=0 len=${#s}

    while [ "$i" -lt "$len" ]; do
        ch="${s:i:1}"
        if [ "$in_squote" = "1" ]; then
            if [ "$ch" = "'" ]; then
                in_squote=0
            else
                cur+="$ch"
            fi
            have_token=1
            i=$((i + 1))
            continue
        fi
        if [ "$in_dquote" = "1" ]; then
            if [ "$ch" = '"' ]; then
                in_dquote=0
            else
                cur+="$ch"
            fi
            have_token=1
            i=$((i + 1))
            continue
        fi
        case "$ch" in
            "'")
                in_squote=1
                have_token=1
                ;;
            '"')
                in_dquote=1
                have_token=1
                ;;
            [[:space:]])
                if [ "$have_token" = "1" ]; then
                    tokens+=("$cur")
                    cur=""
                    have_token=0
                fi
                ;;
            *)
                cur+="$ch"
                have_token=1
                ;;
        esac
        i=$((i + 1))
    done
    if [ "$have_token" = "1" ]; then
        tokens+=("$cur")
    fi

    local t
    for t in "${tokens[@]}"; do
        printf '%s\n' "$t"
    done
}

# 公開: `gh pr create` コマンドの --head 値を抽出する（B-2 / {ISSUE-ID} P3。堅牢化・B-2 追加修正）。
#
# 抽出対象: `--head <val>`（スペース区切り）/ `--head=<val>`（= 区切り）の両形式。
# `gh pr create` セグメントの中でのみ検索する（quote-aware セグメンテーション経由）。
#   - 引用符で囲まれた値（`--head "main"` / `--head 'main'`）は囲む引用符のみを
#     剥がして中身を保持する（中身削除はしない・引用符バイパスの修正）
#   - 引用符内の偽装（例: `gh pr create --title "--head feat/x"`）は 1 トークンに
#     まとまるため本物の --head として誤認しない
#   - 無関係なセグメントに現れる --head を拾わない
#     （例: `echo "--head foo" && gh pr create` のような別コマンドの引数）
#
# 複数 --head がある場合は**最後**の 1 つを採用する。見つからなければ空文字を返す。
#
# セキュリティ修正（Critical・{ISSUE-ID} P3 再レビュー）: `gh` は Cobra/pflag ベースの
# CLI であり、通常の文字列フラグは繰り返し指定すると**後段の値が前段を上書きする**
# （実機で `gh pr list --limit 5 --limit 1` の挙動から確認済み）。旧実装は最初に
# 見つかった --head を採用していたため、`--head <安全そうな値> --head main` のように
# 無害な --head を先頭に置いて実際の main 指定を後段に隠すバイパスが成立していた。
# 返値は生値のまま（フォーク構文の owner: プレフィックス・大文字小文字は未加工）。
# main/master 判定は cm_is_main_or_master_branch（正規化込み）を使うこと。
gh_pr_create_head_branch() {
    local cmd="$1"
    [ -z "$cmd" ] && { printf ''; return 0; }

    local unwrapped
    unwrapped=$(_cm_unwrap_subshells "$cmd")
    local segmented
    segmented=$(_cm_segment_quote_aware "$unwrapped")

    local seg trimmed found=0 found_val=""
    while IFS= read -r seg; do
        trimmed="${seg#"${seg%%[![:space:]]*}"}"
        [ -z "$trimmed" ] && continue
        if [[ "$trimmed" =~ ^gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$) ]]; then
            local -a tokens=()
            local tok
            while IFS= read -r tok; do
                tokens+=("$tok")
            done < <(_cm_tokenize_quoted "$trimmed")

            local idx n="${#tokens[@]}"
            for ((idx = 0; idx < n; idx++)); do
                if [ "${tokens[idx]}" = "--head" ]; then
                    if [ $((idx + 1)) -lt "$n" ]; then
                        found_val="${tokens[idx + 1]}"
                        found=1
                    fi
                elif [[ "${tokens[idx]}" == --head=* ]]; then
                    found_val="${tokens[idx]#--head=}"
                    found=1
                fi
            done
        fi
    done <<< "$segmented"

    if [ "$found" = "1" ]; then
        printf '%s' "$found_val"
        return 0
    fi

    printf ''
    return 0
}

# 公開: --head の生値を正規化する（B-2 追加修正・{ISSUE-ID} P3）。
#   - フォーク構文 <user>:<branch> はコロン以降（ブランチ部）を取り出す
#   - 小文字化する（bash 3.2 互換のため tr を使用。${var,,} は bash4+ 限定のため避ける）
cm_normalize_head_branch() {
    local raw="$1"
    local branch="$raw"
    case "$branch" in
        *:*) branch="${branch#*:}" ;;
    esac
    printf '%s' "$branch" | tr '[:upper:]' '[:lower:]'
}

# 公開: 正規化後の --head 値が main/master 相当か判定する（B-2 追加修正・{ISSUE-ID} P3）。
# `refs/heads/main` のような完全参照表記も考慮する。
cm_is_main_or_master_branch() {
    local normalized
    normalized=$(cm_normalize_head_branch "$1")
    case "$normalized" in
        main|master|refs/heads/main|refs/heads/master) return 0 ;;
        *) return 1 ;;
    esac
}

# git commit / git push の実行を判定
# pre-tool-use.sh の main ブロックが素の grep（クォート未対応）で判定していたため、
# git "commit" / git p"u"sh のようなクォート分割で回避できていた。
# is_gh_pr_* と同じ「コマンド置換展開 + クォート認識セグメント分割 + 実トークン化 +
# セグメント先頭アンカー」に統一する。
is_git_commit_command() {
    _cm_segment_starts_with "$1" "git[[:space:]]+commit"
}

is_git_push_command() {
    _cm_segment_starts_with "$1" "git[[:space:]]+push"
}

# git push によるリモートブランチ削除判定（--delete / -d）+ main/master 除外
# pre-tool-use.sh の「main/master の削除は引き続きブロックするが、feature ブランチの
# 削除は dev-flow 違反でないため許可する」例外ロジックを、トークン化済みセグメントに対して
# 判定する共通ヘルパーに集約する。生コマンド文字列に対する grep のままだと、
# git push が引用符分割されるケース（`git p"u"sh origin --delete feat/x`）で
# 削除例外・main/master 判定の対象セグメントが正しく拾えない。
#
# 引数: $1 = command
# 返値: 0 = 「git push で --delete/-d 付き、かつ対象が main/master ではない」と判定できるセグメントがある
#       1 = 該当なし（= 通常の push、または main/master 削除、または push 自体が存在しない）
is_git_push_delete_non_main_command() {
    local cmd="$1"
    [ -z "$cmd" ] && return 1

    local expanded
    expanded=$(_cm_expand_command_substitution "$cmd")
    local segmented
    segmented=$(_cm_segment_command "$expanded")

    while IFS= read -r seg; do
        local tokenized
        tokenized=$(_cm_tokenize_line "$seg")
        if [[ "$tokenized" =~ ^git[[:space:]]+push([[:space:]]|$) ]]; then
            if [[ "$tokenized" =~ (--delete|[[:space:]]-d([[:space:]]|$)) ]] \
                && ! [[ "$tokenized" =~ [[:space:]/](main|master)([[:space:]]|$) ]]; then
                return 0
            fi
        fi
    done <<< "$segmented"

    return 1
}

# bypass 判定専用のストリップ。
# _cm_strip_quoted は「実行される `gh pr create` / `git commit` 等を検知する」目的で
# $(...) / `...` の中身を温存するが、worktree bypass の判定では逆に
# **コマンド置換・バッククォートの中身を除去** する。
# 理由: $(...) / `...` 内の `cd` はサブシェルで実行され **親シェルの cwd を変えない** ため、
# 「正当な worktree 遷移」とみなしてはいけない（温存すると C-4 / C-5 のバイパスが通る）。
# クォートはここでも実トークン化する（{ISSUE-ID}: danger_re 側の引用符分割回避を防ぐため。
# 例: `git "commit" -m x ; cd .claude/worktrees/x` で danger_re が反応せず
#     バイパスが誤って true になっていた回帰を修正）。
_cm_strip_for_bypass() {
    local no_subst
    # shellcheck disable=SC2016  # backtick in sed pattern is literal, not bash expansion
    # ヒアドキュメント本体の除去を $(...) / `...` 削除の前に適用する。
    # 本体中の偽装テキスト（例: 「cd .claude/worktrees/x」という説明文）が
    # found_worktree_cd を誤って立てたり、本体中の説明文が danger_re に誤マッチして
    # バイパス判定を誤らせたりするのを防ぐ（main 保護の bypass 経路を強化する側の変更）。
    # unquoted ヒアドキュメント内に温存された $(...) / `...` は、このあとの sed で
    # 従来どおり削除される（サブシェル実行の cd は親 cwd を変えないため bypass 判定では
    # 見ない、という既存方針と矛盾しない）。
    no_subst=$(printf '%s' "$1" \
        | _cm_strip_heredoc_bodies \
        | sed -E 's/`[^`]*`//g' \
        | sed -E 's/\$\([^)]*\)//g')

    # クォート認識セグメント分割 → 各セグメントをトークン化。
    # 先にトークン化してからセグメント分割すると、クォート内のエスケープ済み区切り文字
    # （例: grep "a\|b" の `\|`）を保護できなくなる（{ISSUE-ID}。_cm_segment_starts_with と
    # 同じ順序に揃える）。
    local segmented
    segmented=$(_cm_segment_command "$no_subst")

    local result=()
    while IFS= read -r _seg; do
        result+=("$(_cm_tokenize_line "$_seg")")
    done <<< "$segmented"

    local IFS=$'\n'
    printf '%s' "${result[*]}"
}

# worktree への cd バイパス判定（{ISSUE-ID} セキュリティ修正・pre-tool-use.sh / -gh-pr-create.sh 共用）
#
# cd セグメントが worktree 配下に留まる移動か判定する（C-9 一般化・{ISSUE-ID}・敵対レビュー）。
# is_worktree_cd_bypass が worktree 遷移（found）を検出した後、後続の cd で worktrees の
# 外へ出ていないかを再評価するために使う。
#   留まる（return 0）: .claude/worktrees/ への cd（`..` なし）、または `..`/絶対/~/- を
#     含まない相対 cd（worktree 内で下るだけ）。
#   出る（return 1）: `..` パスセグメント / 絶対パスで worktrees 外 / `~` / `cd -`・オプション /
#     引数なし cd（= home）。いずれも worktrees 配下を保証できないため安全側でブロックへ。
_cm_cd_stays_in_worktree() {
    local _seg="$1"
    local _t="${_seg#cd}"
    _t="${_t#"${_t%%[![:space:]]*}"}"   # 先頭空白除去
    _t="${_t%%[[:space:]]*}"             # cd の第 1 トークン
    [ -z "$_t" ] && return 1                       # 引数なし = home
    [[ "$_t" == -* ]] && return 1                  # cd -/-P/-- 等（直前 dir・オプション）
    [[ "$_t" == *'$'* ]] && return 1               # $VAR/${VAR} 展開（$(...) は strip 済み）→ 配下を静的保証できない
    [[ "$_t" =~ (^|/)\.\.(/|$) ]] && return 1      # .. パスセグメント
    [[ "$_t" =~ \.claude/worktrees/ ]] && return 0 # 別 worktree（.. は上で除外済み）
    [[ "$_t" == /* ]] && return 1                  # 絶対パスで worktrees 外
    [[ "$_t" == "~"* ]] && return 1                # ~ 始まり = home 方面
    return 0                                        # .. なしの相対パス（worktree 内で下る）
}

# セグメントが cwd を変えうるか（保守判定・{ISSUE-ID} 敵対レビュー3巡）。
# cd/pushd/popd/eval/exec/source を（`\cd`・command/builtin/env/`VAR=` 前置経由も含めて）
# トークンとして含むなら true。肯定列挙の取りこぼしを避けるため cd 系を広く拾う。
_cm_seg_may_change_cwd() {
    local _s="$1"
    # CDPATH 設定は後続の裸相対 cd（cd core）の解決先を worktrees 外（CDPATH 配下）へ変えうる
    # （Codex 二次レビュー・{ISSUE-ID}）。コマンド列内の CDPATH 設定を cwd 変更扱いにして found を
    # 降ろす（環境側で export 済みの CDPATH はコマンド列に現れず既知制約）。
    [[ "$_s" =~ (^|[[:space:]])CDPATH= ]] && return 0
    [[ "$_s" =~ (^|[[:space:]])(export|declare|typeset)[[:space:]] ]] && [[ "$_s" == *CDPATH* ]] && return 0
    # 誤爆防止（{ISSUE-ID} 敵対4巡目 Major）: セグメント全体でトークン走査すると、無害コマンドの
    # 引数（`grep -rn cd` / `rg eval` / `git add . -v` / `echo "...cd..."`）を cwd 変更と
    # 誤認する。前置修飾子（VAR= / command / builtin / env / nohup / time / `\`）を剥がした
    # 「第 1 実コマンドトークン」だけを cd/pushd/popd/eval/exec/source/`.` と照合する。
    local -a _toks
    read -ra _toks <<< "$_s"
    local i=0 _tok
    while [ "$i" -lt "${#_toks[@]}" ]; do
        _tok="${_toks[$i]}"
        # 代入プレフィックス VAR=val（= の前が identifier なら代入。値に `/` を含んでも代入。
        # Codex 二次レビュー: 旧 `!= */*` は `X=/tmp` を代入と認識できず後続 cd を見逃していた）
        if [[ "$_tok" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then i=$((i+1)); continue; fi
        # コマンド前置修飾子はスキップ
        case "$_tok" in
            command|builtin|env|nohup|time) i=$((i+1)); continue ;;
        esac
        # `\` エスケープ（\cd 等）を剥がして第 1 実コマンドを判定
        _tok="${_tok#\\}"
        case "$_tok" in
            cd|pushd|popd|eval|exec|source|.) return 0 ;;
        esac
        return 1
    done
    return 1
}

# セグメントが「worktree 内滞在を静的保証できる素直な cd」か。
# 先頭が literal cd（プレフィックスなし）かつ _cm_cd_stays_in_worktree が true のときのみ true。
_cm_seg_is_safe_worktree_cd() {
    local _s="$1"
    [[ "$_s" =~ ^cd([[:space:]]|$) ]] || return 1
    _cm_cd_stays_in_worktree "$_s"
}

# 「コマンド本体として cd <path>.claude/worktrees/... が危険コマンドより前にあるか」を判定する。
# コマンド置換・バッククォート・引用符を _cm_strip_for_bypass で除去した後にセグメント分割し、
#   1. cd .claude/worktrees/ セグメントが見つかるより前に危険コマンドが現れていない
#   2. cd .claude/worktrees/ セグメント自体が存在する
# 両方を満たす場合のみ true（バイパス可）。
#
# Args:
#   $1 = command
#   $2 = 危険コマンドの ERE（省略時は git commit/push。-C <path>/-C=<path> 経由の
#        commit/push も含む。-gh-pr-create.sh は gh pr create を渡す）
#
# 判定 true（exit 0）= バイパス可（正当な worktree 遷移）:
#   cd .claude/worktrees/foo && git commit -m x
#   cd /repo/.claude/worktrees/foo && git push origin feat/bar
#
# 判定 false（exit 1）= バイパス不可（ブロック対象）:
#   echo "cd .claude/worktrees/x" && git commit -m x          （C-1: 引用符内）
#   git -C /repo/.claude/worktrees/foo status && git commit   （C-2: -C は後段に効かない）
#   git commit -m x ; cd .claude/worktrees/foo                （C-3: commit が先）
#   echo $(cd .claude/worktrees/x) && git commit -m x         （C-4: コマンド置換 — 親 cwd 不変）
#   true `cd .claude/worktrees/x` && git commit -m x          （C-5: バッククォート — 親 cwd 不変）
#   git "commit" -m x ; cd .claude/worktrees/foo               （C-6: 引用符分割・{ISSUE-ID}）
#   git -C /repo commit -m x ; cd .claude/worktrees/foo       （C-3 の -C 版: -C で main に commit
#                                                                した後 cd しても不可・B-1・{ISSUE-ID} P3）
#   cd .claude/worktrees/foo && git -C /repo commit -m x      （C-7: worktree へ cd した後でも
#                                                                後段の -C が当該コマンド単体の
#                                                                対象を main へ上書きするなら不可・
#                                                                B-1 追加修正・{ISSUE-ID} P3）
#
# 返値: 0 = バイパス可、1 = バイパス不可
is_worktree_cd_bypass() {
    local cmd="$1"
    # デフォルトの危険コマンド ERE: 素の `git commit`/`git push` に加え、
    # `git -C <path> commit`/`git -C <path> push`（-C=<path> 形式も含む）も検知する。
    # 検知しないと「-C で main に commit → その後 worktree へ cd」が是のバイパス扱いに
    # なってしまう（C-3 の -C 版・穴の封鎖・B-1・{ISSUE-ID} P3）。
    # `-C` グループは `*`（0 回以上）で繰り返しを許容する（Critical・{ISSUE-ID} P3 再レビュー）:
    # `?`（0 or 1）のままだと `git -C a -C b commit` のような stacked -C セグメントが
    # 「danger command」として認識されず、この関数自体の検知から漏れてしまっていた。
    local danger_re="${2:-^git([[:space:]]+-C(=[^[:space:]]+|[[:space:]]+[^[:space:]]+))*[[:space:]]+(commit|push)}"
    local _depth="${3:-0}"
    [ -z "$cmd" ] && return 1

    # C-8: `bash -c '<script>'` ラップは <script> が実行本体なのに、下の
    # 引用符除去で cd セグメントが不可視になり、worktree 内の正当な commit/push が
    # 誤ブロックされていた（P6 クリーンラン レポート 2）。
    # **全体が単一の bash|sh|zsh -c 呼び出し**で、スクリプトが単純クォート（内部に
    # 同種クォートを含まない）かつ閉じクォート後が空白のみの場合に限り、1 段 unwrap
    # して同じ判定を再帰適用する（深さ 2 まで）。条件を外れる形（後続コマンドあり・
    # エスケープ入り等）は unwrap せず従来の保守的解析（= ブロック側）に倒す。
    # C-1（echo "cd ..." 偽装）は再帰先の引用符除去で引き続き防がれ、C-6/-C 上書きも
    # 再帰先の同一ロジックが効く（テスト: test-command-match.sh の C-8 ブロック）。
    if [ "$_depth" -lt 2 ] && \
       [[ "$cmd" =~ ^[[:space:]]*(bash|sh|zsh)([[:space:]]+-[[:alnum:]]+)*[[:space:]]+-[[:alnum:]]*c[[:alnum:]]*[[:space:]]+ ]]; then
        local _prefix="${BASH_REMATCH[0]}"
        local _rest="${cmd:${#_prefix}}"
        local _q="${_rest:0:1}"
        if [ "$_q" = "'" ] || [ "$_q" = '"' ]; then
            local _body="${_rest:1}"
            local _inner="${_body%%["$_q"]*}"
            if [ "$_inner" != "$_body" ]; then
                local _after="${_body:$((${#_inner}+1))}"
                if [[ "$_after" =~ ^[[:space:]]*$ ]]; then
                    is_worktree_cd_bypass "$_inner" "$danger_re" "$((_depth+1))"
                    return $?
                fi
            fi
        fi
    fi

    # _cm_strip_for_bypass は既にクォート認識セグメント分割 + トークン化済みの
    # 改行区切り文字列を返すため、ここで再度セグメント分割する必要はない
    # （二重分割を避ける・{ISSUE-ID} でセグメント分割の責務を _cm_strip_for_bypass に集約）。
    local segmented
    segmented=$(_cm_strip_for_bypass "$cmd")

    local found_worktree_cd=0
    while IFS= read -r _seg; do
        # 先頭の空白を除去
        _seg="${_seg#"${_seg%%[![:space:]]*}"}"
        [ -z "$_seg" ] && continue

        if [ "$found_worktree_cd" = "1" ]; then
            # worktree へ cd した後のセグメント（C-7・セキュリティ修正・Critical・
            # {ISSUE-ID} P3 再レビュー）: ambient cwd は worktree のはずだが、当該セグメント
            # 自身が明示的に -C <path> を指定していれば、その -C は cd の効果を上書きして
            # コマンド単体の対象を変える。-C の解決先が main/master ならバイパス不可に倒す
            # （-C 指定が無い、または worktree を指す場合は従来どおり ambient cd に従い安全）。
            if [[ "$_seg" =~ $danger_re ]]; then
                local _dir
                _dir=$(_cm_extract_dash_c_path "$_seg")
                if [ -n "$_dir" ]; then
                    local _branch
                    _branch=$(resolve_target_branch "$_seg")
                    if [ "$_branch" = "main" ] || [ "$_branch" = "master" ]; then
                        return 1
                    fi
                fi
                continue
            fi
            # C-9 一般化（保守デフォルト・{ISSUE-ID} 敵対レビュー3巡）: worktree 遷移後に cwd を
            # 変えうるセグメントは、worktree 内滞在が静的保証できる素直な cd 以外すべて found を
            # 降ろす（肯定列挙の取りこぼしを避ける deny-by-default）。cwd を変えうる形＝
            # cd/pushd/popd/eval/exec/source をトークンとして含む（`\cd`・command/builtin/env/
            # `VAR=` 前置経由も含む）。cwd を変えない無害なコマンド（echo/git status 等）は維持。
            # 静的にコマンド解釈を完全網羅はできない（関数定義経由 cd 等）ため、既知の cwd 変更
            # 経路を広く塞ぐ「事故防止ガード」と位置づける（{ISSUE-ID} 既知制約・PR 本文に明記）。
            if _cm_seg_may_change_cwd "$_seg" && ! _cm_seg_is_safe_worktree_cd "$_seg"; then
                found_worktree_cd=0
            fi
            continue
        fi

        # cd .claude/worktrees/ セグメントを検出
        if [[ "$_seg" =~ ^cd[[:space:]]+[^[:space:]]*\.claude/worktrees/ ]]; then
            # C-9: worktrees 配下に留まる cd のみを worktree 遷移と認める。
            # `..` トラバーサル・変数展開（$VAR）で外へ抜けうるパスは found を立てず、
            # 後続の危険コマンドをブロック側へ倒す。判定は found 後の後続 cd 再評価と
            # 共通化（_cm_cd_stays_in_worktree）。正当な worktree パスは `..`/`$` を
            # 含まないため過剰ブロックにならない（安全側の保守判定）。
            if _cm_cd_stays_in_worktree "$_seg"; then
                found_worktree_cd=1
            fi
            continue
        fi
        # cd .claude/worktrees/ より先に危険コマンドが現れたらバイパス不可
        if [[ "$_seg" =~ $danger_re ]]; then
            return 1
        fi
    done <<< "$segmented"

    [ "$found_worktree_cd" = "1" ] && return 0
    return 1
}

# ============================================================
# B-1: git -C <path> の対象ブランチを実解決して判定（{ISSUE-ID} P3）
# ============================================================
#
# 背景（セキュリティ・重要）: 旧実装は「CWD の実ブランチ」のみで main 判定していたため、
#   `git -C <path> commit` は pre-tool-use.sh の `grep -qE '(^|[;&|]\s*)git commit'` に
#   マッチせず素通りしていた。これは worktree の誤ブロック（`git -C <worktree> commit` が
#   本来通過すべきなのに `-C` を認識できず判定不能だった）だけでなく、
#   main repo に対する `git -C /repo commit` も main ブロックを迂回できる穴になっていた。
#   本セクションはコマンド中の `git -C <path>` を実解決し、両方を同時に修正する。

# git rev-parse --abbrev-ref HEAD の実行ラッパー（間接層）。
# 本番では常に実 git を呼ぶ。dir が空文字なら CWD、非空なら `git -C <dir>` で解決する。
# 失敗時（存在しないパス・network 等）は "unknown" を返す（fail-open。呼び出し側は
# "unknown" を main/master と一致させないため、対象パスの実体が無ければ実害も無い
# ＝そのパスへの実 commit/push 自体も同じ理由で失敗する）。
# テストでは同名関数を source 後に再定義（関数差し替え）することで stub 可能
# （本番挙動には影響しない・純粋な間接呼び出しのみ）。
_cm_git_rev_parse_branch() {
    local dir="$1"
    if [ -n "$dir" ]; then
        git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown"
    else
        git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown"
    fi
}

# コマンド文字列（1 セグメント想定）から git グローバルオプションとしての
# `-C <path>` / `-C=<path>`（**git とサブコマンドの間**にあるもの）を解決し、
# 最終的な対象ディレクトリを返す。
#
# セキュリティ修正（Critical / {ISSUE-ID} P3 レビュー指摘）: 旧実装はセグメント全体から
# 無条件に `-C` を抽出していたため、`git commit -C HEAD -m x`（`--reuse-message` の
# 短縮形。`git commit --amend -C HEAD` は一般的な操作）の `HEAD` を対象パスと誤認し、
# `git -C HEAD rev-parse` が失敗 → fail-open で "unknown" → main 不一致 → main ブロックが
# 素通りする穴になっていた（旧実装 d919ff07 は `git commit -C HEAD` を main コミットとして
# 正しくブロックしていたため、この誤認識は退行だった）。
# `cm_git_danger_targets_main` の位置アンカー正規表現
# （`^git([[:space:]]+-C(...))?[[:space:]]+${kind}`）と同じ「git 直後のみ」の
# セマンティクスに統一する。`git commit -C HEAD` のようなサブコマンド側フラグの
# `-C` は対象 dir 変更として扱わない（＝ CWD ブランチで判定する）。
#
# セキュリティ修正（Critical・{ISSUE-ID} P3 再レビュー）: 旧実装は「複数 -C がある場合は
# 最初の 1 つを採用する」としていたが、実 git は逆に **後段の -C が前段の結果を合成・
# 上書きする**（絶対パスの -C はそれまでの結果を丸ごと置き換え、相対パスの -C は
# 直前までの結果に連結される。実機で検証済み）。そのため
# `git -C .claude/worktrees/feat-x -C /repo commit` のように、見せかけの worktree
# パスを先頭に置いて本当の対象（main 等の絶対パス）を後段の -C に隠すバイパスが
# 成立していた。本実装は git 直後から連続する -C を全て消費し、実 git と同じ規則で
# 最終ディレクトリを合成する。
_cm_extract_dash_c_path() {
    local seg="$1"
    local rest
    if [[ "$seg" =~ ^git[[:space:]]+(.*)$ ]]; then
        rest="${BASH_REMATCH[1]}"
    else
        printf ''
        return 0
    fi

    local resolved="" val matched=1
    while [ "$matched" = "1" ]; do
        matched=0
        if [[ "$rest" =~ ^-C=([^[:space:]]+)[[:space:]]*(.*)$ ]]; then
            val="${BASH_REMATCH[1]}"
            rest="${BASH_REMATCH[2]}"
            matched=1
        elif [[ "$rest" =~ ^-C[[:space:]]+([^[:space:]]+)[[:space:]]*(.*)$ ]]; then
            val="${BASH_REMATCH[1]}"
            rest="${BASH_REMATCH[2]}"
            matched=1
        fi
        if [ "$matched" = "1" ]; then
            case "$val" in
                /*) resolved="$val" ;;
                *) if [ -z "$resolved" ]; then resolved="$val"; else resolved="$resolved/$val"; fi ;;
            esac
        fi
    done

    printf '%s' "$resolved"
}

# 公開: コマンド（1 セグメント想定）の対象ブランチを解決する（B-1 / {ISSUE-ID} P3）。
# `git -C <path>`（git とサブコマンドの間のグローバルオプションのみ。位置アンカーの
# 詳細は _cm_extract_dash_c_path 参照）があればそのディレクトリの実ブランチ、
# 無ければ CWD の実ブランチを返す。`git commit -C HEAD` のようなサブコマンド側の
# `-C` は対象 dir とみなさない（Critical 修正・{ISSUE-ID} P3 レビュー指摘）。
# 複数 -C が連続する場合は実 git と同じ規則（絶対パスは上書き・相対パスは連結）で
# 合成した最終ディレクトリを使う。複合コマンド（`;` / `&&` 等をまたぐ）全体を渡した
# 場合は先頭セグメントの -C 列のみを見る（複合コマンドを厳密に判定したい場合は
# cm_git_danger_targets_main のようにセグメント単位で呼ぶこと）。
resolve_target_branch() {
    local cmd="$1"
    local dir
    dir=$(_cm_extract_dash_c_path "$cmd")
    _cm_git_rev_parse_branch "$dir"
}

# 公開: コマンド中に「対象ブランチが main/master の git commit/push」セグメントが
# 含まれるか判定する（-C 対応・B-1 / {ISSUE-ID} P3）。
# セグメント単位に走査し、各セグメント自身の -C <path>（無ければ CWD）で対象ブランチを
# 解決するため、複合コマンド（例: `git -C <worktree> status && git -C <main> commit`）でも
# セグメントごとに正しい対象を判定できる。
#
# セキュリティ修正（Important / {ISSUE-ID} P3 レビュー指摘 + {ISSUE-ID} 統合時に再構成）:
# 生の cmd をそのまま _cm_segment_command に渡すと、
# `git commit -m "not real; git push origin main"` のような**引用符内の `; git push`**
# を誤ってセグメント分割・検知し、main 上で無関係なコマンドを過剰ブロックしてしまう。
# {ISSUE-ID} 統合後は _cm_segment_starts_with と同じ
# 「コマンド置換 + bash -c 展開 → クォート認識セグメント分割 → 各セグメント実トークン化」
# パイプラインで処理する（クォート内の区切り文字はセグメント境界にならず、
# `git "commit"` のような引用符分割サブコマンドもトークン化で復元されて検知される。
# 旧 _cm_strip_quoted → _cm_segment_command の二段呼び出しは {ISSUE-ID} 以降
# _cm_strip_quoted 自体がトークン化済み出力を返すため、再分割すると引用符由来の
# `;` が露出して上記の過剰ブロックが再発する。この順序を変えてはならない）。
#
# セキュリティ修正（Minor / {ISSUE-ID} P3 レビュー指摘）: `-C <path>` 指定があるのに
# 実ブランチが解決できない（_cm_git_rev_parse_branch が fail-open で "unknown" を返す）
# 場合は fail-closed（ブロック側）に倒す。「パスが存在しないだけなら実 commit/push
# 自体も同じ理由で失敗するため実害がない」という従来の fail-open 根拠は、
# 「パスは存在するが rev-parse だけが失敗する」ケース（例: commit 0 件の unborn branch
# ＝ `git rev-parse --abbrev-ref HEAD` は失敗するが `git commit` 自体は成立し main へ
# 記録されてしまう）には当てはまらないため。
# ただし worktree らしきパス（`*worktrees*`）は既存の worktree バイパス挙動
# （実体の無いテスト用パスも含め fail-open で通過させる）を壊さないため対象外とする
# （CWD 側 = -C 無し の fail-open は別の理由で維持している既存挙動でありそもそも対象外。
#  _cm_git_rev_parse_branch のコメント参照）。
#
# セキュリティ修正（Critical・{ISSUE-ID} P3 再レビュー）: 「danger command か」を判定する
# 位置アンカー正規表現も `-C` グループを `*`（0 回以上）で繰り返し許容する。`?`（0 or 1）
# のままだと `git -C a -C /main commit` のような stacked -C セグメントがそもそも
# 「commit/push コマンドである」と認識されず、_cm_extract_dash_c_path 側の stacked -C
# 対応（後述）を実装しても本関数の呼び出しに到達しない穴が残っていた。
#
# 引数: $1 = command 全体, $2 = "commit" | "push"
# 返値: 0 = main/master を対象にした該当セグメントが見つかった, 1 = 見つからない
cm_git_danger_targets_main() {
    local cmd="$1" kind="$2"
    [ -z "$cmd" ] && return 1

    local expanded
    expanded=$(_cm_expand_command_substitution "$cmd")
    local segmented
    segmented=$(_cm_segment_command "$expanded")

    local seg
    while IFS= read -r seg; do
        seg=$(_cm_tokenize_line "$seg")
        seg="${seg#"${seg%%[![:space:]]*}"}"
        [ -z "$seg" ] && continue
        if [[ "$seg" =~ ^git([[:space:]]+-C(=[^[:space:]]+|[[:space:]]+[^[:space:]]+))*[[:space:]]+${kind}([[:space:]]|$) ]]; then
            local dir branch
            dir=$(_cm_extract_dash_c_path "$seg")
            branch=$(resolve_target_branch "$seg")
            if [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
                return 0
            fi
            if [ -n "$dir" ] && [ "$branch" = "unknown" ]; then
                case "$dir" in
                    *worktrees*) : ;; # worktree らしきパスは既存の fail-open 挙動を維持
                    *) return 0 ;;    # fail-closed: -C 指定ありなのに実ブランチ解決不能（Minor）
                esac
            fi
        fi
    done <<< "$segmented"

    return 1
}