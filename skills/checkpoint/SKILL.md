---
model: sonnet
name: checkpoint
description: 作業を中断（pause）して進捗を Issue に保存し、別セッションから復元（resume）するチェックポイント。Issue は GitHub 番号と Linear ID（{ISSUE-ID}）の両方で指定可
user-invocable: true
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash(gh:*, git:*, python3:*, bash:*)
---

# /checkpoint

作業の中断（pause）・再開（resume）を Issue ベースで管理するチェックポイント。記録先は GitHub Issue に集約し、Issue の指定は **GitHub 番号（`81`）と Linear ID（`{ISSUE-ID}`）の両方**を受け付ける。

## 使い方

```
/checkpoint pause                  # Issue 自動推論、進捗を Issue にコメント
/checkpoint pause --issue 81       # GitHub Issue 番号を明示指定
/checkpoint pause --issue {ISSUE-ID}  # Linear ID で指定（→ 対応する GitHub Issue に記録）
/checkpoint pause --create         # 新規 Issue を作成して記録
/checkpoint resume 81              # Issue #N の中断メモからコンテキスト復元
/checkpoint resume {ISSUE-ID}         # Linear ID から復元（→ 対応する GitHub Issue を参照）
```

---

## pause — 作業中断記録

作業中断時にセッション情報・git 状態・進捗を収集し、GitHub Issue にコメントとして記録する。

### 引数

| 引数 | 説明 | デフォルト |
|------|------|-----------|
| `--issue <ref>` | 記録先 Issue。GitHub 番号（`81`）または Linear ID（`{ISSUE-ID}`） | ブランチ名から自動推論 |
| `--create` | 新規 Issue を作成して記録 | false |

`--issue` と `--create` の同時指定はエラーとする。

### 手順（6 ステップ、ユーザー確認なし・即実行）

#### ステップ 1: 引数パース & 認証チェック

1. 引数をパース:
   - `--issue <ref>`: 記録先 Issue。GitHub 番号（`81`）または Linear ID（`{ISSUE-ID}`）。**生の文字列として保持し、GitHub Issue 番号への解決はステップ 4 の「Issue 参照の解決」で行う**
   - `--create`: 新規 Issue 作成フラグ
   - `--issue` と `--create` が同時指定された場合 → エラー: `--issue と --create は同時に指定できません`
   - 残りテキスト: 追加メモとして使用

2. `gh` 認証チェック:
   ```bash
   gh auth status 2>&1
   ```
   未認証の場合 → 最終的にマークダウン出力にフォールバックする旨を通知して続行

#### ステップ 2: セッション情報収集

1. プロジェクトキーを生成:
   ```bash
   pwd | sed 's|/|-|g'
   ```

2. セッション ID を取得:
   ```bash
   PROJECT_KEY=$(pwd | sed 's|/|-|g')
   SESSION_FILE="$HOME/.claude/projects/${PROJECT_KEY}/sessions-index.json"

   if [ -f "$SESSION_FILE" ]; then
     python3 -c "
   import json, sys
   with open(sys.argv[1]) as f:
       sessions = json.load(f)
   if sessions:
       latest = sorted(sessions, key=lambda s: s.get('modified',''), reverse=True)[0]
       print(latest['id'])
   else:
       print('NONE')
   " "$SESSION_FILE" 2>/dev/null || echo "NONE"
   else
     echo "NONE"
   fi
   ```

3. セッション ID が `NONE` の場合 → セッション情報セクションに「取得不可」と記載して続行
4. 再開コマンドを生成: `claude --resume {sessionId}`

#### ステップ 3: git 状態収集（並列実行）

以下を並列で実行:

```bash
git branch --show-current
git status --short
git log --oneline -5
git diff --stat
git worktree list
```

#### ステップ 4: Issue 参照の解決 & 存在確認

以下の優先順位で「Issue 参照」を決定する:

1. `--create` 指定 → Step 6 で新規 Issue を作成（解決スキップ）
2. `--issue <ref>` 指定 → その参照を使用
3. 未指定 → ブランチ名から推論（判別関数を使う。旧 `grep -oE '^(feat|fix)/([0-9]+)'` は `feat/{ISSUE-ID}-...` にマッチしないバグがあったため lib 関数に統一）:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT:-.claude}/skills/checkpoint/lib/resolve-issue-ref.sh"
   extract_issue_ref_from_branch "$(git branch --show-current)"
   # → "{ISSUE-ID}"（Linear）/ "120"（GitHub）/ 非ゼロ(抽出不可)
   ```
4. 推論不可 → Step 6 で新規 Issue を作成

得た参照を **「Issue 参照の解決（pause / resume 共通）」セクションに通して GitHub Issue 番号に変換**する。確定した番号で存在確認:
```bash
gh issue view {N} --json number,title,state -q '.number' 2>&1
```
存在しない場合 → エラー: `Issue #{N} が見つかりません。番号を確認するか --create で新規作成してください`

#### ステップ 5: コンテキスト要約（LLM）

会話コンテキスト・git 状態から以下を生成:

