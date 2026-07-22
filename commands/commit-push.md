---
model: sonnet
description: スコープ/フロー チェック・レビュー・README更新・コミット・プッシュを一気通貫で実行
allowed-tools:
  - Read
  - Edit
  - Write
  - Glob
  - Grep
  - Bash(git:*)
  - Bash(gh:*)
  - Bash(npm:*)
  - Bash(npx:*)
  - Bash(turbo:*)
  - Bash(node:*)
  - Bash(vitest:*)
  - Bash(jest:*)
  - Bash(eslint:*)
  - Bash(tsc:*)
  - Skill(monorepo-manager)
  - Skill(monorepo-manager:*)
  - Skill(review)
  - Skill(review:*)
---

以下の手順で commit/push を実行する。

## 手順

### 1. スコープ/フロー チェック（pre-commit）
- `/monorepo-manager pre-commit` を実行し、整合性・フロー遵守を確認する
- **BLOCK**（❌）がある場合: 修正してから次へ進む
- **WARN**（⚠️）がある場合: 注意事項を確認し、問題なければ続行
- **PASS**（✅）の場合: そのまま続行
- 軽微変更（変更5行以下の typo・文言修正、`.md` のみの変更）はチェックをスキップしてよい

### 2. コードレビュー（pre-commit）
- **review スキルを起動**し（このリポジトリの review コマンド）、コード品質・テストを確認する
  - スラッシュ記法（`/review`）で呼ばないこと。プラグイン経由のインストール時は `/review` が `/cc-autoship:review` にプレフィックスされてこの記法では解決できず、Claude Code 組込の `code-review` スキル（`dynamic workflow` の課金プロンプトを出す別物）に shadow されることがある。必ず**このプラグインの review スキルを名前で起動**する（`post-tool-use-pr-created.sh` が post-PR 経路で採る「スキル名を起動」形式と同一の回避策）
- テストが失敗する場合は修正してから次へ進む
- `.md` ファイルのみの変更、設定ファイルのみの変更など、コードレビュー不要な場合はスキップしてよい

> **スキップ判断の境界（迷ったらこの表）**:
>
> | 状況 | 判断 |
> |------|------|
> | typo・文言修正 ≤5 行 / 一般 .md のみ | ステップ 1・2 ともスキップ可 |
> | .md のみだが**旗艦ドキュメント**（CLAUDE.md / `rules/*` / 公開 README） | ステップ 1 は実行する（スコープ・フロー整合は文書でも壊れ、マージ直後から全セッションの挙動を変える）。ステップ 2 はスキップ可 |
> | 設定ファイルのみ（`*.json` / `*.yml`） | ステップ 2 の検証は該当分のみ実行（yamllint / スキーマ・JSON parse）。「設定だから安全」ではない — エラーを出す検出器が無い変更ほど手動確認が要る |
> | テストファイルのみ | ステップ 1 スキップ可・ステップ 2 は対象テストを必ず実行し**件数が出たこと**まで確認（0 件実行の exit 0 は green ではない） |
> | 迷った | スキップしない側に倒す（スキップで浮く数分 < 見逃しの手戻り） |
>
> **アンチパターン**: 「.md だから」の一括スキップ（rules 変更は実質コード変更）/ 5 行以下でも意味が変わる変更（判定条件・閾値・パス・コマンド）をスキップ扱いにする

### 3. README・仕様書の更新
- 関連 README および仕様書を最新の状態に更新する

### 4. コミット
- 対応内容の粒度に合わせてコミットを分割する
- コミットメッセージは `type(scope): 説明` 形式を遵守する

### 5. デプロイプレビュートリガー判定（push 直前、optional）
- Vercel 等のプレビューデプロイで `feat/*` ブランチがデフォルトスキップされる構成の project の場合、push 直前に `[preview]` 空コミットを追加してプレビューを発火させる
- project 側に preview-trigger スクリプトが配置されているなら呼び出す（無ければスキップ可）
- スクリプト未配置の project では、必要な PR でのみ手動で `git commit --allow-empty -m '[preview] ...'` を追加する

### 6. プッシュ
- リモートにプッシュする

> **補足ルール: PR 作成時の `Closes` 記法**
>
> `/commit-push` は commit + push までのスキルで PR 作成自体は別工程だが、push 後に PR を作成する際は以下のルールに従う:
>
> - GitHub Issue クローズ: `Closes #<数字>` 例: `Closes #<num>`
> - 外部 tracker（Linear / Jira 等）を使う案件は `docs/optional-integrations.md` を参照
>
> 詳細: `rules/dev-flow.md` の「PR 本文の Closes 記法」セクション。

> **PR 作成後の自動チェーン**: 後続で `gh pr create` を実行すると PostToolUse hook が `/review` と `/pr-context-summary --mode pre-merge` を順序付きで自動で促す（`scripts/claude-hooks/post-tool-use-pr-created.sh` を project 側で配置）。`/commit-push` 側で明示的に呼び出す必要はない。詳細は `rules/dev-flow.md` の「PR 作成後の hook」セクションを参照。
