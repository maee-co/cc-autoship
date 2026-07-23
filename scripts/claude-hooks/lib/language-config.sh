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

# 直接実行した場合のみ strict mode を有効化する（source 時は親の設定を尊重）。
# ★ ${BASH_SOURCE[0]:-} と既定値を必ず付ける: zsh には BASH_SOURCE が無いため、
#   set -u を敷いた親（auto-merge-criteria.sh 等）から source されると unbound エラーで
#   **読み込みがこの行で中断**し、lc_* が未定義のまま日本語へ無言フォールバックする
#   （{ISSUE-ID} で実測。エラーは stderr に出るだけで hook は落ちないため気付きにくい）。
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
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
# 入力: $1 = kind（review | verdict）, $2 = lang（ja|en）
lc_heading() {
  local kind="${1:-review}" lang="${2:-ja}"
  case "${kind}:${lang}" in
    review:en)  printf '%s' "## Review Result" ;;
    review:*)   printf '%s' "## レビュー結果" ;;
    verdict:en) printf '%s' "### Verdict" ;;
    verdict:*)  printf '%s' "### 判定" ;;
    *)          printf '%s' "## レビュー結果" ;;
  esac
}

# lc_verdict_label: 表示専用の判定ラベル。
#   機械検知はマーカー（<!-- review-verdict: <token> -->）が担うため、これは表示専用。
#   ja/en 双方のトークン（要確認 / needs-review）を受け付け、指定言語のラベルに正規化する。
# 入力: $1 = status（pass|要確認|fail|needs-review）, $2 = lang（ja|en）
lc_verdict_label() {
  # ★ 変数名に status を使わない: zsh では status が read-only（$? のエイリアス）のため
  #   `local status=...` が失敗し、ラベルが空文字になる（{ISSUE-ID} の配線時に実測）。
  #   hook 本体は bash 実行だが、スキル経由の zsh source 経路があるため両対応が必要
  #   （bash のテストでは原理的に検出できない。__tests__ に zsh 回帰テストを併設している）。
  local vstatus="${1:-}" lang="${2:-ja}"
  case "${vstatus}:${lang}" in
    pass:en)                   printf '%s' "pass" ;;
    要確認:en|needs-review:en) printf '%s' "needs-review" ;;
    fail:en)                   printf '%s' "fail" ;;
    pass:*)                    printf '%s' "pass" ;;
    要確認:*|needs-review:*)   printf '%s' "要確認" ;;
    fail:*)                    printf '%s' "fail" ;;
    *)                         printf '%s' "$vstatus" ;;
  esac
}

# lc_verdict_reason: 判定に添える理由文（表示専用）。pass は理由なし（空文字）。
#   文頭の区切り（ja は「。」/ en は ". "）まで含めて返すので、呼び出し側は連結するだけでよい。
# 入力: $1 = verdict（pass|要確認|fail|needs-review）, $2 = lang（ja|en）
lc_verdict_reason() {
  local verdict="${1:-}" lang="${2:-ja}"
  case "${verdict}:${lang}" in
    要確認:en|needs-review:en) printf '%s' ". Major findings or high-risk points remain; merge after a maintainer review" ;;
    要確認:*|needs-review:*)   printf '%s' "。Major 指摘または高リスク論点が残るため、メンテナの確認後にマージ可" ;;
    fail:en)                   printf '%s' ". Critical findings or non-green tests; fixes are required" ;;
    fail:*)                    printf '%s' "。Critical 指摘またはテスト非緑化のため修正が必要" ;;
    *)                         printf '%s' "" ;;
  esac
}

