---
model: sonnet
name: pr-context-summary
description: PR 作成時 / マージ後に メンテナとの意思決定サマリを GitHub Issue にコメント追記、後続タスクへ引き継ぐ
user-invocable: true
allowed-tools: Read, Bash
---

# /pr-context-summary

セッションで メンテナと交わした意思決定・要望・没案を要約し、PR に紐づく GitHub Issue にコメントとして残すスキル。**振り返り** と **後続タスクへの方針引き継ぎ** に活用する。

## 使い方

```
# pre-merge: PR 作成完了時に呼ぶ（/commit-push 末尾から自動チェーン）
/pr-context-summary --mode pre-merge

# post-merge: マージ完了時に呼ぶ（/auto-merge 末尾・MERGED 検知時から自動チェーン）
/pr-context-summary --mode post-merge

# PR 番号 / Issue 番号を明示指定
/pr-context-summary --mode pre-merge --pr 226
/pr-context-summary --mode post-merge --pr 226 --issue 226

# 軽量 PR（docs-only / test-only / 小規模内部変更）は会話履歴の詳細抽出を省く
/pr-context-summary --mode pre-merge --pr 226 --lightweight

# post-merge を会話コンテキスト非依存で GitHub 状態から再構成する（F1・人手マージ検知等）
/pr-context-summary --mode post-merge --reconstruct --pr 226
```

### 引数

| 引数 | 説明 | デフォルト |
|------|------|-----------|
| `--mode` | `pre-merge` / `post-merge` | 必須 |
| `--pr` | PR 番号 | 現在ブランチから自動推論 |
| `--issue` | GitHub Issue 番号 | PR 本文の `Closes #XX` から自動抽出 |
| `--lightweight` | docs-only / test-only / 小規模内部変更向け。PR metadata・Issue・commit から**薄い専用テンプレート**で最小サマリを作り、会話履歴から詳細抽出しない | false |
| `--reconstruct` | `--mode post-merge` と併用。会話コンテキストが無いセッション（人手マージ後の別セッション・SessionStart 検知等）で、**通常 post-merge テンプレート**（レビュー指摘/メンテナ調整/追加判断の枠を持つもの）を会話ではなく GitHub 状態（レビュー・コメント・pre-merge サマリ）から埋める。`--lightweight` とは別経路（詳細は Step 5「post-merge を GitHub 状態から再構成する」） | false |

## 重要ルール

- **二重投稿を避ける**: 各コメントの先頭に HTML コメントマーカーを置き、同モードのマーカーが既存コメントにあれば再投稿しない
- **Issue が複数紐づく場合**: PR 本文から最初の `Closes #XX`（GitHub Issue）のみに投稿。Linear は GitHub 同期で自動的にコメントが反映されるため、Linear への直接投稿は行わない
- **粒度は中程度（20〜30 行）**: 後続タスクで引き継げるが、ノイズにならない量
- **個人情報・シークレットを含めない**: API キー、トークン、`.env` 内容は出力前に除去する

## 手順

### Step 1: 引数パース

```typescript
const argString = args || '';
const modeMatch = argString.match(/--mode\s+(pre-merge|post-merge)/);
const prMatch = argString.match(/--pr\s+(\d+)/);
const issueMatch = argString.match(/--issue\s+#?(\d+)/);
const lightweight = /\s--lightweight(\s|$)/.test(` ${argString} `);
const reconstruct = /\s--reconstruct(\s|$)/.test(` ${argString} `);

const mode = modeMatch?.[1];
let pr = prMatch?.[1];
let issue = issueMatch?.[1];

if (!mode) {
  // エラー: --mode は必須
  return error('--mode pre-merge|post-merge は必須です');
}
```

### Step 2: PR 番号の解決

`--pr` が未指定の場合、現在ブランチに紐づく PR を取得:

```bash
PR_NUM=$(gh pr view --json number -q .number 2>/dev/null)
```

取得できなかった場合はエラー終了:
- `現在のブランチに紐づく PR が見つかりません。--pr で指定してください`

### Step 3: Issue 番号の解決

`--issue` が未指定の場合、PR 本文から `Closes #XX` を抽出:

```bash
gh pr view "$PR_NUM" --json body --jq '.body' \
  | /usr/bin/grep -oiE '(close[sd]?|fixe[sd]?|resolve[sd]?|complete[sd]?|implement[sd]?)\s+#[0-9]+' \
  | head -1 \
  | /usr/bin/grep -oE '#[0-9]+' \
  | tr -d '#'
```

- 取得できた場合 → その Issue 番号を使用
- 取得できなかった場合 → スキップして PR 本体にコメント投稿（フォールバック）

### Step 4: 重複投稿チェック

同モードのマーカーが既存コメントにある場合は再投稿しない。

```bash
# Issue にコメント投稿する場合
EXISTING=$(gh issue view "$ISSUE" --json comments --jq '.comments[].body' \
  | /usr/bin/grep -c "<!-- pr-context-summary:${MODE}:PR#${PR_NUM} -->" || true)

if [ "${EXISTING:-0}" -gt 0 ]; then
  echo "既に ${MODE} サマリが投稿済みです（PR #${PR_NUM}）。スキップします"
  exit 0
fi
```

