# 開発フロールール（Issue 駆動 + 自律実行）

## 基本原則

メンテナの指示を受けたら、自律判断で実行する。**確認が必要なケースのみメンテナに確認**する。

**依頼のスコープはマージまで**: ユーザーの単発依頼（「◯◯して」）は、Issue 作成 → 実装 → PR → レビュー → **マージまでのループ全体**の依頼として扱う（本キットの標準フロー）。レビュー判定が pass になった後に「マージしてよいですか？」とユーザーへ確認（AskUserQuestion 等）することは**しない** — マージ可否はテスト済みの決定的ゲート（/auto-merge の 8 条件）が決定済みであり、止めるべきものはゲートが機械的に止める（サイズ超過・判定 NG・`[manual-merge]` タグ等はスクリプトがハンドオフを指示する）。ユーザーが確認を望む場合は PR 本文に `[manual-merge]` を書く、という opt-out 側で表明する設計。

### 1. QA（要件確認）— 必要な場合のみ
- 指示が明確な場合は QA をスキップし、そのまま実行に進む
- QA が必要なのは以下のケースのみ:
  - 指示が曖昧で複数の解釈ができる
  - 技術的な選択肢が複数ありメンテナの意向を確認したい
- QA 時は AskUserQuestion（選択肢付き）で不明点を解消する

### 2. 方針提案（必要な場合のみ）
- 以下のケースでは方針を提案しメンテナの承認を待つ:
  - 複数アプリ/パッケージにまたがる変更
  - 新しいアーキテクチャ・技術スタックの導入
  - 外部サービス連携・課金・データ削除など不可逆操作
  - セキュリティ・プライバシーに関わる変更
- 上記に該当しない場合は、方針提案をスキップして自律実行に進む
- 自律実行時も、実行開始時に「〜を実装します」と一言報告する（承認は待たない）

### 3. 自律実行（承認後 or 自律判断で一気通貫）

メンテナの承認を得た場合、または自律実行条件を満たす場合、以下を自動で連続実行する:

#### 自律実行の条件（以下をすべて満たす場合、QA・方針提案をスキップ）
- 指示の意図と変更範囲が明確
- 既存パターンの踏襲（新規アーキテクチャ判断が不要）
- 影響範囲が限定的（1アプリ or 1パッケージ内）
- 外部サービス連携・課金・データ削除などの不可逆操作がない

#### チーム構成の判断
- タスクの規模・複雑さから「単独実装」か「Agent Teams で並行実装」かを自律判断
- Teams の場合はロール構成とタスク分担案を提示

1. **Issue 作成**: `gh issue create` で GitHub Issue を作成（外部 tracker を使う案件は `docs/optional-integrations.md` を参照）
2. **worktree 作成**: `git worktree add` で隔離環境を作成（ブランチ: `feat/{ISSUE-ID}-{scope}-{説明}`）
3. **実装**: 単独 or `/start-team` で Agent Teams を起動して実装
4. **進捗報告**: 区切りごとに Issue にコメント（`gh issue comment`）
5. **コミット・プッシュ**: `/commit-push` でコミット → リモートにプッシュ
6. **PR 作成**: `Closes #XX` 付きで PR を作成（マージ時に Issue が自動クローズ）
7. **UI 変更時のスクショ添付（必須）**: フロントエンド・スライド・公開ドキュメント等の **見た目に影響する変更** を含む PR は、ブラウザで撮影したスクショを `gh pr comment` で添付する。撮影・アップロードは各 project のブラウザ操作規約に従う。対象外: バックエンド・設定・テスト・スキル定義のみの変更
8. **一次レビュー**: PR 作成を hook が検知し `/review` を自動起動する。Claude 自身は **手動でレビューコメントを書かない**（二重投稿になるため）

### 4. メンテナマージ

メンテナが PR のレビューコメントを確認し、OK ならマージ。マージ時に Issue が自動 Close される。

## PR 作成前の lint チェック（必須）

PR を作成する前に、ローカルで lint チェックをすべて通すこと。CI に lint / type-check が無い場合、ローカルが最終ガード。これを怠るとマージ後にデプロイで初めてエラーが出る。

### 実行すべきチェック

プロジェクトのビルド / lint ツール（turbo / nx / pnpm-workspace 等、あれば）に合わせて実行:

```bash
npx turbo lint          # ESLint
npx turbo type-check    # TypeScript 型チェック
```

`/commit-push` がコミット前に `/review` を起動して上記を自動実行する仕組みなので、通常はそのフローに乗ること。手動実行は緊急時のみ。

### ワークフローファイルを変更した場合
```bash
# yamllint（120文字制限）
yamllint .github/workflows/ -d '{extends: default, rules: {line-length: {max: 120}}}'
# actionlint（shellcheck 含む）
actionlint
```

