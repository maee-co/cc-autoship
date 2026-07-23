#!/usr/bin/env bash
# lib/review-verdict.sh（/review 判定の機械導出・{ISSUE-ID} Phase 2）のユニットテスト。
#
# 背景: auto mode の権限分類器は「エージェントが自分の PR に肯定的 pass 判定を投稿する」
#   行為を [Self-Approval] として実ブロックする（2026-07-12 撮影セッション jsonl L365 で実証）。
#   判定の「著者」をモデルから剥奪し、findings の事実（Critical/Major 数・テスト結果・
#   高リスク論点有無）から verdict をスクリプトが決定的に導出・投稿する。
#
# runner 規約: test-runner.sh が PASS/FAIL/ERRORS と assert_* / 色変数を注入して source する。
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT/claude-hooks/lib/review-verdict.sh"
# 実パーサとの統合 assert 用
# shellcheck disable=SC1091
source "$ROOT/claude-hooks/lib/auto-merge-criteria.sh"

# 表示言語の決定性: compose は lc_current_lang（native 追随）に従うため、
# 既定ケースは ja に固定し、実行環境の ~/.claude/settings.json に左右されないようにする
# （CI と開発機で結果が変わると回帰検知が壊れる）。en の検証は各ケースで明示上書きする。
export CC_AUTOSHIP_LANG=ja

echo "test-review-verdict: 判定の機械導出（{ISSUE-ID} Phase 2）"

# --- rvp_derive_verdict: 導出マトリクス ---
assert_eq "pass"   "$(rvp_derive_verdict 0 0 green no)"  "derive: 0/0/green/no → pass"
assert_eq "fail"   "$(rvp_derive_verdict 1 0 green no)"  "derive: critical>0 → fail"
assert_eq "fail"   "$(rvp_derive_verdict 0 0 red no)"    "derive: tests=red → fail"
assert_eq "fail"   "$(rvp_derive_verdict 2 3 red yes)"   "derive: fail が最優先"
assert_eq "要確認" "$(rvp_derive_verdict 0 1 green no)"  "derive: major>0 → 要確認"
assert_eq "要確認" "$(rvp_derive_verdict 0 0 green yes)" "derive: 高リスク論点 → 要確認"

# 不正入力は非0（fail-closed）
if rvp_derive_verdict abc 0 green no >/dev/null 2>&1; then
  FAIL=$((FAIL + 1)); ERRORS+=("derive: 非数値 critical は非0"); echo -e "  ${RED}✗${NC} derive: 非数値 critical は非0"
else
  PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} derive: 非数値 critical は非0"
fi
if rvp_derive_verdict 0 0 sometimes no >/dev/null 2>&1; then
  FAIL=$((FAIL + 1)); ERRORS+=("derive: tests は green|red 限定"); echo -e "  ${RED}✗${NC} derive: tests は green|red 限定"
else
  PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} derive: tests は green|red 限定"
fi

# --- rvp_compose_comment: 合成 + 実パーサ統合 ---
BODY_FACTS="**対象**: PR {ISSUE-ID}（feat/x） / 実コード差分 10 行・2 ファイル

**サマリ**: 事実サマリ。

### 指摘一覧

| # | 重要度 | 信頼度 | スコープ | 指摘 | 対応 |
|---|--------|--------|----------|------|------|

### 検証

- test: ✅"

OUT_PASS="$(rvp_compose_comment "$BODY_FACTS" pass 0 0 green no "")"
assert_contains "## レビュー結果" "$OUT_PASS" "compose: 見出しをスクリプトが付与"
assert_contains "review-verdict-post.sh" "$OUT_PASS" "compose: 導出主体（スクリプト）を明記"
assert_eq "pass" "$(extract_review_verdict_from_text "$OUT_PASS")" "統合: 実パーサが pass を抽出"

OUT_YK="$(rvp_compose_comment "$BODY_FACTS" 要確認 0 2 green no "")"
assert_eq "要確認" "$(extract_review_verdict_from_text "$OUT_YK")" "統合: 実パーサが 要確認 を抽出"

OUT_FAIL="$(rvp_compose_comment "$BODY_FACTS" fail 1 0 red no "")"
assert_eq "fail" "$(extract_review_verdict_from_text "$OUT_FAIL")" "統合: 実パーサが fail を抽出"

# light マーカー: 見出し直下 2 行目に置く（review.md 不変条件）
OUT_LIGHT="$(rvp_compose_comment "$BODY_FACTS" pass 0 0 green no "light")"
assert_eq "<!-- review:light -->" "$(printf '%s\n' "$OUT_LIGHT" | sed -n '2p')" "compose: light マーカーは 2 行目"
assert_eq "pass" "$(extract_review_verdict_from_text "$OUT_LIGHT")" "統合: light でもパーサ pass"