# lc_verdict_rationale_format: 判定節本文の printf フォーマット（表示専用）。
#   %s の順序は「判定ラベル / critical / major / tests / high_risk / reason」で ja/en 共通に保つ
#   （呼び出し側 rvp_compose_comment が同じ順で埋めるため、順序を崩さないこと）。
# 入力: $1 = lang（ja|en）
lc_verdict_rationale_format() {
  local lang="${1:-ja}"
  case "$lang" in
    en) printf '%s' '**%s** — derived deterministically by the bundled script (review-verdict-post.sh) from the submitted facts: Critical %s / Major %s / tests %s / high-risk %s (not a self-approval by the implementing session, but the output of a tested pure function)%s' ;;
    *)  printf '%s' '**%s** — 判定は同梱スクリプト（review-verdict-post.sh）が入力事実から決定的に導出: Critical %s / Major %s / tests %s / 高リスク論点 %s（実装セッションによる自己承認ではなく、テスト済み純関数の出力）%s' ;;
  esac
}

# ─────────────────────────────────────────────
# auto-merge 判定コメントの文言（{ISSUE-ID} Phase 2a・すべて表示専用）
#   マージ可否そのもの（exit code）と検知ロジックは言語に依存しない。
#   ja は既存文言と 1 文字も変えないこと（既存テストが日本語で assert しているため）。
# ─────────────────────────────────────────────

# lc_am_heading: 判定コメントの見出し
# 入力: $1 = ok|ng, $2 = lang（ja|en）
lc_am_heading() {
  case "${1:-ok}:${2:-ja}" in
    ok:en) printf '%s' "## 🤖 /auto-merge verdict: ✅ Auto-mergeable" ;;
    ok:*)  printf '%s' "## 🤖 /auto-merge 判定結果: ✅ 自動マージ可" ;;
    ng:en) printf '%s' "## 🤖 /auto-merge verdict: ❌ Not auto-mergeable" ;;
    ng:*)  printf '%s' "## 🤖 /auto-merge 判定結果: ❌ 自動マージ不可" ;;
  esac
}

# lc_am_conclusion: 判定コメントの結論文。
#   ng は失敗理由を %s で受ける printf フォーマットを返す（呼び出し側が埋める）。
# 入力: $1 = ok|ng, $2 = lang（ja|en）
lc_am_conclusion() {
  case "${1:-ok}:${2:-ja}" in
    ok:en) printf '%s' "Waiting for CI to finish, then merging automatically." ;;
    ok:*)  printf '%s' "CI 完了を待って自動マージします。" ;;
    ng:en) printf '%s' '**Conclusion**: %s. Manual merge by a maintainer is required.' ;;
    ng:*)  printf '%s' '**結論**: %s。メンテナの手動マージが必要です。' ;;
  esac
}

# lc_am_step: 判定の後に auto-merge-run.sh が投稿する CI / マージ結果コメントの全文（{ISSUE-ID} Phase 3）。
#   Phase 2 で判定コメントだけが言語追随したため、英語セッションでは「判定は英語・その直後の
#   マージ結果は日本語」という混在が起きていた（v0.1.21 のリリース前 e2e で実測）。
#   ci_fail / merge_fail は可変部（checks 出力・マージ出力）を %s で受ける printf フォーマットを返す。
#   それ以外は %s を含まない素の文字列を返す（呼び出し側が printf '%s' で扱えるようにするため）。
# 入力: $1 = ci_skip|ci_pass|ci_fail|merge_fail|merge_ok, $2 = lang（ja|en）
# 出力: コメント全文（見出し込み）。未知キーは空（呼び出し側でコメント投稿を抑止する）
lc_am_step() {
  case "${1:-}:${2:-ja}" in
    ci_skip:en) printf '%s' "## 🤖 /auto-merge CI: ⏭️ CI not configured

statusCheckRollup is empty, so the CI check is skipped. Running squash merge." ;;
    ci_skip:*)  printf '%s' "## 🤖 /auto-merge CI: ⏭️ CI 未設定

statusCheckRollup が空のため CI チェックをスキップします。squash merge を実行します。" ;;
    ci_pass:en) printf '%s' "## 🤖 /auto-merge CI: ✅ All checks passed

CI passed, so the squash merge will run." ;;
    ci_pass:*)  printf '%s' "## 🤖 /auto-merge CI: ✅ 全 check 成功

CI が pass したため、squash merge を実行します。" ;;
    ci_fail:en) printf '%s' "## 🤖 /auto-merge CI: ❌ Failed / timed out