- **やったこと**: `[x]` チェックリスト形式で完了した作業を列挙
- **残タスク**: `[ ]` チェックリスト形式で未完了の作業を列挙
- **判断メモ**: メンテナ への伝達事項、意思決定の記録

- API Key パターン（`sk-...`, `Bearer ...`）→ `***` マスク
- `.env` の値 → `***` マスク
- パスワード・シークレット → `***` マスク
- 絶対パス（`/Users/...`）→ リポジトリ相対パスに変換

#### ステップ 6: Issue に記録

1. **一時ファイルに本文を書き出し**（`mktemp` で一意なパスを確保）:
   ```bash
   TMPFILE=$(mktemp /tmp/pause-memo-XXXXXX)
   cat <<'PAUSE_BODY_EOF' > "$TMPFILE"
   {出力テンプレートの内容}
   PAUSE_BODY_EOF
   ```

2. **既存 Issue にコメント**（Issue 番号がある場合）:
   ```bash
   gh issue comment {N} --body-file "$TMPFILE"
   ```

3. **新規 Issue を作成**（`--create` or Issue 推論不可の場合）:
   ```bash
   gh issue create --title "[{scope}] 作業中断メモ: {概要}" --body-file "$TMPFILE"
   ```

4. **フォールバック**（`gh` 未認証の場合）:
   - 出力テンプレートの内容をマークダウンとしてそのまま表示
   - 「GitHub Issue に手動でコピーしてください」と案内

5. **一時ファイルを削除**: `rm -f "$TMPFILE"`

6. **結果報告**: Issue URL + セッション ID + 再開コマンド

### 出力テンプレート

~~~markdown
## 作業中断メモ

### セッション情報
- **セッション ID**: `{sessionId}`
- **再開コマンド**: `claude --resume {sessionId}`
- **ブランチ**: `{branch}`
- **worktree**: `{worktree情報 or "なし"}`

### やったこと
- [x] {完了した作業1}
- [x] {完了した作業2}

### 残タスク
- [ ] {残っている作業1}
- [ ] {残っている作業2}

### 判断メモ
{意思決定やメンテナへの伝達事項}

### 現在の状態

    {git status --short の出力}

### 変更サマリー

    {git diff --stat の出力}

### 直近コミット

    {git log --oneline -5 の出力}
~~~

---

## resume — コンテキスト復元・再開

`pause` で記録した中断メモを GitHub Issue から読み込み、コンテキストを復元して作業を再開する。

### 引数

| 引数 | 説明 | デフォルト |
|------|------|-----------|
| (参照) | 再開する Issue。GitHub 番号（`81`）または Linear ID（`{ISSUE-ID}`） | ブランチ名から自動推論 |
| `--issue <ref>` | 同上（明示形式） | — |

### 手順（4 ステップ）

#### ステップ 1: 引数パース & 認証チェック

1. Issue 参照を取得:
   - 数字 / `{ISSUE-ID}` → そのまま参照として使用
   - `--issue <ref>` → その参照を使用
   - 引数なし → ブランチ名から自動推論（lib 関数。旧 `grep` 版は `feat/{ISSUE-ID}` 非対応バグあり）:
     ```bash
     source "${CLAUDE_PLUGIN_ROOT:-.claude}/skills/checkpoint/lib/resolve-issue-ref.sh"
     extract_issue_ref_from_branch "$(git branch --show-current)"
     # → "{ISSUE-ID}" / "120" / 非ゼロ(抽出不可)
     ```
   - 推論不可 → エラー: `Issue を指定してください（例: /checkpoint resume 81 または {ISSUE-ID}）`

   得た参照を **「Issue 参照の解決（pause / resume 共通）」セクションに通して GitHub Issue 番号に変換**してからステップ 2 へ進む。

2. `gh` 認証チェック — 未認証の場合はエラー

#### ステップ 2: Issue から中断メモを読み込み

1. Issue のデータを取得:
   ```bash
   gh issue view {N} --json body,comments,title,state
   ```

2. 最新の「作業中断メモ」セクションを探す:
   - コメントを逆順検索（最新コメントから）→ `## 作業中断メモ` ヘッダーを探す
   - コメントになければ Issue 本文を検索
   - 複数の中断メモがある場合は最新のものを使用

3. 中断メモから以下を正規表現で抽出:
   - **セッション ID**: `` `claude --resume (.+)` ``
   - **ブランチ名**: `\*\*ブランチ\*\*: \`(.+)\``
   - **worktree**: `\*\*worktree\*\*: \`(.+)\``
   - **やったこと**: `- \[x\] (.+)`
   - **残タスク**: `- \[ \] (.+)`
   - **判断メモ**: `### 判断メモ` セクション

4. 中断メモが見つからない場合 → Issue 本文から状況を読み取って再開

#### ステップ 3: 環境復元

1. ブランチ・worktree の存在確認
2. 状況に応じた対応:

| 状況 | 対応 |
|------|------|
| ブランチ & worktree が存在 | worktree パスを案内 |
| ブランチのみ存在 | worktree 作成を提案 |
| どちらも存在しない | ブランチ + worktree 作成を提案 |

3. Issue が Close 済みの場合 → 警告を出して続行（re-open はしない）