# --- rvp_validate_body: findings 本文の契約 ---
if rvp_validate_body "$BODY_FACTS" >/dev/null 2>&1; then
  PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} validate: 事実本文は受理"
else
  FAIL=$((FAIL + 1)); ERRORS+=("validate: 事実本文は受理"); echo -e "  ${RED}✗${NC} validate: 事実本文は受理"
fi
# 見出し・判定セクションを含む本文は拒否（二重付与とパーサ二重判定を防ぐ）
if rvp_validate_body "## レビュー結果
$BODY_FACTS" >/dev/null 2>&1; then
  FAIL=$((FAIL + 1)); ERRORS+=("validate: 見出し入り本文は拒否"); echo -e "  ${RED}✗${NC} validate: 見出し入り本文は拒否"
else
  PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} validate: 見出し入り本文は拒否"
fi
if rvp_validate_body "$BODY_FACTS
### 判定
pass" >/dev/null 2>&1; then
  FAIL=$((FAIL + 1)); ERRORS+=("validate: 判定セクション入り本文は拒否"); echo -e "  ${RED}✗${NC} validate: 判定セクション入り本文は拒否"
else
  PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} validate: 判定セクション入り本文は拒否"
fi

# --- Major 修正の回帰（PR {ISSUE-ID} full レビュー） ---
echo "test-review-verdict: full レビュー Major 修正"

# {ISSUE-ID}: 判定系見出し（## 総合判定 / #### 判定）はパーサが判定節として先に拾うため拒否する
if rvp_validate_body "$BODY_FACTS
## 総合判定
勝手な verdict" >/dev/null 2>&1; then
  FAIL=$((FAIL + 1)); ERRORS+=("validate: '## 総合判定' 見出しは拒否"); echo -e "  ${RED}✗${NC} validate: '## 総合判定' 見出しは拒否"
else
  PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} validate: '## 総合判定' 見出しは拒否"
fi
if rvp_validate_body "$BODY_FACTS
#### 判定" >/dev/null 2>&1; then
  FAIL=$((FAIL + 1)); ERRORS+=("validate: '#### 判定' 見出しは拒否"); echo -e "  ${RED}✗${NC} validate: '#### 判定' 見出しは拒否"
else
  PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} validate: '#### 判定' 見出しは拒否"
fi
# 「判定」を含むが見出し末尾でない行は受理（誤爆防止）
if rvp_validate_body "$BODY_FACTS
判定基準は testing.md を参照。" >/dev/null 2>&1; then
  PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} validate: 地の文の「判定」は受理"
else
  FAIL=$((FAIL + 1)); ERRORS+=("validate: 地の文の「判定」は受理"); echo -e "  ${RED}✗${NC} validate: 地の文の「判定」は受理"
fi

# --- review-verdict-post.sh 引数堅牢性（{ISSUE-ID}/{ISSUE-ID}・alarm でハング防止） ---
RVP_SH="$ROOT/claude-hooks/review-verdict-post.sh"
TMPB="$(mktemp)"; printf '%s' "$BODY_FACTS" > "$TMPB"

# {ISSUE-ID}: 末尾値なしフラグは exit 64（旧実装は無限ループ）
perl -e 'alarm 5; exec @ARGV' -- bash "$RVP_SH" 1 --major 0 --tests green --high-risk no --body-file "$TMPB" --critical >/dev/null 2>&1
RC=$?
assert_eq "64" "$RC" "post: 末尾値なし --critical は exit 64（ハングしない）"

# {ISSUE-ID}: --high-risk は必須（省略で pass に倒れる permissive 既定を廃止）
perl -e 'alarm 5; exec @ARGV' -- bash "$RVP_SH" 1 --critical 0 --major 0 --tests green --body-file "$TMPB" >/dev/null 2>&1
RC=$?
assert_eq "64" "$RC" "post: --high-risk 省略は exit 64（必須化）"
rm -f "$TMPB"

