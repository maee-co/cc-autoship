#!/usr/bin/env bash
# コマンドが操作する「実リポジトリ」を解決する純関数群。
#
# 背景:
#   pre-tool-use.sh / pre-tool-use-gh-pr-create.sh の main 保護は core の git HEAD
#   （= hook 実行 cwd の HEAD）だけを見て判定しており、コマンド内の
#   `cd <別repo>` / `git -C <path>` / `gh --repo <owner>/<repo>` を解釈しなかった。
#   このため cc-autoship 等の外部リポジトリでのフィーチャーブランチ作業が
#   core の main 直コミットと誤判定されてブロックされていた。
#
# 方針（fail-closed）:
#   「コマンド内のすべての危険コマンドが、確実に core 以外のリポジトリを対象に
#   実行される」と判定できた場合のみ true（= main 保護をスキップしてよい）。
#   パスが解決できない・git repo でない・core とその worktree・判定不能な混在は
#   すべて false（= 現行どおりブロック）。セキュリティ用途の hook なので
#   fail-open にしない。
#
# バイパス防止（{ISSUE-ID} の C-1〜C-5 と同じ考え方）:
#   - 引用符リテラル（"..." / '...'）内の `cd <path>` は遷移ではない → 除去
#   - コマンド置換（$(...) / `...`）内の `cd` は親シェルの cwd を変えない → 除去
#   - `git -C <path>` はそのコマンドにのみ有効で後段には効かない → セグメント単位で判定
#   - 危険コマンドが cd より前にあれば cwd（= core）で実行される → false
#
# Known limitations（すべて fail-closed 側に倒れる = ブロック維持）:
#   - 引用符で囲んだパス（cd "/path with spaces/repo"）は解決不能 → ブロック維持
#   - 変数展開（cd $DIR）・チルダ（cd ~/x）・cd - は解決不能 → ブロック維持
#   - コマンド置換内の commit/push（X=$(cd /ext && git push)）は検知対象外 →
#     呼び出し側の既存検知（grep / command-match）がブロック維持
#   - サブシェル / グループ化（( ... ) / { ... }）を含むコマンドは cwd 追跡を線形に
#     モデル化できないため一律ブロック維持（下の括弧ガード参照）
#   - ヒアドキュメント（<<EOF ... EOF）の中身は引用符として扱わず行単位でセグメント化
#     される（command-match.sh と同じ制限）。誤判定は fail-closed 側にのみ倒れる
#
# 公開関数:
#   command_targets_only_external_repo <command> <core_root> [danger_re]
#
# 返値: 0 = すべての危険コマンドが外部リポジトリ対象（main 保護スキップ可）
#       1 = それ以外（判定不能を含む。main 保護は現行どおり発火）

# 引用符リテラル・コマンド置換を除去する（bypass 判定と同じ方向のストリップ）。
# コマンド置換の中身は「親シェルの cwd に影響しない」ため温存せず削除する。
_rt_strip_for_target() {
    # shellcheck disable=SC2016  # sed パターン内のバッククォートはリテラル
    printf '%s' "$1" \
        | sed -E 's/`[^`]*`//g' \
        | sed -E 's/\$\([^)]*\)//g' \
        | sed -E 's/"[^"]*"//g' \
        | sed -E "s/'[^']*'//g"
}

# コマンドを実行セグメントに分割（;, &&, ||, |, &, 改行 で区切る）
_rt_segment_command() {
    local cmd="$1"
    cmd="${cmd//&&/$'\n'}"
    cmd="${cmd//||/$'\n'}"
    cmd="${cmd//;/$'\n'}"
    cmd="${cmd//|/$'\n'}"
    cmd="${cmd//&/$'\n'}"
    printf '%s' "$cmd"
}

# ディレクトリが属する git repo の toplevel を返す（repo でなければ失敗）
_rt_repo_toplevel() {
    local dir="$1"
    [ -n "$dir" ] || return 1
    [ -d "$dir" ] || return 1
    git -C "$dir" rev-parse --show-toplevel 2>/dev/null
}

