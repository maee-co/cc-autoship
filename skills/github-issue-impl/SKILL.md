---
name: github-issue-impl
description: GitHub Issue 番号を指定して内容を読み込み、コードベースを調査して実装計画を立て実装を開始する
user-invocable: true
allowed-tools: Bash, Read, Glob, Grep, Agent, Write, Edit, ToolSearch
---

# /github-issue-impl

GitHub Issue の番号を指定して、内容を読み込み → コードベース調査 → 実装計画策定 → 実装を行う。

## 使い方

```
/github-issue-impl 59
/github-issue-impl #<N>
/github-issue-impl 59 --plan-only
/github-issue-impl 59 --team
```

## 引数

| 引数 | 説明 | デフォルト |
|------|------|-----------|
| (位置引数) | Issue 番号（`#59` or `59`） | 必須 |
| `--plan-only` | 実装計画のみ出力、コード変更しない | false |
| `--team` | Agent Teams で並行実装 | false |

## 手順

### ステップ 1: Issue データ取得

1. 引数から Issue 番号を抽出する（`#` プレフィックスがあれば除去）

2. **`gh` 認証チェック**（最初に実行）:
   ```bash
   gh auth status
   ```
   未認証の場合はエラーメッセージを表示し、`gh auth login` を案内して終了する

3. Issue データを取得:
   ```bash
   gh issue view {NUMBER} --json title,body,labels,assignees,comments,state
   ```

4. **Issue 状態チェック**:
   - Issue が存在しない場合 → エラーメッセージを表示して終了
   - Issue が `closed` の場合 → ユーザーに「この Issue は既にクローズされています。再オープンして作業しますか？」と確認

5. Issue 本文を構造化パース:
   - 概要セクション
   - 原因調査セクション（根本原因のリスト）
   - 修正案セクション
   - 再現手順（bug の場合）
   - 実装方針（feature の場合）
   - 完了条件（task の場合）

6. ラベルから type を判定（`bug`, `enhancement`, etc.）

7. **対象アプリの特定**: 以下の順序で推論:
   - Issue タイトルの `[App名]` パターン
   - Issue 本文中のファイルパスから `apps/{app}/` を抽出
   - ラベルからアプリ名を推論
   - 特定できない場合はユーザーに確認

8. **GitHub Issue で着手を可視化（任意）**:

   着手前に GitHub Issue へコメントを残すと、並行セッションとの衝突を避けられ、後から経緯を追える。

   ```bash
   gh issue comment <Issue番号> --body "🤖 Claude Code が実装に着手します"
   ```

   外部 Issue トラッカー（Linear 等）と連携したい場合は、MCP を別途設定して各自のフローに組み込む。

### ステップ 2: コードベース確認

1. Issue 本文中のファイルパス・行番号を正規表現で抽出:
   - パターン: `` `{path}:{line}` ``, `` `{path}` `` 等
2. 該当ファイルを Read して現在の状態を確認
   - Issue 作成後にコードが変更されていないかチェック（`git log --since` で確認）
   - 変更がある場合はユーザーに報告し、続行するか確認
3. 関連テストを Grep/Glob で探索:
   ```
   {対象ファイル名のベース名}.test.ts
   {対象ファイル名のベース名}.spec.ts
   __tests__/{対象ファイル名のベース名}.*
   ```
4. 依存コード（import 元/先）を確認

### ステップ 3: 実装計画の策定

1. Issue の修正案をベースに具体的な変更リストを作成
2. 以下の形式で計画を構造化:
   ```
   ## 実装計画: {Issue タイトル}

   ### 変更ファイル一覧
   | ファイル | 変更内容 | 優先度 |
   |---------|---------|--------|
   | `path/to/file.ts` | {変更内容} | 高 |

   ### 実装ステップ
   1. [ ] {ステップ1}: {詳細}
   2. [ ] {ステップ2}: {詳細}

   ### テスト計画
   - [ ] {テスト1}
   - [ ] {テスト2}

   ### リスク・注意点
   - {リスク1}
   ```
3. `--plan-only` の場合はここで計画を出力して終了

### ステップ 4: 実装

#### 4.0: worktree 作成（実装前に必須）

実装は **必ず `.claude/worktrees/` 配下の worktree** で行う。`pre-tool-use.sh` フックは `.claude/worktrees/` 配下のパスでのみ main 上の commit/push 例外を許可するため、**規約外（リポジトリ兄弟ディレクトリ等）に worktree を作ると初手の commit でブロックされる**（{ISSUE-ID} / cc-autoship live 検証で実発生）。

```bash
# ブランチ名は dev-flow 規約に従う: feat/{ISSUE-ID}-{scope}-{説明}（bugfix は fix/...）
BRANCH="feat/{ISSUE-ID}-{scope}-{説明}"
git worktree add ".claude/worktrees/${BRANCH}" -b "$BRANCH" origin/main
cd ".claude/worktrees/${BRANCH}"
```

- worktree パス・ブランチ命名規約の SSoT は `rules/dev-flow.md`「worktree 運用ルール」「命名規則」
- commit/push 時は worktree に `cd` 済み、または `git -C .claude/worktrees/...` を使う（フック例外パターンに合致させる）

#### 通常モード

1. 計画に沿って Edit/Write でコード変更を実施
2. 各変更後にテストを実行:
   ```bash
   cd apps/{app} && pnpm test
   ```
   pnpm test が存在しない場合は `npm test` にフォールバック
3. テストが失敗した場合は修正してから次のステップに進む
4. 全変更完了後に最終テスト実行

#### Team モード（`--team` 指定時）

1. 以下の順序で team-config.md を探索:
   - `apps/{app}/team-config.md`
   - リポジトリルートの `team-config.md`
2. team-config.md が見つからない場合はユーザーに通知し、通常モードにフォールバック
3. team-config.md に基づき Agent Teams を起動（`/start-team` スキルを活用）
4. 計画の各ステップをタスクとして分配

#### 進捗記録

変更ごとに `progress/{app名}.md` に進捗を追記:
```markdown
### {日付} Issue #{番号} 対応
- {変更内容のサマリー}
```

### ステップ 5: 完了報告

1. Issue にコメントを追加（`--body-file` でシェル特殊文字を回避）:
   ```bash
   cat <<'COMMENT_EOF' > /tmp/github-issue-comment.md
   修正コミット: $(git log -1 --format=%H)

   ### 変更内容
   {変更サマリー}

   ### テスト結果
   {テスト実行結果のサマリー}
   COMMENT_EOF

   gh issue comment {NUMBER} --body-file /tmp/github-issue-comment.md
   rm -f /tmp/github-issue-comment.md
   ```

2. ユーザーに変更サマリーを報告:
   - 変更ファイル一覧
   - テスト結果
   - Issue URL

3. ユーザーに次のアクションを確認:
   - Issue をクローズするか
   - コミットを作成するか
   - PR を作成するか

## 安全ルール

- Issue に記載のないファイルへの変更は事前にユーザーに確認する
- `--team` モードでは各エージェントのスコープ外編集を禁止する
- コードスニペットに `.env` の値・API Key・個人情報が含まれていないか確認する