PR 本体にフォールバック投稿する場合も同様に `gh pr view "$PR_NUM" --json comments` でチェック。

### Step 5: サマリを生成

`--lightweight` / `--reconstruct` の有無で抽出元を切り替える（`--lightweight` は薄い専用テンプレート・`--reconstruct` は通常テンプレートを GitHub 状態で埋める・詳細は各節）。

#### lightweight モード

対象: docs-only / test-only / 小規模な内部ワークフロー変更など、メンテナとの追加判断が少ない軽量 PR。

- **PR metadata**: `gh pr view "$PR_NUM" --json title,body,commits,files,additions,deletions`
- **Issue metadata**: 解決済みなら `gh issue view "$ISSUE" --json title,body`
- **commit 情報**: PR の commit title / body
- **差分の粗い分類**: docs-only / test-only / infra / code などを files から判断
- **会話履歴から詳細抽出しない**: 採用案・没案・メンテナ判断の深掘りは行わず、PR 本文と Issue に残っている範囲だけを書く

lightweight でも、マーカー・投稿先・二重投稿チェックは通常モードと同じ。

#### 通常モード

Claude 自身が現在のセッションコンテキストを参照し、以下を抽出する。

#### pre-merge モード

セッション開始から PR 作成までの内容を対象:

- **着手時の指示・背景**: メンテナからの最初の依頼、前提条件
- **設計の選択肢と判断**: 検討した選択肢と メンテナが選んだもの
- **没にした案とその理由**: 検討したが採用しなかった案
- **実装の主要ポイント**: 設計上の重要な決定（具体的な diff ではなく「考え方」）
- **残課題・次の方針候補**: PR では扱わなかったが続きでやるべきこと

#### post-merge モード

PR 作成からマージまでの内容を対象:

- **レビュー指摘と対応**: `/review` の指摘 + 修正内容
- **メンテナの調整要望**: PR コメントや会話で メンテナが追加で指示した内容
- **マージ後の追加判断**: マージ直前/直後に決まった方針
- **次アクション**: フォローアップ Issue / PR の候補

#### post-merge を GitHub 状態から再構成する（会話非依存・F1・`--reconstruct`）

元セッション外（人手マージ後の別セッション、または SessionStart 検知経由）で `--mode post-merge --reconstruct` が呼ばれた場合、そのセッションには会話コンテキストが無いため、通常モードの「Claude 自身がセッションコンテキストを参照」は使えない。**`--lightweight` ではなくこちらを使う**（両者は別経路。詳細は下記「`--reconstruct` と `--lightweight` の違い」）。

生成物は **通常 post-merge テンプレート**（後述 Step 6「レビュー指摘と対応」「メンテナの調整要望・追加判断」「マージ後の次アクション」の 3 枠を持つもの）。ただし各セクションの内容は会話ではなく GitHub 状態から埋める:

- **Issue の既存 pre-merge サマリコメント**（マーカー `<!-- pr-context-summary:pre-merge:PR#N -->` で識別）: 着手時の指示・設計判断・残課題を引き継ぐ
- **PR のコメント/レビュー**: `gh pr view <PR> --json comments,reviews,mergedAt,mergeCommit`
  - 「レビュー指摘と対応」→ `reviews`（`/review` 等が投稿したレビューコメント）から抽出
  - 「メンテナの調整要望・追加判断」→ `comments`（PR 上で メンテナが追加指示したコメント）から抽出
- **closing issue の状態**: Issue がクローズ済みかどうか（`mergedAt` / `mergeCommit` と合わせてマージ結果の裏付けに使う）

上記から該当情報が取れないセクションは「なし」または「GitHub 状態から抽出できる情報なし」と明記する（会話ログには一切依存しない）。

##### `--reconstruct` と `--lightweight` の違い

- **`--reconstruct`**: テンプレートは**通常版のまま**（3 枠を維持）。情報源だけを会話から GitHub 状態（pre-merge サマリ・PR レビュー/コメント・Issue 状態）に差し替える
- **`--lightweight`**: テンプレート自体が**薄い専用テンプレート**（レビュー指摘等の枠を持たない）。元々「メンテナとの追加判断が少ない軽量 PR」向けで、レビュー/コメントの深掘り自体を意図的に省く設計

両者を混同しない: `--mode post-merge --lightweight` を呼ぶと薄いテンプレート節（Step 6「lightweight post-merge テンプレート」）に流れ、このセクションの再構成ロジックには到達しない。

二重投稿マーカー `<!-- pr-context-summary:post-merge:PR#N -->` は inline パス（`/auto-merge` からの通常呼び出し）と F1 パス（このセクション）で共通のため、どちらが先に投稿しても Step 4 の重複投稿チェックがもう一方を抑止する（マーカー方式を分ける必要はない）。

### Step 6: テンプレートで整形

