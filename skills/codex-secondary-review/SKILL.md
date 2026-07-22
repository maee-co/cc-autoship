---
model: sonnet
name: codex-secondary-review
description: Claude /review 後の opt-in 二次レビュー。PR diff を Codex (`gpt-5-codex`) に渡し外部 API 仕様・最小権限・Promise 未捕捉・リファクタ整合性を補完。Hook 自動起動 + 手動呼び出し対応
user-invocable: true
allowed-tools: Read, Bash, Agent
---

# /codex-secondary-review

Claude 一次レビュー (`/review`) の補完として、Codex に同じ PR をレビューさせ、結果をマーカー付きで PR コメントに投稿する。

## 設計方針

- **Claude が authoritative**: `/auto-merge` の Critical/Major 集計に Codex 指摘は **含めない**。Codex は参考情報
- **opt-in 起動**: 条件を満たした PR のみ自動起動する（hook 経由）。手動でも呼べる
- **二重投稿抑止**: コメント先頭の `<!-- codex-secondary-review:PR#{n} -->` マーカーで再投稿を防ぐ
- **静かに失敗**: Codex CLI 未認証 / API エラーは `/auto-merge` フローを巻き込まない

詳細は `rules/dev-flow.md` の「Codex 二次レビュー」セクションを参照。

## 使い方

```
# PR 番号を明示
/codex-secondary-review 283

# 現在ブランチから自動推論
/codex-secondary-review
```

### 引数

| 引数 | 説明 | デフォルト |
|------|------|-----------|
| `<PR番号>` | 対象 PR 番号 | 現在ブランチから自動推論 |

## 起動条件（hook 側で評価済み）

このスキルが呼ばれる時点で、`scripts/claude-hooks/lib/codex-trigger-criteria.sh` による評価で以下のいずれかを満たしている:

1. PR diff に外部 API 連携キーワードを含むファイル変更: `discord` / `slack` / `notion` / `openai` / `anthropic` / `webhook` / `mcp`
2. PR 規模 ≥ 500 行 OR ≥ 10 ファイル
3. PR 本文に `[codex-review]` タグ（明示 opt-in）
4. セキュリティ修正系 PR: PR タイトル / 本文にセキュリティ意図キーワード（`脆弱性` / `XSS` / `CSRF` / `SSRF` / `SQL injection` / `権限昇格` / `認証バイパス` / `RLS` / `OWASP` / `CVE-XXXX` 等）を含む

opt-out: PR 本文に `[no-codex]` タグ → hook 側で抑止（起動条件 4 より優先）

## 手順

### Step 1: PR 番号の解決

引数から PR 番号を取得。未指定なら現在ブランチから推論:

```bash
PR_NUM="$1"
if [ -z "$PR_NUM" ]; then
  PR_NUM=$(gh pr view --json number -q .number 2>/dev/null)
fi
if [ -z "$PR_NUM" ]; then
  echo "現在のブランチに紐づく PR が見つかりません。PR 番号を指定してください"
  exit 1
fi
```

### Step 2: 重複投稿チェック

マーカーが既存コメントにあれば再投稿しない:

```bash
EXISTING=$(gh pr view "$PR_NUM" --json comments \
  --jq ".comments[].body" \
  | grep -c "<!-- codex-secondary-review:PR#${PR_NUM} -->" || true)

if [ "${EXISTING:-0}" -gt 0 ]; then
  echo "PR #${PR_NUM} には既に Codex 二次レビューが投稿済みです。スキップします"
  exit 0
fi
```

### Step 3: PR メタデータ取得

タイトル・ブランチ・規模を取得（プロンプト構築用）:

```bash
PR_META=$(gh pr view "$PR_NUM" --json title,headRefName,additions,deletions,changedFiles,body)
PR_TITLE=$(printf '%s' "$PR_META" | jq -r '.title')
PR_BRANCH=$(printf '%s' "$PR_META" | jq -r '.headRefName')
PR_ADDS=$(printf '%s' "$PR_META" | jq -r '.additions')
PR_DELS=$(printf '%s' "$PR_META" | jq -r '.deletions')
PR_FILES=$(printf '%s' "$PR_META" | jq -r '.changedFiles')
```

