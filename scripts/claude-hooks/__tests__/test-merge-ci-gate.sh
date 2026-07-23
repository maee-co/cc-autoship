#!/bin/bash
# merge-ci-gate.sh（手動 gh pr merge の CI-green ゲート純関数・#N / {ISSUE-ID}）のテスト

# shellcheck source=../lib/merge-ci-gate.sh
source "$HOOKS_DIR/lib/merge-ci-gate.sh"

echo "merge-ci-gate: PR 番号抽出"

assert_eq "123" "$(mcg_pr_number_from_merge_command 'gh pr merge 123 --squash')" "番号が merge 直後にある形"
assert_eq "123" "$(mcg_pr_number_from_merge_command 'gh pr merge --squash 123')" "番号がフラグの後にある形"
assert_eq "123" "$(mcg_pr_number_from_merge_command 'gh pr merge https://github.com/acme/widgets/pull/123 -s')" "URL 形"
assert_eq "" "$(mcg_pr_number_from_merge_command 'gh pr merge --squash')" "番号なし（現在ブランチ）は空"
assert_eq "" "$(mcg_pr_number_from_merge_command 'gh pr merge --subject 999')" "値を取るフラグの直後は番号扱いしない"
assert_eq "456" "$(mcg_pr_number_from_merge_command 'gh pr merge -s 456')" "値を取らないフラグの後の番号は拾う"
assert_eq "78" "$(mcg_pr_number_from_merge_command 'gh pr merge -R acme/widgets 78 --squash')" "-R の値はスキップして番号を拾う"

# グロブ抑止（set -f）: 数字名ファイルがある cwd でも `*` が展開されず誤 PR 番号にならない
MCG_GLOB_DIR=$(mktemp -d)
touch "$MCG_GLOB_DIR/999"
assert_eq "123" "$(cd "$MCG_GLOB_DIR" && mcg_pr_number_from_merge_command 'gh pr merge * 123')" "グロブ展開で cwd の数字ファイル名を拾わない"
rm -rf "$MCG_GLOB_DIR"

echo "merge-ci-gate: [force-merge] タグ判定"

BODY_WITH_TAG=$'## 概要\n\n[force-merge]\n\n以上'
BODY_INLINE=$'この PR は [force-merge] を使わない'
BODY_INDENTED=$'  [force-merge]  '
BODY_NONE=$'## 概要\n通常の PR'

mcg_has_force_merge_tag "$BODY_WITH_TAG"
assert_exit_code "0" "$?" "独立行タグは検知"
mcg_has_force_merge_tag "$BODY_INDENTED"
assert_exit_code "0" "$?" "前後空白のみの行も検知"
mcg_has_force_merge_tag "$BODY_INLINE"
assert_exit_code "1" "$?" "文中の言及は検知しない"
mcg_has_force_merge_tag "$BODY_NONE"
assert_exit_code "1" "$?" "タグなしは検知しない"

echo "merge-ci-gate: failing check 抽出"

CHECKS_MIXED=$'static-checks\tfail\t1m2s\thttps://example.com/a\nhook-tests\tpass\t47s\thttps://example.com/b\ne2e\tpending\t0\thttps://example.com/c'
CHECKS_GREEN=$'static-checks\tpass\t1m2s\thttps://example.com/a\nhook-tests\tpass\t47s\thttps://example.com/b'
CHECKS_SKIP=$'Vercel - app\tskipping\t0\thttps://example.com/v'

assert_eq "static-checks" "$(mcg_failing_from_checks "$CHECKS_MIXED")" "fail 行のみ抽出（pending は含めない）"
assert_eq "" "$(mcg_failing_from_checks "$CHECKS_GREEN")" "全 pass は空"
assert_eq "" "$(mcg_failing_from_checks "$CHECKS_SKIP")" "skipping は failing 扱いしない"
assert_eq "" "$(mcg_failing_from_checks "")" "空入力は空（CI 未設定の fail-open 前提）"

