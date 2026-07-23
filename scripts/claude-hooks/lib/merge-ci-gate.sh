#!/usr/bin/env bash
# merge-ci-gate.sh — 手動 `gh pr merge` の CI-green ゲート用純関数（#N / {ISSUE-ID}）
#
# 背景: auto-merge の「CI 全 check pass」ゲートは /auto-merge 経路のみで、
# `gh pr merge`（手動）には効かない。GitHub Free × private のためブランチ保護
# （required status checks）も使えず、赤 PR の手動マージが main を壊す事故が実発生した
# （PR #N → 全 PR の static-checks 連鎖失敗 → #N で復旧）。
# 本 lib は pre-tool-use-gh-pr-merge.sh から使う純関数のみを持つ（ネットワーク呼び出しなし）。

# gh pr merge コマンド文字列から明示 PR 番号を抽出する。
#   "gh pr merge 123 --squash"                       -> 123
#   "gh pr merge --squash 123"                       -> 123
#   "gh pr merge https://github.com/o/r/pull/123 -s" -> 123
#   "gh pr merge --squash"（現在ブランチ）           -> ""（空）
# 値を取るフラグ（--subject 等）の直後トークンは番号でも PR 番号とみなさない。
mcg_pr_number_from_merge_command() {
  # サブシェル + set -f: 未クォートのワード分割でグロブ展開が効くと、`*` を含む
  # コマンドで cwd のファイル名（数字名なら誤 PR 番号）がトークンに混入するため抑止する
  # （`local -` は macOS bash 3.2 に無いのでサブシェルで隔離）。
  (
    set -f
    local cmd="$1"
    local -a tokens
    # shellcheck disable=SC2206
    tokens=($cmd)
    local seen_merge=0 skip_next=0 tok
    for tok in "${tokens[@]}"; do
        if [ "$skip_next" = 1 ]; then
            skip_next=0
            continue
        fi
        if [ "$seen_merge" = 0 ]; then
            [ "$tok" = "merge" ] && seen_merge=1
            continue
        fi
        case "$tok" in
            -t|-b|-F|-A|--subject|--body|--body-file|--match-head-commit|--author-email|-R|--repo)
                skip_next=1
                continue
                ;;
            -*)
                continue
                ;;
        esac
        if [[ "$tok" =~ ^[0-9]+$ ]]; then
            printf '%s\n' "$tok"
            return 0
        fi
        if [[ "$tok" =~ /pull/([0-9]+) ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
            return 0
        fi
    done
    printf '\n'
    return 0
  )
}

# PR 本文に独立行の [force-merge] タグがあるか（意図的な赤マージの opt-out）。
# 記法は [manual-merge] / [team] と同じ「前後が空白文字のみの独立行」。
mcg_has_force_merge_tag() {
    local body="$1"
    grep -Eq '^[[:space:]]*\[force-merge\][[:space:]]*$' <<<"$body"
}

# `gh pr checks <PR>` の TSV 出力（name<TAB>bucket<TAB>...）から failing check 名を列挙する。
# bucket ∈ {pass, fail, pending, skipping, cancel}（`gh pr checks --help` 記載の 5 種）のうち
# fail / cancel を failing とみなす:
#   - fail   : 実行されて失敗
#   - cancel : 最新 run がキャンセル済み = 「通った」ではない。長い CI を待てず run を
#              cancel してマージする経路が [force-merge] の記録を残さず成立するのを防ぐ
#   - pending: ブロックしない（実行中マージの是非は auto-merge 経路の CI 待ちが担う）
# `error` は gh に存在しないバケットのため見ない（旧実装のデッドコード・deep-audit F-7）。
mcg_failing_from_checks() {
    local checks="$1"
    awk -F'\t' '$2 == "fail" || $2 == "cancel" { print $1 }' <<<"$checks"
}