`--reconstruct` 時も新規テンプレートは追加しない。後述の**通常 pre-merge / post-merge テンプレート**をそのまま使い、Step 5 で GitHub 状態から抽出した内容を各セクションに当てはめる（投稿フォーマットは inline 呼び出しと同一）。薄い専用テンプレートを使うのは `--lightweight` のときのみ。

#### lightweight pre-merge テンプレート

```markdown
<!-- pr-context-summary:pre-merge:PR#${PR_NUM} -->
## 🤖 PR コンテキストサマリ（PR 作成時・軽量）

**PR**: #${PR_NUM}

### 背景
{Issue title / PR title から 1-2 行}

### 変更の分類
- {docs-only / test-only / infra / code など}
- 変更量: +{additions} / -{deletions}

### 実装サマリ
- {PR metadata と commit から 1-3 点}

### 残課題
- {PR 本文に明記されたもの。なければ「なし」}

---
🤖 `/pr-context-summary --mode pre-merge --lightweight` により自動生成
```

#### lightweight post-merge テンプレート

```markdown
<!-- pr-context-summary:post-merge:PR#${PR_NUM} -->
## 🤖 PR コンテキストサマリ（マージ後追記・軽量）

**PR**: #${PR_NUM} (merged)

### マージ結果
- {PR title} をマージ済み

### 次アクション
- {Issue / PR body に明記された残課題。なければ「なし」}

---
🤖 `/pr-context-summary --mode post-merge --lightweight` により自動生成
```

#### pre-merge テンプレート

```markdown
<!-- pr-context-summary:pre-merge:PR#${PR_NUM} -->
## 🤖 PR コンテキストサマリ（PR 作成時）

**PR**: #${PR_NUM}

### 着手時の指示・背景
{1-3 行で要約}

### 設計の選択肢と メンテナの判断
- **採用**: {選んだ案} — {理由}
- **検討したが不採用**: {没案} — {理由}（複数あれば箇条書き / なければセクションごと省略）

### 実装の主要ポイント
- {ポイント 1}
- {ポイント 2}

### 残課題・次の方針候補
- {残課題 1}
- {次にやると良いこと}

---
🤖 `/pr-context-summary --mode pre-merge` により自動生成
```

#### post-merge テンプレート

```markdown
<!-- pr-context-summary:post-merge:PR#${PR_NUM} -->
## 🤖 PR コンテキストサマリ（マージ後追記）

**PR**: #${PR_NUM} (merged)

### レビュー指摘と対応
- {指摘 1} → {対応}（なければ「Critical/Major なし」）

### メンテナの調整要望・追加判断
- {要望 1} → {対応}
- {追加判断 1}

### マージ後の次アクション
- {フォロー Issue / PR の候補}

---
🤖 `/pr-context-summary --mode post-merge` により自動生成
```

該当なしのセクションは「なし」と書くか省略してよい。

### Step 7: コメント投稿

```bash
# Issue が解決していれば Issue に投稿、なければ PR にフォールバック
if [ -n "${ISSUE:-}" ]; then
  gh issue comment "$ISSUE" --body "$SUMMARY"
  echo "✅ Issue #${ISSUE} にコンテキストサマリを投稿しました"
else
  gh pr comment "$PR_NUM" --body "$SUMMARY"
  echo "✅ PR #${PR_NUM} にコンテキストサマリを投稿しました（Issue 未解決のためフォールバック）"
fi
```

### Step 8: 結果報告

メンテナに以下を報告:
- 投稿先（Issue 番号 or PR 番号）
- モード（pre-merge / post-merge）
- 既に同モードのサマリが投稿済みでスキップした場合はその旨

## エッジケース

| ケース | 対応 |
|--------|------|
| 現在ブランチに PR がない | エラー終了し `--pr` 指定を促す |
| PR 本文に `Closes #` がない | PR 本体へフォールバック投稿 |
| 同モードのマーカーが既存コメントにある | スキップ（再投稿しない） |
| post-merge を pre-merge より先に呼ばれた | 投稿は実行する（順序に依存しない） |
| 会話履歴がほぼ空（短いセッション） | 「特筆すべきやり取りなし」と明記して最小限のサマリを残す |
| トークン・APIキーが会話に登場 | 値を `[REDACTED]` に置換してから投稿 |

## チェーン呼び出し元

- `/commit-push`: PR 作成完了直後に `--mode pre-merge` で自動呼び出し
- `/auto-merge`: マージ成功直後に `--mode post-merge` で自動呼び出し（未充足時はハンドオフして停止し、人手マージ後は SessionStart の F1 検知が補う・{ISSUE-ID}）
- SessionStart（Task 6・F1 検知）: 人手マージ済みで post-merge 未投稿の PR を検知したら `--mode post-merge --reconstruct --pr <N>` で呼ぶ（`--lightweight` ではない）。`--reconstruct` を明示することで、会話コンテキストが無い状態でも Step 5「post-merge を GitHub 状態から再構成する（会話非依存・F1・`--reconstruct`）」の経路に確実に倒す

詳細は `rules/dev-flow.md` の「PR コンテキストサマリ」セクションを参照。