# --- 成功パス（gh モック）: 投稿成功時に exit 0 + VERDICT 行（$PR+日本語括弧の誤パース回帰・dogfooding 実測バグ） ---
GH_MOCK_DIR2="$(mktemp -d)"
printf '#!/bin/bash\necho "https://example.test/pr/1#c"\nexit 0\n' > "$GH_MOCK_DIR2/gh"; chmod +x "$GH_MOCK_DIR2/gh"
TMPB2="$(mktemp)"; printf '%s' "$BODY_FACTS" > "$TMPB2"
OUT_OK="$(PATH="$GH_MOCK_DIR2:$PATH" perl -e 'alarm 5; exec @ARGV' -- bash "$RVP_SH" 1 --critical 0 --major 0 --tests green --high-risk no --body-file "$TMPB2" 2>&1)"
RC=$?
assert_eq "0" "$RC" "post: 成功パスは exit 0（\$PR 日本語括弧の誤パース回帰）"
assert_contains "VERDICT=pass" "$OUT_OK" "post: VERDICT 行を出力"
rm -rf "$GH_MOCK_DIR2" "$TMPB2"

# --- pass 後の確認不要ガイダンス（{ISSUE-ID} Phase 3・シンプルプロンプトで AskUserQuestion を出さない） ---
assert_contains "確認" "$OUT_OK" "post: stdout に確認不要ガイダンスがある"
assert_contains "マージまでを含む" "$OUT_OK" "post: 依頼スコープ（マージまで）を明示"

# --- 言語不変判定マーカー（{ISSUE-ID} の構造解決・{ISSUE-ID}）---
echo "test-review-verdict: 言語不変判定マーカー"
# verdict → 言語不変トークン（pass/needs-review/fail）
assert_eq "pass"         "$(rvp_verdict_to_marker_token pass)"   "marker token: pass"
assert_eq "needs-review" "$(rvp_verdict_to_marker_token 要確認)" "marker token: 要確認→needs-review"
assert_eq "fail"         "$(rvp_verdict_to_marker_token fail)"   "marker token: fail"
# compose が言語不変マーカーを刻印する（見出し・判定節の自然言語に依存しない機械可読判定）
assert_contains "<!-- review-verdict: pass -->"         "$OUT_PASS" "compose: pass マーカーを刻印"
assert_contains "<!-- review-verdict: needs-review -->" "$OUT_YK"   "compose: 要確認→needs-review マーカーを刻印"
assert_contains "<!-- review-verdict: fail -->"         "$OUT_FAIL" "compose: fail マーカーを刻印"
# 英語見出し + 判定節なし + マーカーのみでも verdict を抽出（{ISSUE-ID} の実害を構造的に解消）
EN_MARKER_ONLY="## Review Result

An English review body without any Japanese judgment section.

<!-- review-verdict: fail -->"
assert_eq "fail" "$(extract_review_verdict_from_text "$EN_MARKER_ONLY")" "統合: 英語本文+マーカーのみで fail 抽出（{ISSUE-ID} 解消）"

# --- 表示文言の言語追随---
# 不変条件: 表示（見出し・判定節・判定ラベル）は言語に追随するが、
#   機械可読マーカーと実パーサの抽出結果は**言語不変**（= auto-merge 連鎖が切れない）。
echo "test-review-verdict: 表示文言の言語追随"

# en: 見出し・判定節・判定ラベルが英語になる
OUT_EN_PASS="$(CC_AUTOSHIP_LANG=en rvp_compose_comment "$BODY_FACTS" pass 0 0 green no "")"
assert_contains "## Review Result" "$OUT_EN_PASS" "compose(en): 見出しが英語"
assert_contains "### Verdict"      "$OUT_EN_PASS" "compose(en): 判定節見出しが英語"

OUT_EN_YK="$(CC_AUTOSHIP_LANG=en rvp_compose_comment "$BODY_FACTS" 要確認 0 2 green no "")"
# 太字ラベルで検証する（素の "needs-review" だとマーカー <!-- review-verdict: needs-review -->
# に誤マッチし、ラベルが日本語のままでも通ってしまうため）
assert_contains "**needs-review**" "$OUT_EN_YK" "compose(en): 判定ラベルが 要確認→needs-review"

OUT_EN_FAIL="$(CC_AUTOSHIP_LANG=en rvp_compose_comment "$BODY_FACTS" fail 1 0 red no "")"

# ★ 最重要の不変条件: en でもマーカーは言語不変トークンで刻印され、実パーサが抽出できる
#   （v0.1.16 の「英語だと auto-merge 連鎖が黙って切れる」の再演を防ぐ回帰テスト）
assert_contains "<!-- review-verdict: pass -->"         "$OUT_EN_PASS" "compose(en): マーカーは言語不変（pass）"
assert_contains "<!-- review-verdict: needs-review -->" "$OUT_EN_YK"   "compose(en): マーカーは言語不変（needs-review）"
assert_contains "<!-- review-verdict: fail -->"         "$OUT_EN_FAIL" "compose(en): マーカーは言語不変（fail）"
assert_eq "pass"   "$(extract_review_verdict_from_text "$OUT_EN_PASS")" "統合(en): 英語表示でも pass 抽出（連鎖維持）"
assert_eq "要確認" "$(extract_review_verdict_from_text "$OUT_EN_YK")"   "統合(en): 英語表示でも 要確認 抽出（連鎖維持）"
assert_eq "fail"   "$(extract_review_verdict_from_text "$OUT_EN_FAIL")" "統合(en): 英語表示でも fail 抽出（連鎖維持）"