# `gh pr merge` コマンド文字列から明示 repo 指定（-R / --repo の値、または PR URL の
# owner/repo 部）を抽出する。空文字なら「現在の repo」。
#   "gh pr merge -R acme/widgets 78"                        -> acme/widgets
#   "gh pr merge -Racme/widgets 78"                         -> acme/widgets（-R 連結形）
#   "gh pr merge --repo=acme/widgets 78"                    -> acme/widgets
#   "gh pr merge https://github.com/acme/widgets/pull/123"   -> acme/widgets
#   "gh pr merge 123 --squash"                              -> ""（現在の repo）
#
# 抽出しないと PR 番号だけが後段の `gh pr checks <N>` に渡り、**別 repo の PR を指定しても
# 現在の repo の同番号 PR を見てしまう**（deep-audit F-2）。赤 PR の素通しと、無関係な
# 赤 PR による誤ブロックの両方向に誤る。
mcg_repo_from_merge_command() {
  (
    set -f
    local cmd="$1"
    local -a tokens
    # shellcheck disable=SC2206
    tokens=($cmd)
    local seen_merge=0 expect_repo=0 tok
    for tok in "${tokens[@]}"; do
        if [ "$expect_repo" = 1 ]; then
            printf '%s\n' "$tok"
            return 0
        fi
        # -R / --repo は **サブコマンドの前後どちらにも置ける**（実測: `gh pr -R o/r view N` は成功）。
        # merge 以降だけを走査すると `gh pr -R o/r merge N` で repo を取りこぼし、番号だけが後段に
        # 渡って現在 repo の同番号 PR を見てしまう（F-2 と同じ事故の別配置）。よって全トークンを見る。
        # -R は pflag の shorthand flag のため区切りなし連結（-Rvalue）も有効な gh 構文
        # （実測: `gh pr -Racme/widgets view N` は成功）。`-R?*` は `-R=*` より後に置き、
        # `-R=acme/widgets` が先に `-R=*` へマッチしてから `-R` の等号を正しく剥がせるようにする
        # （{ISSUE-ID} / #N: 検知側 `_cm_has_gh_pr_subcommand` の連結形対応と対で修正。検知が
        # 先に直ってこの抽出漏れが初めて到達可能になった＝片方だけ直すと「検知はするが誤った
        # repo の CI を見る」という、無検知より危険な状態が残るため同一 PR で修正する）。
        case "$tok" in
            -R|--repo)   expect_repo=1; continue ;;
            --repo=*)    printf '%s\n' "${tok#--repo=}"; return 0 ;;
            -R=*)        printf '%s\n' "${tok#-R=}"; return 0 ;;
            -R?*)        printf '%s\n' "${tok#-R}"; return 0 ;;
        esac
        # URL 形は PR 引数の位置（merge の後）にしか現れないため、こちらは従来どおり merge 以降に限る
        if [ "$seen_merge" = 0 ]; then
            [ "$tok" = "merge" ] && seen_merge=1
            continue
        fi
        if [[ "$tok" =~ ^https?://[^/]+/([^/]+/[^/]+)/pull/[0-9]+ ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
            return 0
        fi
    done
    printf '\n'
    return 0
  )
}

# `--auto` / `--disable-auto` を伴う `gh pr merge` か。
#   `gh pr merge --auto` は「CI が green になったら自動マージ」= 本ゲートが実現したい挙動
#   そのもの。赤い現時点でブロックすると [force-merge] の濫用を誘発しゲートが形骸化する。
#   `--disable-auto` は auto-merge の解除でマージですらない。どちらも判定対象外にする
#   （deep-audit F-3）。
mcg_is_auto_merge_command() {
    local cmd="$1"
    [[ " $cmd " =~ [[:space:]](--auto|--disable-auto)([[:space:]]|$) ]]
}

# checks が空だったときに「CI 未設定 repo」と「CI はあるが未報告（head SHA に未登録）」を
# 区別する（deep-audit F-1 / 較正実例 Case A の再演を防ぐ）。
#   csr 相当の判定を hook 予算（timeout 15s）に収まる非ポーリング形で行う。auto-merge 側の
#   classify_ci_presence は約 90 秒ポーリングする設計で PreToolUse hook には入らないため、
#   「workflow 定義が存在するか」という決定的・O(1) の signal に置き換えている（分類の意図
#   =「空」を即「CI 無し」と読まないことは同一）。
#
#   rollup_len > 0                     -> present      （checks あり。個別 bucket で判定）
#   rollup_len == 0 かつ workflow あり -> not-reported （CI はある = まだ報告されていない → ブロック）
#   rollup_len == 0 かつ workflow なし -> absent       （真の CI 未設定 repo → 通す）
#   非数値（取得失敗）                 -> not-reported （安全側。素通しさせない）
mcg_ci_presence_decision() {
    local rollup_len="${1:-}" workflows_exist="${2:-}"
    if [[ "$rollup_len" =~ ^[0-9]+$ ]]; then
        if [ "$rollup_len" -gt 0 ]; then
            echo "present"
        elif [ "$workflows_exist" = "1" ]; then
            echo "not-reported"
        else
            echo "absent"
        fi
    else
        echo "not-reported"
    fi
}

# repo に GitHub Actions の workflow 定義が存在するか（1 = あり / 0 = なし）。
# 別 repo 指定時はローカルから判定できないため 1（= 安全側・ブロック寄り）を返す。
mcg_workflows_exist() {
    local repo_dir="${1:-}" cross_repo="${2:-0}" p
    [ "$cross_repo" = "1" ] && { echo 1; return 0; }
    for p in "$repo_dir"/.github/workflows/*.yml "$repo_dir"/.github/workflows/*.yaml; do
        [ -f "$p" ] && { echo 1; return 0; }
    done
    echo 0
}