# deep-audit F-4 / F-7: cancel は「通った」ではない / error は gh に存在しないバケット
CHECKS_CANCEL=$'static-checks\tcancel\t1m\thttps://example.com/a'
assert_eq "static-checks" "$(mcg_failing_from_checks "$CHECKS_CANCEL")" "cancel は failing 扱い（無記録バイパス防止）"

echo "merge-ci-gate: repo 抽出（cross-repo 誤判定の防止・F-2）"

assert_eq "acme/widgets" "$(mcg_repo_from_merge_command 'gh pr merge -R acme/widgets 78 --squash')" "-R の値を抽出"
assert_eq "acme/widgets" "$(mcg_repo_from_merge_command 'gh pr merge --repo acme/widgets 78')" "--repo の値を抽出"
assert_eq "acme/widgets" "$(mcg_repo_from_merge_command 'gh pr merge --repo=acme/widgets 78')" "--repo=値 形を抽出"
assert_eq "acme/widgets" "$(mcg_repo_from_merge_command 'gh pr merge https://github.com/acme/widgets/pull/123 -s')" "URL から owner/repo を抽出"
assert_eq "" "$(mcg_repo_from_merge_command 'gh pr merge 123 --squash')" "repo 指定なしは空（現在の repo）"
assert_eq "" "$(mcg_repo_from_merge_command 'gh pr merge --squash')" "番号も repo も無い形は空"

# gh は `-R` をサブコマンドより前にも置ける（実測: `gh pr -R <owner>/<repo> view <N>` は成功する）。
# merge 以降しか走査しないと repo を取りこぼし、番号だけが後段に渡って **現在 repo の同番号 PR** を
# 見てしまう（F-2 と同じ事故が別の引数配置で再演する）。赤 PR の素通し・無関係な誤ブロックの両方向。
assert_eq "acme/widgets" "$(mcg_repo_from_merge_command 'gh pr -R acme/widgets merge 78')" "-R が merge の前でも抽出"
assert_eq "acme/widgets" "$(mcg_repo_from_merge_command 'gh pr --repo acme/widgets merge 78')" "--repo が merge の前でも抽出"
assert_eq "acme/widgets" "$(mcg_repo_from_merge_command 'gh pr --repo=acme/widgets merge 78')" "--repo=値 が merge の前でも抽出"

# {ISSUE-ID} / #N: -R は pflag の shorthand flag のため区切りなし連結（-Rvalue）も有効な gh
# 構文（実測: `gh pr -Racme/widgets view N` は成功）。検知側 `_cm_has_gh_pr_subcommand` の
# 連結形対応と対で修正 — 検知だけ直して抽出を直さないと「検知はするが誤った repo の CI を
# 見る」という無検知より危険な状態が残る。
assert_eq "acme/widgets" "$(mcg_repo_from_merge_command 'gh pr merge -Racme/widgets 78')" "-R 連結形（merge の後）を抽出"
assert_eq "acme/widgets" "$(mcg_repo_from_merge_command 'gh pr -Racme/widgets merge 78')" "-R 連結形（merge の前）を抽出"

echo "merge-ci-gate: --auto / --disable-auto は判定対象外（F-3）"

mcg_is_auto_merge_command 'gh pr merge --auto --squash 1882'
assert_exit_code "0" "$?" "--auto は検知（green 待ち自動マージを止めない）"
mcg_is_auto_merge_command 'gh pr merge --disable-auto 1882'
assert_exit_code "0" "$?" "--disable-auto は検知（マージですらない）"
mcg_is_auto_merge_command 'gh pr merge --squash 1882'
assert_exit_code "1" "$?" "通常マージは検知しない"
mcg_is_auto_merge_command 'gh pr merge --body "enable --auto later" 1882'
assert_exit_code "0" "$?" "現状は本文中の --auto も検知する（安全側=ゲート緩和ではなくスキップ）"

echo "merge-ci-gate: checks 空の解釈（未設定 vs 未報告・F-1 / 較正 Case A）"