\`\`\`
%s
\`\`\`

If CI never started (exhausted Actions quota and the like), run step 2.5 of auto-merge.md (local verification fallback) by hand. Waiting for a maintainer." ;;
    ci_fail:*)  printf '%s' "## 🤖 /auto-merge CI: ❌ 失敗 / タイムアウト

\`\`\`
%s
\`\`\`

CI 不発（Actions 枠枯渇等）の場合は auto-merge.md ステップ 2.5（ローカル検証フォールバック）を手動で実施すること。メンテナの対応待ちです。" ;;
    merge_fail:en) printf '%s' "## 🤖 /auto-merge Merge failed: ❌

\`\`\`
%s
\`\`\`

This may be a conflict or similar. Waiting for a maintainer." ;;
    merge_fail:*)  printf '%s' "## 🤖 /auto-merge マージ失敗: ❌

\`\`\`
%s
\`\`\`

コンフリクト等の可能性があります。メンテナの対応待ちです。" ;;
    merge_ok:en) printf '%s' "## 🤖 /auto-merge Merged: ✅

Merged with \`squash merge\`. The worktree is cleaned up automatically." ;;
    merge_ok:*)  printf '%s' "## 🤖 /auto-merge マージ完了: ✅

\`squash merge\` でマージしました。worktree は自動クリーンアップされます。" ;;
  esac
}

# lc_am_condition: 判定表の条件ラベル（静的なもの）
# 入力: $1 = キー, $2 = lang（ja|en）
lc_am_condition() {
  case "${1:-}:${2:-ja}" in
    size_default:en) printf '%s' "1. Diff size <= 500 lines / <= 10 files" ;;
    size_default:*)  printf '%s' "1. 差分サイズ ≤ 500 行 / ≤ 10 ファイル" ;;
    scope:en)        printf '%s' "2. Scope (infra / single internal app)" ;;
    scope:*)         printf '%s' "2. スコープ（infra / 単一内部アプリ）" ;;
    public:en)       printf '%s' "3. No public content touched" ;;
    public:*)        printf '%s' "3. 公開コンテンツ非該当" ;;
    review:en)       printf '%s' "4. Review verdict pass, zero Critical/Major" ;;
    review:*)        printf '%s' "4. レビュー判定 pass・Critical/Major ゼロ" ;;
    danger:en)       printf '%s' "5. No dangerous operations" ;;
    danger:*)        printf '%s' "5. 危険操作なし" ;;
    manual:en)       printf '%s' "6. No [manual-merge] tag" ;;
    manual:*)        printf '%s' "6. [manual-merge] タグなし" ;;
    draft:en)        printf '%s' "7. Not a draft" ;;
    draft:*)         printf '%s' "7. draft でない" ;;
    e2e:en)          printf '%s' "8. e2e for UI changes (L1 golden path)" ;;
    e2e:*)           printf '%s' "8. UI 変更時 e2e（L1 golden path）" ;;
    e2e_na:en)       printf '%s' "8. e2e for UI changes (no UI change - N/A)" ;;
    e2e_na:*)        printf '%s' "8. UI 変更時 e2e（UI 変更なし・N/A）" ;;
    selfimp_na:en)   printf '%s' "9. self-improve protected paths ([self-improve] absent - N/A)" ;;
    selfimp_na:*)    printf '%s' "9. self-improve 保護パス非該当（[self-improve] でない・N/A）" ;;
    selfimp:en)      printf '%s' "9. [self-improve] PR touches no protected path" ;;
    selfimp:*)       printf '%s' "9. [self-improve] PR は保護パス非該当" ;;
    table_header:en) printf '%s' "| Condition | Result |" ;;
    table_header:*)  printf '%s' "| 条件 | 結果 |" ;;
    *)               printf '%s' "${1:-}" ;;
  esac
}

# lc_am_condition_size_format: 条件 1 の動的ラベル（printf フォーマット）。
#   %s の順序は ja/en 共通に保つこと:
#     excluded → 実コード行数, テスト/.md 行数
#     new_app  → 実コード行数, ファイル数
# 入力: $1 = excluded|new_app, $2 = lang（ja|en）
lc_am_condition_size_format() {
  case "${1:-}:${2:-ja}" in
    excluded:en) printf '%s' '1. Real code diff %s lines / limit 500 / <= 10 files (excludes %s lines of tests/.md)' ;;
    excluded:*)  printf '%s' '1. 実コード差分 %s 行 / 上限 500 行 / ≤ 10 ファイル（テスト/.md %s 行を除外）' ;;
    new_app:en)  printf '%s' '1. Diff size (exempt: initial PR for a new app - real code %s lines / %s files)' ;;
    new_app:*)   printf '%s' '1. 差分サイズ（新規アプリ初期 PR につき上限免除: 実コード %s 行 / %s ファイル）' ;;
  esac
}

# lc_am_reason: auto-merge の失敗理由（{ISSUE-ID} Phase 2b・表示専用）。
#   check_* が >&2 に出し、_eval が判定表の結果列と結論文に埋める文言。
#   %s を含むものは printf フォーマットとして返す（%s の順序は ja/en 共通に保つこと）。
#   ja は既存文言と 1 文字も変えない（既存テストが日本語で assert しているため）。
# 入力: $1 = キー, $2 = lang（ja|en）
lc_am_reason() {
  case "${1:-}:${2:-ja}" in
    # 条件 1: サイズ（%s = 行数/ファイル数, 上限）
    size_lines:en)        printf '%s' 'Diff size exceeded: %s lines (limit %s)' ;;
    size_lines:*)         printf '%s' '差分サイズ超過: %s 行（上限 %s）' ;;
    size_files:en)        printf '%s' 'Too many files: %s (limit %s)' ;;
    size_files:*)         printf '%s' 'ファイル数超過: %s（上限 %s）' ;;
    # 条件 2: スコープ（%s = アプリ名 / パッケージ名）
    multi_app:en)         printf '%s' 'Spans multiple apps: %s' ;;
    multi_app:*)          printf '%s' '複数アプリ横断: %s' ;;
    shared_pkg:en)        printf '%s' 'Shared package changed (affects multiple apps): packages/%s' ;;
    shared_pkg:*)         printf '%s' 'shared package 変更（複数アプリへの影響範囲）: packages/%s' ;;
    # 条件 3: 公開コンテンツ（%s = パス）
    public_content:en)    printf '%s' 'Public content changed: %s' ;;
    public_content:*)     printf '%s' '公開コンテンツへの変更を検出: %s' ;;
    # 条件 4: レビューゲート
    no_review:en)         printf '%s' 'No review comment posted on the PR (/review has not run)' ;;
    no_review:*)          printf '%s' 'レビューコメントが PR に投稿されていません（/review 未実行）' ;;
    review_critical:en)   printf '%s' '/review reported Critical / Major findings' ;;
    review_critical:*)    printf '%s' '/review に Critical / Major 指摘があります' ;;
    review_unresolved:en) printf '%s' 'The /review findings table has unresolved Critical / Major items' ;;
    review_unresolved:*)  printf '%s' '/review の 4 軸表に未解決の Critical / Major 指摘があります' ;;
    verdict_needs:en)     printf '%s' 'The /review verdict is needs-review (auto-merge blocked)' ;;
    verdict_needs:*)      printf '%s' '/review の判定ステータスが『要確認』です（auto-merge ブロック）' ;;
    verdict_fail:en)      printf '%s' 'The /review verdict is fail (auto-merge blocked)' ;;
    verdict_fail:*)       printf '%s' '/review の判定ステータスが『fail』です（auto-merge ブロック）' ;;
    verdict_unknown:en)   printf '%s' 'Could not detect the /review verdict (blocked because it is unknown)' ;;
    verdict_unknown:*)    printf '%s' '/review の判定ステータスを検出できません（不明のため auto-merge ブロック）' ;;
    # 条件 5: 危険操作（%s = ファイルパス）
    danger_migration:en)  printf '%s' 'Migration file changed: %s' ;;
    danger_migration:*)   printf '%s' 'migration ファイル変更: %s' ;;
    danger_sql:en)        printf '%s' 'SQL file changed: %s' ;;
    danger_sql:*)         printf '%s' 'SQL ファイル変更: %s' ;;
    danger_auth:en)       printf '%s' 'Auth-related file changed: %s' ;;
    danger_auth:*)        printf '%s' '認証関連ファイル変更: %s' ;;
    danger_billing:en)    printf '%s' 'Billing-related file changed: %s' ;;
    danger_billing:*)     printf '%s' '課金関連ファイル変更: %s' ;;
    danger_keyword:en)    printf '%s' 'Dangerous-operation keyword found in the PR body' ;;
    danger_keyword:*)     printf '%s' 'PR 本文に危険操作キーワードを検出' ;;
    # 条件 6 / 7
    optout:en)            printf '%s' '[manual-merge] tag present in the PR body - waiting for a manual merge' ;;
    optout:*)             printf '%s' '[manual-merge] タグが PR 本文にあるため メンテナ手動マージ待ち' ;;
    draft:en)             printf '%s' 'The PR is a draft and cannot be merged' ;;
    draft:*)              printf '%s' 'PR が draft 状態のためマージ不可' ;;
    # 条件 8: e2e（%s = 利用量 % / CI status）
    e2e_usage:en)         printf '%s' 'e2e CI auto-skipped above %s%% GitHub Actions usage. Waiting for a manual merge because the PR contains UI changes' ;;
    e2e_usage:*)          printf '%s' 'e2e CI が GitHub Actions 利用量 %s%% 超で自動 skip。UI 変更を含むため メンテナ手動マージ待ち' ;;
    e2e_unknown:en)       printf '%s' 'Could not determine the e2e CI status (gh failure etc.). Waiting for a manual merge because the PR contains UI changes' ;;
    e2e_unknown:*)        printf '%s' 'e2e CI 状態を確認できません（gh 取得失敗等）。UI 変更を含むため メンテナ手動マージ待ち' ;;
    e2e_cancelled:en)     printf '%s' 'e2e CI cancelled (likely a concurrency cancel from the latest push). Waiting for the next run' ;;
    e2e_cancelled:*)      printf '%s' 'e2e CI cancelled（最新 push の concurrency cancel 想定）。次回ジョブ完了を待機' ;;
    e2e_fail:en)          printf '%s' 'e2e CI failed. Not auto-mergeable because the PR contains UI changes' ;;
    e2e_fail:*)           printf '%s' 'e2e CI 失敗。UI 変更を含むため自動マージ不可' ;;
    # CI 不発フォールバックの判定理由（auto-merge.md が FALLBACK_REASON として PR に出す）
    fb_no_info:en)        printf '%s' 'Cannot fall back: failing-check information is unavailable (fail-closed)' ;;
    fb_no_info:*)         printf '%s' 'failing check の情報が取得できないため CI 不発フォールバック不可（fail-closed）' ;;
    fb_workflow:en)       printf '%s' 'Cannot fall back: the PR changes .github/workflows/ (CI definitions must be verified by real CI): %s' ;;
    fb_workflow:*)        printf '%s' 'PR が .github/workflows/ を変更しているため CI 不発フォールバック不可（CI 定義は実 CI で検証必須）: %s' ;;
    fb_no_steps:en)       printf '%s' "Cannot fall back: step count for check '%s' is unavailable (fail-closed)" ;;
    fb_no_steps:*)        printf '%s' "check '%s' の実行ステップ数が取得できないためフォールバック不可（fail-closed）" ;;
    fb_real_fail:en)      printf '%s' "Cannot fall back: check '%s' actually ran and failed (a real CI failure)" ;;
    fb_real_fail:*)       printf '%s' "check '%s' は実行されて失敗しています（真の CI 失敗のためフォールバック不可）" ;;
    *)                    printf '%s' "${1:-}" ;;
  esac
}