### よくある lint エラーと回避策

| エラー | 原因 | 回避策 |
|--------|------|--------|
| yamllint `line-length` | YAML 行が120文字超 | 長い grep コマンドは変数に分割、env で定義 |
| actionlint `shellcheck SC2086` | 変数未クォート | `"$VAR"` でクォートする |
| actionlint `shellcheck SC2129` | 個別リダイレクト `>> file` の連続 | `{ cmd1; cmd2; } > file` でグループ化 |
| actionlint `expression` | `github.head_ref` 等を直接使用 | `env:` で環境変数に渡してから参照 |
| actionlint `action` | `actions/setup-*@v4` が古い | `@v5` 以上に更新 |

### 既存 lint エラーの分離

機能 PR に既存ファイルの lint 修正が混入する場合は、先に `fix/infra-lint-*` ブランチで lint 修正 PR を出してマージし、機能 PR はクリーンな状態で作成する。

## PR 作成後の hook（`/review` + `/pr-context-summary` を順序付きで促す）

PR 作成（`gh pr create`）を PostToolUse hook が検知し、`/review` と `/pr-context-summary` を **順序付きリスト** で `additionalContext` に投入する。Claude は順序に従って `/review` を最優先で起動する。

### 動作概要
- フック: `scripts/claude-hooks/post-tool-use-pr-created.sh`（project 側で配置）
- 出力: 順序付きリマインド
  1. **最優先**: `/review <PR#>` を起動（一次レビュー）
  2. `/pr-context-summary --mode pre-merge --pr <PR#>` を実行（意思決定サマリを Issue にコメント）
- hook 自身は **/review を自動実行しない**。`additionalContext` で Claude にリマインドするのみで、Claude 側が順序通り呼ぶ責任を持つ
- Claude 自身は **手動でレビューコメントを書かない**（hook 経由の `/review` と二重投稿になる）

### 順序付き hook を採用する理由
2 hook が並列にリマインドを返していると、Claude が `/pr-context-summary` を先に解釈して `/review` を呼び忘れる事故が起きる。1 hook 統合 + 順序付きリスト + 「最優先」マーカーで構造的に再発防止する。

### レビュー観点
- `rules/code-review.md` のチェックリスト 6 カテゴリ
  - 型安全 / セキュリティ / テストカバレッジ / パフォーマンス / コード品質 / 依存・スコープ整合性

### Critical/Major 指摘時の対応
- `/review --fix` で自動修正を試みた上でメンテナに報告する
- 修正後は再度 `/review` を実行する
- 修正後 Critical/Major がゼロになれば `/auto-merge` を続けて実行する

### `/review` 完了後の `/auto-merge` 自動チェーン

**フック**: `scripts/claude-hooks/post-tool-use-auto-merge-after-review.sh`（`gh pr comment` を `if` マッチで検知、project 側で配置）

`/review` または `/review --fix` がレビュー結果を `gh pr comment` で投稿した直後、PostToolUse hook がコメント本文中の **Markdown 見出し**（`## レビュー結果` / `## レビュー指摘修正結果` / `## 一次レビュー` 等、絵文字付きも可）を検知し、Claude に `/auto-merge <PR#>` 起動を `additionalContext` で指示する。これにより Claude が呼び忘れる失敗を構造的に防ぐ。

**PR 番号の抽出**: 以下の入力形式に対応
- `gh pr comment 123 --body ...`（番号直指定）
- `gh pr comment https://github.com/owner/repo/pull/456 --body ...`（URL 形式）
- 番号が抽出できない場合は汎用リマインド（current branch 推論を促す）

**抑止条件**:
- PR description 本文（コメントではない、PR 本体の説明文）に `[manual-merge]` タグがある場合は hook が早期 return して `/auto-merge` を促さない
- レビュー結果以外の通常コメント（見出しなしの本文に「レビュー結果」が含まれる程度）は誤発火しないよう Markdown 見出しでのみ判定

## Codex 二次レビュー（opt-in）

Claude `/review` 完了後、特定条件を満たす PR で Codex (`gpt-5-codex`) による二次レビューを自動起動する。Claude が見落としやすい観点（外部 API 仕様・最小権限・Promise 未捕捉・リファクタ整合性）を構造的に補完する。

### 起動条件（OR）

1. PR diff に外部 API 連携キーワードを含むファイル変更: `discord` / `slack` / `notion` / `openai` / `anthropic` / `webhook` / `mcp`
2. PR 規模 ≥ 500 行 OR ≥ 10 ファイル
3. PR 本文に `[codex-review]` タグ（独立行で記載・明示 opt-in）

### Opt-out

- PR 本文に独立行で `[no-codex]` を記載 → 完全スキップ
- Codex CLI が未認証 / 未インストール → 静かに失敗

### 動作概要