### Step 3.5: Codex 可用性の事前判定（spawn せず静かにスキップ・{ISSUE-ID}）

`codex:codex-rescue` エージェントが無い環境（Codex 未導入 = 公開利用者の大多数）で Agent spawn を試みると「Agent type 'codex:codex-rescue' not found」エラーが**一瞬表示されてから** graceful skip になる。spawn の**前に**非ネットワーク・決定的に可用性を判定し、無ければエラーを見せずにスキップする:

判定は `lib/codex-availability.sh` の純関数に切り出してある（テスト: `__tests__/test-codex-availability.sh`）:

```bash
# CLAUDE_PROJECT_DIR 未設定でも source 失敗のエラー行を出さない（本スキルの目的と整合）
CSR_LIB="${CLAUDE_PROJECT_DIR:-.}/.claude/skills/codex-secondary-review/lib/codex-availability.sh"
CODEX_AVAILABLE=0
if [ -f "$CSR_LIB" ] && . "$CSR_LIB" 2>/dev/null && csr_codex_available_default; then
  CODEX_AVAILABLE=1
fi
echo "CODEX_AVAILABLE=${CODEX_AVAILABLE}"
```

- `CODEX_AVAILABLE=0` なら **Step 4 の Agent 呼び出しを行わず**、「Codex が利用できない環境のため二次レビューをスキップしました」と 1 行報告して終了する（コメント非投稿・auto-merge 非ブロック = 既存の「静かに失敗」と同じ帰結を、エラー表示なしで実現）
- 判定は 3 条件の AND（すべて非ネットワーク・決定的）:
  1. CLI 実在（`command -v codex`）
  2. **プラグインが `enabledPlugins` で有効**（{ISSUE-ID} で追加）— `.claude/settings.local.json` → `.claude/settings.json` → `~/.claude/settings.json` の優先順で最初の明示値を採用し、**どこにも無ければ「無効」**
  3. agent 定義ファイル実在（plugin cache `agents/codex-rescue.md` / プロジェクト直下のどちらか）
- 判定が誤って可用と出た場合（定義ファイルは在るがセッションに未ロード等）は、従来どおり Step 4 の spawn 失敗 → 静かに失敗にフォールバックする（安全側の二段構え）
- **判定不能（jq 不在 / 設定 JSON 破損）は不可用に倒す** — 二次レビューは補助情報でありスキップしても `/auto-merge` をブロックしないため、取りこぼしより誤エラー表示を避ける

> **なぜ条件 2 が要るか**: 条件 1・3 だけだと「plugin cache は残っているがプラグインが**有効化されていない**」状態（installed ≠ enabled）を可用と誤判定する。PR #N で実際に `Agent type 'codex:codex-rescue' not found` が再発した。「不在 = 既定で有効」と読まないこと — 実測では enabledPlugins にエントリが無いプラグインはロードされていない。

### Step 4: Codex に二次レビューを依頼

このステップは **Claude が `Agent` ツールを呼び出す** ことで実行する（bash で自動実行されるわけではない）。`subagent_type` には `codex:codex-rescue` を指定し、以下の構造のプロンプトを渡す。

**Agent 呼び出しパラメータ**:

- `description`: `Codex secondary review PR #${PR_NUM}`
- `subagent_type`: `"codex:codex-rescue"`
- `prompt`: 下記テンプレートに Step 3 で取得した変数を埋め込んだ文字列

**プロンプトテンプレート**（変数は Step 3 で取得した実値に置換）:

```
GitHub PR #${PR_NUM} (${PR_TITLE}, branch: ${PR_BRANCH}, ${PR_ADDS} additions / ${PR_DELS} deletions / ${PR_FILES} files) の二次レビューを依頼する。

リポジトリ: (現在のリポジトリ)
PR 取得: `gh pr view ${PR_NUM} --json title,body,files` と `gh pr diff ${PR_NUM}` で確認できる。

これは Claude /review の補完として動く二次レビューです。**Claude が見落としやすい以下の観点を重点的に**:
1. 外部 API 仕様への入力整形（文字数制限・URL バリデーション・スキーマ）
2. Web API のライフサイクル（user activation・transient state・session 失効）
3. 最小権限原則・permission スコープ（特に Chrome 拡張 / OAuth / Webhook）
4. Promise / async の未捕捉例外・try-catch の漏れ
5. リファクタ後の整合性（allowed-tools・参照テスト・ドキュメント追従漏れ）

加えて、rules/code-review.md のチェックリスト 6 カテゴリ（型安全 / セキュリティ / テストカバレッジ / パフォーマンス / コード品質 / 依存・スコープ整合性）の観点も含める。

出力形式:
- Critical / Major / Minor / Nit に分類、各項目に file_path:line_number、根拠、推奨修正案
- 全体所感（マージ可否判定は Claude 一次レビュー側に委ねるため任意）

日本語で返答。
```