# ディレクトリが「core（またはその worktree）以外の git repo」であるか判定する。
# 判定不能（存在しない・git repo でない・core_root 空）はすべて false（fail-closed）。
# Args: $1 = 検査するディレクトリ, $2 = core の toplevel
_rt_dir_is_external_repo() {
    local dir="$1"
    local core_root="$2"
    [ -n "$core_root" ] || return 1

    local top
    top=$(_rt_repo_toplevel "$dir") || return 1
    [ -n "$top" ] || return 1

    # core 自身
    [ "$top" = "$core_root" ] && return 1
    # core 配下（.claude/worktrees/ を含む）
    case "$top" in
        "$core_root"/*) return 1 ;;
    esac
    # core に属する worktree（core_root 外に置かれた worktree も含めて確認）
    if git -C "$core_root" worktree list --porcelain 2>/dev/null \
        | grep -qx "worktree $top"; then
        return 1
    fi
    return 0
}

# GitHub リポジトリ指定を owner/repo に正規化する。
# 対応形式: owner/repo / HOST/owner/repo / https://HOST/owner/repo(.git) /
#           git@HOST:owner/repo(.git) / ssh://git@HOST/owner/repo(.git)
_rt_normalize_slug() {
    local s="$1"
    s="${s%/}"
    s="${s%.git}"
    s="${s#*://}"    # https:// / ssh:// を除去
    s="${s#git@}"    # git@HOST:owner/repo → HOST:owner/repo
    s="${s/:/\/}"    # 最初の : を / に（HOST:owner/repo → HOST/owner/repo）

    # 3 コンポーネント以上なら末尾 2 つ（HOST/owner/repo → owner/repo）
    local IFS=/
    local parts=()
    read -ra parts <<< "$s"
    local n=${#parts[@]}
    if [ "$n" -ge 2 ]; then
        printf '%s/%s' "${parts[$((n - 2))]}" "${parts[$((n - 1))]}"
    else
        printf '%s' "$s"
    fi
}

# core の origin remote から owner/repo slug を返す（解決不能なら失敗）
_rt_core_repo_slug() {
    local core_root="$1"
    [ -n "$core_root" ] || return 1
    local url
    url=$(git -C "$core_root" remote get-url origin 2>/dev/null) || return 1
    [ -n "$url" ] || return 1
    _rt_normalize_slug "$url"
}

# セグメントから gh の明示リポジトリ指定（--repo <slug> / --repo=<slug> / -R <slug>）を
# 抽出する。見つからなければ失敗。
_rt_gh_explicit_repo_slug() {
    local seg="$1"
    local toks=()
    read -ra toks <<< "$seg"
    local i
    local n=${#toks[@]}
    for ((i = 0; i < n; i++)); do
        case "${toks[$i]}" in
            --repo|-R)
                if [ $((i + 1)) -lt "$n" ]; then
                    printf '%s' "${toks[$((i + 1))]}"
                    return 0
                fi
                return 1
                ;;
            --repo=*)
                printf '%s' "${toks[$i]#--repo=}"
                return 0
                ;;
        esac
    done
    return 1
}

# 小文字化（bash 3.2 互換のため ${var,,} は使わない）
_rt_lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# 公開: コマンド内のすべての危険コマンドが「core 以外のリポジトリ」を対象に実行されると
# 確実に判定できる場合のみ 0 を返す（main 保護スキップ可）。
#
# Args:
#   $1 = command
#   $2 = core の toplevel（呼び出し側で git rev-parse --show-toplevel 済み）
#   $3 = 危険コマンドの ERE（省略時は git commit/push）。
#        pre-tool-use-gh-pr-create.sh は '^gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)' を渡す。
#
# 判定 0（スキップ可）の例:
#   cd /path/to/cc-autoship && git push origin feat/x
#   git -C /path/to/cc-autoship commit -m x
#   gh pr create --repo owner/other-repo --title x        （danger_re が gh の場合）
#
# 判定 1（保護継続）の例:
#   git push origin feat/x                        （cwd = core）
#   cd /nonexistent && git push origin feat/x     （解決不能 → fail-closed）
#   echo "cd /ext/repo" && git commit -m x        （引用符内は遷移ではない）
#   git commit -m x ; cd /ext/repo                （commit が core cwd で先に実行される）
#   cd /ext/repo && git commit && cd <core> && git push   （core 対象が混在）
command_targets_only_external_repo() {
    local cmd="$1"
    local core_root="$2"
    local danger_re="${3:-^git[[:space:]]+(commit|push)([[:space:]]|$)}"

    [ -n "$cmd" ] || return 1
    [ -n "$core_root" ] || return 1

    local stripped
    stripped=$(_rt_strip_for_target "$cmd")

    # サブシェル・グループ化を含むコマンドは判定不能として fail-closed に倒す。
    # `cd /ext && (cd /core && git push)` のようにサブシェル内の cd は線形の cwd 追跡を
    # すり抜け、実際には core で push が走るのに外部対象と誤判定されうる（brace group も同様）。
    # $(...) / `...` は _rt_strip_for_target で除去済みのため、ここに残る括弧は
    # サブシェル・関数定義・ブレース展開・ネストしたコマンド置換の残骸のみ → すべてブロック維持。
    case "$stripped" in
        *'('* | *')'* | *'{'* | *'}'*)
            return 1
            ;;
    esac

    local segmented
    segmented=$(_rt_segment_command "$stripped")

    local re_cd='^cd([[:space:]]+|$)'
    local re_git_c='^git[[:space:]]+-C[[:space:]]+([^[:space:]]+)[[:space:]]+(.*)$'
    local re_gh='^gh[[:space:]]'

    local cur_dir="$PWD"
    local cur_known=1    # 現在の cwd 追跡が解決できているか（0 = 解決不能）
    local found_danger=0

    local _seg
    while IFS= read -r _seg; do
        # 先頭・末尾の空白を除去
        _seg="${_seg#"${_seg%%[![:space:]]*}"}"
        _seg="${_seg%"${_seg##*[![:space:]]}"}"
        [ -z "$_seg" ] && continue

        # --- cd <path>: 以降のセグメントの実行ディレクトリを更新 ---
        if [[ "$_seg" =~ $re_cd ]]; then
            local rest="${_seg#cd}"
            rest="${rest#"${rest%%[![:space:]]*}"}"
            if [ -z "$rest" ] || [[ "$rest" == -* ]] || [[ "$rest" == "~"* ]] \
                || [[ "$rest" == *'$'* ]] || [[ "$rest" == *[[:space:]]* ]]; then
                # cd 単独（$HOME）/ cd - / チルダ / 変数展開 / 複数引数は解決不能 → fail-closed
                cur_known=0
            elif [[ "$rest" == /* ]]; then
                cur_dir="$rest"
                cur_known=1
            elif [ "$cur_known" = "1" ]; then
                cur_dir="$cur_dir/$rest"
            fi
            continue
        fi

        # --- git -C <path> <sub>: -C はこの git コマンドにのみ有効 ---
        if [[ "$_seg" =~ $re_git_c ]]; then
            local c_path="${BASH_REMATCH[1]}"
            local git_rest="git ${BASH_REMATCH[2]}"
            if [[ "$git_rest" =~ $danger_re ]]; then
                found_danger=1
                local target
                if [[ "$c_path" == /* ]]; then
                    target="$c_path"
                elif [ "$cur_known" = "1" ]; then
                    target="$cur_dir/$c_path"
                else
                    return 1
                fi
                _rt_dir_is_external_repo "$target" "$core_root" || return 1
            fi
            continue
        fi

        # --- 危険コマンド（cwd で実行される）---
        if [[ "$_seg" =~ $danger_re ]]; then
            found_danger=1

            # gh コマンドは --repo / -R の明示指定を優先して判定する
            if [[ "$_seg" =~ $re_gh ]]; then
                local slug
                if slug=$(_rt_gh_explicit_repo_slug "$_seg") && [ -n "$slug" ]; then
                    local core_slug
                    core_slug=$(_rt_core_repo_slug "$core_root") || return 1
                    [ -n "$core_slug" ] || return 1
                    if [ "$(_rt_lower "$(_rt_normalize_slug "$slug")")" = "$(_rt_lower "$core_slug")" ]; then
                        return 1  # core 自身を明示指定 → 保護継続
                    fi
                    continue  # core 以外を明示指定 → この危険コマンドは外部対象
                fi
            fi

            # 明示指定なし → cwd 追跡で判定
            [ "$cur_known" = "1" ] || return 1
            _rt_dir_is_external_repo "$cur_dir" "$core_root" || return 1
            continue
        fi
    done <<< "$segmented"

    [ "$found_danger" = "1" ] && return 0
    return 1
}