- **フック**: `scripts/claude-hooks/post-tool-use-codex-secondary-review.sh`（`gh pr comment` の `## レビュー結果` 見出しを検知、project 側で配置）
- **判定ロジック**: `scripts/claude-hooks/lib/codex-trigger-criteria.sh`（純関数として分離・テスト推奨）
- **スキル**: `skills/codex-secondary-review/SKILL.md`
- **起動コマンド**: `/codex-secondary-review <PR#>`

### 運用ガード

- Codex 指摘は **`/auto-merge` の Critical/Major 集計に含めない**（Claude 一次レビューが authoritative）
- コメント先頭に `<!-- codex-secondary-review:PR#{n} -->` マーカー → 同 PR への二重投稿を抑止
- hook 自身の投稿（`codex-secondary-review:` マーカー検知）はスキップ → 無限ループ防止

### 比較データ（参考値）

大規模 PR で Claude が APPROVE した場面で Codex が Major 3 件を拾うケースが再現性高く観測されている（user activation 未捕捉、availability check 漏れ、`<all_urls>` 過剰権限 等）。

## PR コンテキストサマリ

PR 作成時とマージ後に、セッション中のメンテナとのやり取り・意思決定を要約して **GitHub Issue にコメント** として残す。後で振り返れる場所を確保し、後続タスクへの方針引き継ぎを可能にする。

### 動作概要

- **`pre-merge`**: PR 作成（`gh pr create`）を `post-tool-use-pr-created.sh` hook が検知し、`/review` と並び順 2 番目で `/pr-context-summary --mode pre-merge --pr <PR#>` を `additionalContext` で促す → そこまでの背景・選択肢・判断・没案・残課題を Issue にコメント
- **`post-merge`**: `/auto-merge` のマージ成功時 + ポーリングモードの MERGED 検知時から自動チェーン → レビュー指摘対応・PR 中のメンテナ追加判断・次アクションを同じ Issue に追記

### 仕組み

- スキル: `skills/pr-context-summary/SKILL.md`
- pre-merge hook: `scripts/claude-hooks/post-tool-use-pr-created.sh`（project 側で配置）
- Issue 番号は PR 本文の `Closes #XX` から自動抽出（フォールバックで PR 本体に投稿）
- 各コメント冒頭に `<!-- pr-context-summary:{mode}:PR#{n} -->` マーカーを置き、同モードの二重投稿を抑止

### 手動実行

```bash
/pr-context-summary --mode pre-merge --pr 226
/pr-context-summary --mode post-merge --pr 226
```

hook が起動しなかった場合や、再生成したい場合に手動で叩く。スキル側のマーカー判定で再投稿は抑止される。

## PR 自動マージ

`/review` 完了後、Claude は **必ず `/auto-merge <PR#>` を実行する**。

### 自動マージ条件（全 AND）

1. **実コード差分 ≤ 500 行**（ファイル数は除外せず総数で ≤ 10 ファイル）
   - **行数集計から除外**: パスに `__tests__/` を含む / `*.test.*` / `*.spec.*` / `*.md`（任意の場所）
   - 除外したテスト・ドキュメント行数は判定結果コメントに「テスト/.md XX 行を除外」と注釈表示
   - ファイル数の上限は **除外せずに全ファイル数** で 10 を判定（レビュー負荷の指標として総数を維持）
2. スコープが単一アプリ（または infra）に閉じる（複数 `apps/*` 横断・shared `packages/*` 変更は NG）。判定は `check_scope_from_files` にハードコード（`apps/` + `packages/` 構成前提）
3. 公開コンテンツに 1 行も触れない（`scripts/claude-hooks/data/public-content-paths.txt` に指定、`PUBLIC_CONTENT_PATHS_FILE` で上書き可）
4. `/review` の Critical / Major 指摘ゼロ
5. CI 全 check pass（10 分タイムアウト）
6. 危険操作なし（migration / 認証 / 課金 / データ削除キーワード / 外部 API キー追加）
7. PR 本文に `[manual-merge]` タグなし

### 動作

- 全条件満たす → Claude が squash merge を実行
- 1 つでも欠ける → 判定結果コメントを PR に投稿し、**ScheduleWakeup でマージ待ちポーリングを開始**
- 各ステップ（判定・CI・マージ）の結果は次の動作前に必ず PR コメントとして投稿される

### マージ待ちポーリング

`/auto-merge` の判定 NG / CI 失敗 / マージ失敗で「メンテナ手動マージ待ち」になった場合、Claude セッションは `ScheduleWakeup` で 10 分後に自分自身を起こす。

- 起床時に PR 状態を確認:
  - **MERGED**: `cleanup-merged-worktrees.sh` で worktree 削除 + main pull + 完了サマリー → セッションクローズ
  - **CLOSED**: worktree のみ削除して完了サマリー → セッションクローズ
  - **OPEN**: 次回 ScheduleWakeup を再スケジュール（最大 24 回 = 4 時間）
