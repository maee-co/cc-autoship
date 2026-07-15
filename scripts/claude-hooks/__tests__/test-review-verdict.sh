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