# ja: 既存出力の後方互換（日本語のまま）
OUT_JA_PASS="$(CC_AUTOSHIP_LANG=ja rvp_compose_comment "$BODY_FACTS" pass 0 0 green no "")"
assert_contains "## レビュー結果" "$OUT_JA_PASS" "compose(ja): 見出しは日本語のまま（後方互換）"
assert_contains "### 判定"        "$OUT_JA_PASS" "compose(ja): 判定節は日本語のまま（後方互換）"
OUT_JA_YK="$(CC_AUTOSHIP_LANG=ja rvp_compose_comment "$BODY_FACTS" 要確認 0 2 green no "")"
assert_contains "**要確認**" "$OUT_JA_YK" "compose(ja): 判定ラベルは 要確認 のまま（後方互換）"
assert_eq "要確認" "$(extract_review_verdict_from_text "$OUT_JA_YK")" "統合(ja): 日本語表示でも 要確認 抽出"

# light マーカーの位置は言語に依らず 2 行目（review.md 不変条件）
OUT_EN_LIGHT="$(CC_AUTOSHIP_LANG=en rvp_compose_comment "$BODY_FACTS" pass 0 0 green no "light")"
assert_eq "<!-- review:light -->" "$(printf '%s\n' "$OUT_EN_LIGHT" | sed -n '2p')" "compose(en): light マーカーは 2 行目"

# validate: 英語の見出し・判定節も拒否する（スクリプトが付与するため二重付与を防ぐ）
if rvp_validate_body "## Review Result
$BODY_FACTS" >/dev/null 2>&1; then
  FAIL=$((FAIL + 1)); ERRORS+=("validate: 英語見出し入り本文は拒否"); echo -e "  ${RED}✗${NC} validate: 英語見出し入り本文は拒否"
else
  PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} validate: 英語見出し入り本文は拒否"
fi
if rvp_validate_body "$BODY_FACTS
### Verdict
pass" >/dev/null 2>&1; then
  FAIL=$((FAIL + 1)); ERRORS+=("validate: 英語判定節入り本文は拒否"); echo -e "  ${RED}✗${NC} validate: 英語判定節入り本文は拒否"
else
  PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} validate: 英語判定節入り本文は拒否"
fi
# 地の文の "Verdict" は受理（誤爆防止・日本語版の「判定基準は…」と対称）
if rvp_validate_body "$BODY_FACTS
See review.md for the verdict rules." >/dev/null 2>&1; then
  PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} validate: 地の文の verdict は受理"
else
  FAIL=$((FAIL + 1)); ERRORS+=("validate: 地の文の verdict は受理"); echo -e "  ${RED}✗${NC} validate: 地の文の verdict は受理"
fi

# --- zsh 経路の回帰（{ISSUE-ID} 実測バグ）---
# hook 本体は bash だが lib はスキル経由で zsh から source されることがある。zsh では
# status が read-only（$? のエイリアス）なので `local status=...` が失敗し、判定ラベルが
# 空文字になる事故が起きた。**bash で走る本テストでは原理的に検出できない**ため、zsh が
# 使える環境でだけ実際に zsh で評価して回帰を止める（無い環境ではスキップ）。
if command -v zsh >/dev/null 2>&1; then
  ZSH_LABEL="$(zsh -c "source '$ROOT/claude-hooks/lib/language-config.sh'; lc_verdict_label 要確認 en" 2>/dev/null)"
  assert_eq "needs-review" "$ZSH_LABEL" "zsh: 判定ラベルが空にならない（status 予約変数の回帰）"
  ZSH_COMPOSE="$(zsh -c "source '$ROOT/claude-hooks/lib/review-verdict.sh'; CC_AUTOSHIP_LANG=en rvp_compose_comment 'B' 要確認 0 2 green no ''" 2>/dev/null)"
  assert_contains "**needs-review**"                      "$ZSH_COMPOSE" "zsh: compose(en) の判定ラベルが出る"
  assert_contains "<!-- review-verdict: needs-review -->" "$ZSH_COMPOSE" "zsh: compose のマーカーは言語不変"
else
  echo "  - zsh 未インストールのため zsh 回帰テストはスキップ"
fi