- 24 回経過 → ポーリング停止し PR コメントで通知。`/auto-merge <PR#>` で再開可能
- **冪等性**: MERGED / CLOSED 検知時の「マージ検知 / Close 検知」コメントは投稿前に既存チェックを行い、二重投稿を抑止する。Claude が手動操作で先にクリーンアップ済みのケースでも race condition で重複投稿しない

これによりメンテナが「merged!」と伝えなくても、Claude セッションがマージ完了を検知して自動でクローズフェーズに進む。

### opt-out

メンテナが手動マージしたい場合は、PR 本文に `[manual-merge]` を含める。判定で早期 return され、ScheduleWakeup も仕掛けられない。

**書き方ルール**:

- **独立行**に `[manual-merge]` を置く（前後は空白文字のみ）
  ```
  通常の PR 説明...

  [manual-merge]
  ```
- 説明文中・インラインコード・リスト項目内・装飾付き（`**[manual-merge]**`）は **検知されない**（仕様）
- タグの解説や言及をドキュメントとして書きたい場合は通常の段落内に書けば誤検知しない

判定ロジックは `scripts/claude-hooks/lib/auto-merge-criteria.sh` の `check_optout_from_body` 関数（project 側で配置）。

### 関連スクリプト

- `scripts/claude-hooks/cleanup-merged-worktrees.sh`: PR 番号 / `--branch` / `--all` でマージ済み worktree を削除する CLI（手動オペにも使える、project 側で配置）

## worktree 運用ルール

- 実装は必ず `git worktree add` で隔離環境を作成して行う
- 複数セッションが並行しても、ブランチ競合を防止できる
- メンテナは worktree の存在を意識する必要はない
- 作成パス: `.claude/worktrees/{ブランチ名}`
  ```bash
  git worktree add .claude/worktrees/feat/{ISSUE-ID}-web-bookmark -b feat/{ISSUE-ID}-web-bookmark
  ```
- クリーンアップ: PR マージ後に自動削除
  ```bash
  git worktree remove .claude/worktrees/{ブランチ名}
  git branch -d {ブランチ名}
  ```

## 命名規則（マルチアプリ対応）

### Issue タイトル
- 形式: `[app名] 説明` — アプリ固有の場合
- 形式: `[infra] 説明` — CI/CD・共有設定・リポジトリ全体の場合
- 形式: `[packages/pkg名] 説明` — 共有パッケージの場合
- 例: `[web] 検索バーの UI 改善`
- 例: `[api] レート制限を追加`
- 例: `[infra] Issue 駆動開発フローの確立`

### コミットメッセージ
- 形式: `type(scope): 説明`
- scope = アプリ名 or パッケージ名 or infra
- type: `feat` / `fix` / `docs` / `refactor` / `test` / `chore`
- 例: `feat(web): ズーム機能を追加`
- 例: `fix(api): レスポンスの文字化けを修正`
- 例: `chore(infra): Issue テンプレートを追加`
- 複数アプリにまたがる場合: `type(scope1,scope2): 説明` or `type(infra): 説明`

### ブランチ名
- feature: `feat/{ISSUE-ID}-{scope}-{簡潔な説明}`
- bugfix: `fix/{ISSUE-ID}-{scope}-{簡潔な説明}`
- ISSUE-ID は GitHub Issue 番号（例: `62`）または外部 tracker ID（例: `ABC-62`）
- 例: `feat/62-infra-issue-driven-workflow`
- 例: `fix/60-web-search-bar`
- GitHub Issue 番号は PR 本文の `Closes #XX` で紐づける

### PR タイトル
- コミットメッセージと同じ形式: `type(scope): 説明`
- 例: `feat(infra): Issue 駆動開発フローの確立`

## PR 本文の Closes 記法

GitHub の自動クローズには `Closes #<数字>` を使う（`#` + 数字のみ）。

| 用途 | 記法 | 例 |
|------|------|----|
| GitHub Issue クローズ | `Closes #<数字>` | `Closes #<num>` |
| 参照のみ（クローズしない） | `Refs #<数字>` / `Part of #<数字>` | `Refs #<num>` |

クローズ系キーワード: closes / fixes / resolves / completes / implements（各活用形も可）。

外部 tracker（Linear / Jira 等）を使う案件での記法は `docs/optional-integrations.md` を参照。

## main ブランチでの直接コミット・プッシュ

main への直接コミット・プッシュは **pre-tool-use hook で一律ブロック** される（project 側に hook を設置すること）。
typo 修正・設定微修正を含む **すべての変更** は worktree + PR 経由で行うこと。

- **緊急バグ修正**: Issue 作成と実装を同時並行で可（ただし worktree + PR は必須）
