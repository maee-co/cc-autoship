# コードレビュー チェックリスト

実施時は [`docs/rules/code-review-checklist.md`](../docs/rules/code-review-checklist.md) の **全項目**を確認する。本ファイルは 6 カテゴリ名とレビュー対応コメントの要点のみ。

## チェックリスト 6 カテゴリ

1. **型安全** — `any` 回避・型定義/型ガード・`as` 最小限・ジェネリクス
3. **テストカバレッジ** — ユニットテスト・エッジケース・モック・既存テスト・**UI 変更を含む PR は L1 e2e（`apps/<app>/e2e/golden-path.spec.ts`・`@l1`）必須**（SSoT: `rules/testing.md`）
4. **パフォーマンス** — 再レンダリング・N+1・`next/image`・バンドルサイズ
5. **コード品質** — Server Components 優先・`"use client"` 最小限・DRY・エラーハンドリング・ESLint・UI 変更はキャプチャ添付・外部 API Skill は実行例/response 抜粋
6. **依存・スコープ整合性** — 担当スコープ内・共有パッケージ（`@core/typescript-config` 等）への影響・`turbo.json` 依存関係

各カテゴリの全チェック項目は [`docs/rules/code-review-checklist.md`](../docs/rules/code-review-checklist.md) を参照。

## レビュー対応 PR コメントの要点

`/review` の指摘・対応結果は **4 軸の表形式**（重要度 × 信頼度 × スコープ × 対応）でコメントする:

- **重要度（Critical / Major / Minor）と信頼度（0-100）は別軸**として併記する（実害の大小と実在確度を混同しない）
- **信頼度 80 未満の指摘は修正せず**「⏭️ 除外（80 未満）」と明記する（誤検知フィルタ。threshold 80 とルーブリックのアンカー `80`/`90` は `/review` で一貫）
- **スコープ列**で「今回の差分 / 既存問題」を区別し、既存問題は原則「📌 別 Issue」とする（本 PR では修正しない）
- 「対応」列は ✅ 完了 / ⏭️ 除外（80 未満）/ ⏭️ スキップ（理由）/ ⚠️ 一部対応 / 📌 別 Issue のいずれか
- **テスト結果は最低限 type-check / lint / test の 3 行**を含める
- 通常レビューは `## レビュー結果`、`--fix` は `## レビュー指摘修正結果` の見出しで投稿する
- **通常レビュー（指摘 → 修正 → テスト緑化）と `--fix`（既存コメントの再修正のみ）の責務を分ける**（境界は「指摘フェーズ → 修正フェーズ」。`/review`「モードと責務」）
- **light モード（`/review --light`・{ISSUE-ID}）**: light 分類 PR（PR 作成後 hook が引数で指示）の短縮レビュー。差分関連カテゴリのみ確認 + 実レビューを sonnet subagent に委譲する。**不変条件**: 見出し `## レビュー結果`・4 軸表・信頼度 80 閾値・判定ステータス・auto-merge 連動は維持（識別は本文 2 行目の `<!-- review:light -->` マーカー）。Critical/Major を検出したら通常レビューにエスカレする（詳細は `/review`「`--light` オプション」）
- **判定ステータス `pass` / `要確認` / `fail`** を明記し、`pass` のみ `/auto-merge` 可（`要確認` / `fail` はブロック。`rules/dev-flow-pr.md`「PR 自動マージ」と `/review`「判定」に接続）
- **信頼度スコアには算出根拠（ファイル・行 / rule 項目名 / 再現条件）を 1 行併記する**（推測での水増し防止。`/review`「スコアの算出根拠を併記する」）

フォーマットの SSoT は `/review` スキル（`commands/review.md`）。通常レビュー用テンプレは同「レビュー結果のコメント（通常レビュー）」、`--fix` 用と対応列の値の定義はステップ 7。テンプレート全文は [`docs/rules/code-review-checklist.md`](../docs/rules/code-review-checklist.md)「レビュー対応 PR コメントの標準フォーマット」。