assert_eq "present" "$(mcg_ci_presence_decision 9 1)" "checks あり → present"
assert_eq "present" "$(mcg_ci_presence_decision 1 0)" "checks あれば workflow 有無に依らず present"
assert_eq "not-reported" "$(mcg_ci_presence_decision 0 1)" "空 × workflow あり → 未報告としてブロック"
assert_eq "absent" "$(mcg_ci_presence_decision 0 0)" "空 × workflow なし → 真の CI 未設定として通す"
assert_eq "not-reported" "$(mcg_ci_presence_decision "" 0)" "取得失敗は安全側（素通しさせない）"

echo "merge-ci-gate: workflow 定義の実在判定"

MCG_WF_DIR=$(mktemp -d)
assert_eq "0" "$(mcg_workflows_exist "$MCG_WF_DIR" 0)" "workflow ディレクトリなし → 0"
mkdir -p "$MCG_WF_DIR/.github/workflows"
assert_eq "0" "$(mcg_workflows_exist "$MCG_WF_DIR" 0)" "空ディレクトリ → 0"
touch "$MCG_WF_DIR/.github/workflows/ci.yml"
assert_eq "1" "$(mcg_workflows_exist "$MCG_WF_DIR" 0)" "*.yml があれば 1"
assert_eq "1" "$(mcg_workflows_exist "$MCG_WF_DIR" 1)" "cross-repo は判定不能のため安全側 1"
rm -rf "$MCG_WF_DIR"

echo "merge-ci-gate: bash 3.2 互換（空配列 × set -u で fatal しない）"

# 素の macOS の /bin/bash は 3.2 で、`set -u` 下の空配列展開 "${A[@]}" を unbound として fatal 終了する
# （bash 4.4 で修正済み）。本 hook は settings.json から `bash <script>` = **PATH の bash** で起動され、
# homebrew bash が無い環境では 3.2 が使われる。さらに本 hook は manifest 経由で cc-autoship として
# OSS 配布されるため、配布先の素の macOS で「ゲートが常に fatal → 赤 PR 素通し」になる。
# 実測: repo 指定なし（GH_REPO_ARGS が空）の `gh pr merge <N>` で
#   bash 5.3 → exit 2（ブロック成功） / bash 3.2 → line 72 unbound variable, exit 1（素通し）
MCG_GATE_HOOK="$HOOKS_DIR/pre-tool-use-gh-pr-merge.sh"

# 1) 静的: GH_REPO_ARGS の展開はすべて ${ARR[@]+"${ARR[@]}"} のガード形であること
mcg_unguarded=0
while IFS= read -r mcg_line; do
    case "$mcg_line" in
        *'GH_REPO_ARGS[@]'*)
            case "$mcg_line" in
                *'GH_REPO_ARGS[@]+'*) : ;;
                *) mcg_unguarded=$((mcg_unguarded + 1)) ;;
            esac
            ;;
    esac
done < "$MCG_GATE_HOOK"
assert_eq "0" "$mcg_unguarded" "GH_REPO_ARGS の展開は空配列ガード形のみ（bash 3.2 で fatal しない）"

# 2) 実行: ガード形が set -u 下で空/非空とも壊れないこと（3.2 があれば 3.2 で確認する）
MCG_TEST_BASH=bash
[ -x /bin/bash ] && MCG_TEST_BASH=/bin/bash
if "$MCG_TEST_BASH" -c 'set -euo pipefail; A=(); printf "%s" "${A[@]+"${A[@]}"}"' >/dev/null 2>&1; then
    mcg_guard_empty=0
else
    mcg_guard_empty=1
fi
assert_eq "0" "$mcg_guard_empty" "空配列のガード形は set -u で fatal しない（${MCG_TEST_BASH}）"
assert_eq "-R|acme/widgets" \
    "$("$MCG_TEST_BASH" -c 'set -euo pipefail; A=(-R acme/widgets); printf "%s|%s" "${A[@]+"${A[@]}"}"')" \
    "非空配列のガード形は語分割を保つ（引数が 1 語に潰れない）"