#### ステップ 4: コンテキスト提示 & 再開

~~~markdown
## Issue #{N} から再開

### 前回のセッション
- **セッション ID**: `{sessionId}`
- **同一セッションで再開**: `claude --resume {sessionId}`

### 前回のブランチ
- **ブランチ**: `{branch}`
- **worktree**: `{path or "なし"}`

### 前回の完了作業
- [x] {完了した作業1}

### 残タスク（前回の中断メモより）
- [ ] {残タスク1}

### 判断メモ
{前回の判断メモ}

---
上記コンテキストを踏まえて作業を再開します。
~~~

その後、残タスクの最初の項目から作業を開始する。

---

## Issue 参照の解決（pause / resume 共通）

`--issue <ref>` / 位置引数 / ブランチ推論で得た参照を GitHub Issue 番号に解決する共通手順。

### 1. 参照の分類

```bash
source "${CLAUDE_PLUGIN_ROOT:-.claude}/skills/checkpoint/lib/resolve-issue-ref.sh"
classify_issue_ref "$REF"   # → "github:81" / "linear:{ISSUE-ID}" / 非ゼロ(無効)
```

- `github:<N>` → `<N>` をそのまま GitHub Issue 番号として使用
- `linear:MAE-<N>` → 下記 2 で GitHub 番号に変換
- 非ゼロ（無効） → エラー: `無効な Issue 参照です（例: 81 または {ISSUE-ID}）`

ブランチ名からの自動推論も同じ lib 関数を使う:

```bash
extract_issue_ref_from_branch "$(git branch --show-current)"
# → "{ISSUE-ID}" / "120" / 非ゼロ(抽出不可)。得た値を classify_issue_ref に通す
```

### 2. {ISSUE-ID} → GitHub Issue 番号の解決

Linear ID は GitHub Issue タイトルに入らず `gh search` では特定できない（fuzzy ヒットで誤判定する）。**Linear MCP 経由で解決する**（重い読み取りのため subagent 隔離推奨・`subagent-isolation.md` 準拠）:

1. subagent（`model: haiku` または `sonnet`）に Linear MCP `get_issue("{ISSUE-ID}", includeRelations: true)` を実行させ、`attachments` / links から `github.com/<owner>/<repo>/issues/<N>` 形式の URL を探し、**GitHub Issue 番号 `<N>` だけを親に返させる**
2. 見つからない場合のフォールバック: Linear Issue の本文/説明内の GitHub Issue リンクを探す
3. それでも無ければエラー: `{ISSUE-ID} に対応する GitHub Issue が見つかりません`

> **実機検証**（{ISSUE-ID} / 2026-06-24）: `get_issue(id="{ISSUE-ID}", includeRelations=true)` のレスポンス `attachments[0].url` に `https://github.com/maee-co/core/issues/988` が格納され、正規表現で GitHub Issue 番号 `988` を抽出できることを確認済み（`attachments[].url` が主経路）。

> 記録先は常に GitHub Issue（メンテナ 確定方針）。Linear 番号は「入力キー」として受理し、メモ自体は解決後の GitHub Issue にコメントする。Linear からは GitHub↔Linear 同期リンクで辿れる。

## エッジケース対応

| ケース | 対応 |
|--------|------|
| `--issue` と `--create` 同時指定 | エラーメッセージを表示して終了 |
| `--issue` に無効な参照（`abc` / `#1` 等） | `classify_issue_ref` が非ゼロ → エラー: `無効な Issue 参照です（例: 81 または {ISSUE-ID}）` |
| `--issue {ISSUE-ID}` の GitHub Issue を解決できない | エラー: `{ISSUE-ID} に対応する GitHub Issue が見つかりません` |
| Linear MCP 未接続 / `get_issue` 失敗（{ISSUE-ID} 指定時） | エラーを表示し、GitHub 番号での再指定を案内 |
| Issue が存在しない | エラーメッセージを表示して終了 |
| セッション ID 取得不可 | 「取得不可」と記載して続行 |
| `gh` 未認証（pause） | マークダウン出力にフォールバック |
| `gh` 未認証（resume） | エラーメッセージを表示して終了 |
| main ブランチで `--issue` 未指定 | Issue 推論不可 → 新規 Issue 作成 |
| worktree 外で実行 | worktree 情報を「なし」と記載 |
| git 変更なし | 「変更なし」と記載して続行 |
| ブランチが削除済み（resume） | worktree 再作成を提案 |
| Issue が Close 済み（resume） | 警告を出して続行 |
| 複数の中断メモがある | 最新のコメントのものを使用 |

## 安全ルール

- Level 1（API Key・パスワード・個人識別情報）: Issue 本文に絶対に含めない
- `.env` ファイルの値や認証情報は `***` でマスク
- `git diff --stat` のみ使用（コード差分全体は出さない）
- 絶対パス（`/Users/...`）→ リポジトリ相対パスに変換
- 一時ファイルは `mktemp` で一意なパスを生成し、使用後に必ず削除
- `gh` コマンドのレート制限に注意し、必要最小限の API コールに留める
- Close 済み Issue の re-open は行わない（メンテナ 判断）