Agent ツールの返り値（Codex のレビュー本文）を Step 5 でコメント整形に使う。

### Step 5: Codex 出力を PR コメントとして投稿

Codex の出力を受け取り、マーカー付きでフォーマット:

```markdown
<!-- codex-secondary-review:PR#${PR_NUM} -->
## 🤖 Codex 二次レビュー

Claude `/review` の補完として、Codex (`gpt-5-codex`) で二次レビューを実施しました。Codex は外部 API 仕様・最小権限・Promise 未捕捉・リファクタ整合性などの観点で Claude が見落としやすい指摘を拾う傾向があります。

{Codex の出力本文をそのまま}

---

<sub>
- Claude `/review` が authoritative — Codex 指摘は `/auto-merge` の Critical/Major 集計に **含まれません**
- 起動条件: 外部 API キーワード変更 / 大規模 PR (≥500行 or ≥10ファイル) / `[codex-review]` タグ
- 抑止: PR 本文に `[no-codex]` を独立行で記載
</sub>
```

投稿:

```bash
gh pr comment "$PR_NUM" --body "$BODY"
```

### Step 6: 結果報告

メンテナ に以下を報告:
- PR 番号と投稿先
- Codex の Critical / Major 件数（参考値）
- スキップした場合（既存マーカーあり等）はその旨

## 重要ルール

- **二重投稿の抑止**: Step 2 のマーカーチェックは必須。Codex 出力を毎回再生成しないこと
- **`/auto-merge` への非影響**: コメント本文の Markdown 見出しが `## 🤖 Codex 二次レビュー` であり、auto-merge-after-review hook の検知パターン（`レビュー結果` / `レビュー指摘修正結果` / `一次レビュー`）には一致しない設計。再帰起動しない
- **マーカー文字列**: `<!-- codex-secondary-review:PR#{n} -->` 形式を厳密に守る。hook 側もこのマーカーで自分自身の投稿を除外する
- **個人情報除去**: Codex 出力に万一トークン / API キーが含まれていたら投稿前に `[REDACTED]` に置換する

## エッジケース

| ケース | 対応 |
|--------|------|
| PR 番号未指定 + 現在ブランチに PR なし | エラー終了、`<PR番号>` 指定を促す |
| 既にマーカー付きコメントあり | スキップ（再投稿しない） |
| Codex 未導入（CLI なし / agent 定義なし） | Step 3.5 の事前判定で **spawn せず**静かにスキップ（エラー表示ゼロ・{ISSUE-ID}） |
| Codex は installed だが**未有効**（`enabledPlugins` に無い / `false`） | 同上（{ISSUE-ID} で追加。cache 残存のまま無効化された状態を可用と誤判定しない） |
| Codex CLI 未認証 / 起動失敗 | 静かに失敗（PR コメント投稿せず exit 0）。`/auto-merge` フローへの影響なし |
| Codex 出力が空 / 異常 | エラーログのみ stderr に出して exit 0、コメントは投稿しない |
| 引数に PR 番号以外の文字列 | 数値チェックで弾き、エラー終了 |

## チェーン呼び出し元

- `scripts/claude-hooks/post-tool-use-codex-secondary-review.sh`: Claude `/review` 完了後（**`review-verdict-post.sh` の実行**＝正規経路、または `gh pr comment` でレビュー結果見出し検知時）に起動条件を満たした PR で自動呼び出し
- 手動: メンテナ や Claude 自身が `/codex-secondary-review <PR#>` で任意のタイミングで起動可能