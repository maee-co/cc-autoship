#!/bin/bash
# /auto-merge スラッシュコマンドが利用する判定ロジック
#
# 純関数（check_*_from_data）と gh ラッパー（check_*）に分離している。
# テストは純関数に対して書く。

set -uo pipefail

# 二重 source ガード（source 済みなら再定義せず即 return。readonly 再定義エラーも回避・#1323）
if [ -n "${_AUTO_MERGE_CRITERIA_SH_LOADED:-}" ]; then
  # shellcheck disable=SC2317  # source でなく直接実行されたときのみ return が失敗し || true に到達する
  return 0 2>/dev/null || true
fi
_AUTO_MERGE_CRITERIA_SH_LOADED=1

# 上限定数
readonly AUTO_MERGE_MAX_LINES=500
readonly AUTO_MERGE_MAX_FILES=10

# 公開コンテンツのパスリスト（自動マージをブロックする公開アセット）。
# source 元 (bash: BASH_SOURCE / zsh: $0) 相対で data/ を解決するため、配布時の
# ${CLAUDE_PLUGIN_ROOT} 配置でも正しく効く。環境変数 PUBLIC_CONTENT_PATHS_FILE で上書き可能。
# 注: bash の hook 実行と zsh での source（/auto-merge スキル）双方で動くよう、
# ${BASH_SOURCE[0]:-$0} で set -u 下の unbound を回避する（zsh は BASH_SOURCE 未定義）。
_AMC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
PUBLIC_CONTENT_PATHS_FILE="${PUBLIC_CONTENT_PATHS_FILE:-${_AMC_LIB_DIR:-.}/../data/public-content-paths.txt}"

# self-modification guard（{ISSUE-ID} 自己改善ループ Phase 2a・条件 9）。
# 既に読み込み済みなら再 source しない（readonly 再定義エラーの回避・pr-class.sh と同じ方式）。
declare -f check_self_improve_protected_paths_from_data >/dev/null 2>&1 \
  || source "${_AMC_LIB_DIR:-.}/protected-paths.sh"

# Pure: 差分行数とファイル数から判定
# Args: additions deletions file_count
# Returns: 0=OK, 1=NG（理由を stderr に出す）
#
# 注: ここに渡す additions / deletions は **実コード行数**（テスト・ドキュメント除外後）が想定。
# 除外ロジックは categorize_diff_lines_from_files で行い、auto_merge_evaluate 経路から呼び出す。
# 直接 check_size_from_data を呼ぶ既存テストは raw 値（カテゴリ分けなし）を渡しても動作する。
check_size_from_data() {
  local additions="$1" deletions="$2" file_count="$3"
  local total=$((additions + deletions))
  if [ "$total" -gt "$AUTO_MERGE_MAX_LINES" ]; then
    echo "差分サイズ超過: ${total} 行（上限 ${AUTO_MERGE_MAX_LINES}）" >&2
    return 1
  fi
  if [ "$file_count" -gt "$AUTO_MERGE_MAX_FILES" ]; then
    echo "ファイル数超過: ${file_count}（上限 ${AUTO_MERGE_MAX_FILES}）" >&2
    return 1
  fi
  return 0
}

# Pure: ファイル別差分一覧から「実コード行数」と「テスト/.md 行数」を分けて集計
# Args: file_diff_list (改行区切り、各行は "path\tadditions\tdeletions")
# Stdout: "prod_add prod_del td_add td_del"（スペース区切り 4 整数）
#
# 除外対象（テスト・ドキュメント）として「テスト/.md 側」に振り分けるパターン:
#   - パスに /__tests__/ を含む（一般的な慣習）
#   - *.test.* / *.spec.* で終わる（Jest / Vitest 慣習）
#   - 拡張子 .md（任意の場所、スキル参照ドキュメントも含む）
#
# 上記以外（TS/JS/Python/sh/json/yml 等の実コード）を「実コード側」に集計する。
# auto-merge のサイズ判定は実コード側のみを 500 行閾値で判定するため、
# テスト・ドキュメントを厚く書く infra PR が手動マージ待ちになる構造的衝突を回避できる（{ISSUE-ID}）。
#
# 注: `*/references/*` パターンは {ISSUE-ID} レビューで over-inclusive と判定されたため不採用。
# スキル references/ 配下は実質 .md のみで *.md パターンが既にカバーする一方、
# 将来 production code が references/ 配下に置かれた場合に silent fail するリスクがあるため。
categorize_diff_lines_from_files() {
  local file_diff_list="$1"
  local prod_add=0 prod_del=0 td_add=0 td_del=0
  while IFS=$'\t' read -r path adds dels; do
    [ -z "$path" ] && continue
    # 数値以外（空文字・null）を 0 に正規化
    [[ "$adds" =~ ^[0-9]+$ ]] || adds=0
    [[ "$dels" =~ ^[0-9]+$ ]] || dels=0
    case "$path" in
      */__tests__/*|*.test.*|*.spec.*|*.md)
        td_add=$((td_add + adds))
        td_del=$((td_del + dels))
        ;;
      *)
        prod_add=$((prod_add + adds))
        prod_del=$((prod_del + dels))
        ;;
    esac
  done <<< "$file_diff_list"
  echo "$prod_add $prod_del $td_add $td_del"
}

# Pure: PR のファイル + ステータス一覧から「新規アプリ初期 PR」候補を判定（{ISSUE-ID}）
# Args: file_status_list (改行区切り、各行 "path\tstatus"。status は GitHub API の added/modified/removed/renamed 等)
# Stdout: 候補アプリパス（例 "apps/aqua-trip"）
# Returns: 0=候補あり, 1=候補なし
#
# 候補条件（すべて AND・fail-closed）:
#   - 1 行以上ある
#   - 全行が status=added（既存ファイルへの変更が 1 つでもあれば候補外）
#   - 全 path が同一の apps/<app>/ 配下（turbo.json / workflows 等 apps/ 外に触れたら候補外）
#
# 「main に当該アプリが存在しないこと」の確認は wrapper（auto_merge_new_app_exempt）の責務。
# 用途: 世に出ていない新規アプリの初期 PR はサイズ上限（500 行 / 10 ファイル）を免除する
# （既存コードへの影響がゼロのため。公開コンテンツ・危険操作・レビュー等の他条件は免除しない）。
new_app_candidate_from_files() {
  local file_status_list="$1"
  local app="" path fstatus
  [ -z "$file_status_list" ] && return 1
  while IFS=$'\t' read -r path fstatus; do
    [ -z "$path" ] && continue
    [ "$fstatus" = "added" ] || return 1
    case "$path" in
      apps/*/*) ;;
      *) return 1 ;;
    esac
    local this="${path#apps/}"
    this="apps/${this%%/*}"
    if [ -z "$app" ]; then
      app="$this"
    elif [ "$app" != "$this" ]; then
      return 1
    fi
  done <<< "$file_status_list"
  [ -z "$app" ] && return 1
  printf '%s\n' "$app"
  return 0
}

# Pure: CI 失敗時に「ローカル検証フォールバック」が許されるかを判定（{ISSUE-ID}）
# Args: failing_jobs (改行区切り、各行 "check_name\texecuted_steps") file_list (改行区切り)
# Returns: 0=フォールバック可, 1=不可（理由を stderr）
#
# フォールバック可 = 全 failing check が 1 ステップも実行されていない（= GitHub Actions
# 課金枯渇等でジョブが起動しなかった「CI 不発」）。この場合のみ、実 CI の代わりに
# ローカル検証（lint / type-check / unit test / 必要なら L1 e2e）で品質を担保してマージできる。
#
# fail-closed 側に倒すケース:
#   - failing check の情報が空（判定材料なし）
#   - executed_steps が非数値・-1（取得不能）
#   - 1 つでもステップが実行されて失敗した check がある（真の CI 失敗）
#   - PR が .github/workflows/ を変更している（CI 定義の変更は実 CI でしか検証できない）
check_ci_fallback_from_data() {
  local failing_jobs="$1" file_list="$2"
  local name steps file

  if [ -z "$failing_jobs" ]; then
    echo "failing check の情報が取得できないため CI 不発フォールバック不可（fail-closed）" >&2
    return 1
  fi

  while IFS= read -r file; do
    [ -z "$file" ] && continue
    case "$file" in
      .github/workflows/*)
        echo "PR が .github/workflows/ を変更しているため CI 不発フォールバック不可（CI 定義は実 CI で検証必須）: $file" >&2
        return 1
        ;;
    esac
  done <<< "$file_list"

  while IFS=$'\t' read -r name steps; do
    [ -z "$name" ] && continue
    if ! [[ "$steps" =~ ^[0-9]+$ ]]; then
      echo "check '$name' の実行ステップ数が取得できないためフォールバック不可（fail-closed）" >&2
      return 1
    fi
    if [ "$steps" -gt 0 ]; then
      echo "check '$name' は実行されて失敗しています（真の CI 失敗のためフォールバック不可）" >&2
      return 1
    fi
  done <<< "$failing_jobs"

  return 0
}

# Pure: 変更ファイル一覧（改行区切り）からスコープを判定
# Args: file_list (改行区切り)
# Returns: 0=OK, 1=NG（複数アプリ横断 / packages 変更時）
# 注: <public-app> など公開アプリも scope check は通過する（公開判定は check_public_content_from_files の責務）
# 注: packages/** は複数アプリ横断の影響があるため scope check で NG とする
check_scope_from_files() {
  local file_list="$1"
  local apps_touched=()
  local packages_touched=()

  while IFS= read -r file; do
    [ -z "$file" ] && continue
    case "$file" in
      apps/*)
        local app_name="${file#apps/}"
        app_name="${app_name%%/*}"
        local found=0
        for a in "${apps_touched[@]:-}"; do
          [ "$a" = "$app_name" ] && found=1 && break
        done
        [ "$found" -eq 0 ] && apps_touched+=("$app_name")
        ;;
      packages/*)
        local pkg_name="${file#packages/}"
        pkg_name="${pkg_name%%/*}"
        local found=0
        for p in "${packages_touched[@]:-}"; do
          [ "$p" = "$pkg_name" ] && found=1 && break
        done
        [ "$found" -eq 0 ] && packages_touched+=("$pkg_name")
        ;;
    esac
  done <<< "$file_list"

  if [ "${#apps_touched[@]}" -gt 1 ]; then
    echo "複数アプリ横断: ${apps_touched[*]}" >&2
    return 1
  fi
  if [ "${#packages_touched[@]}" -gt 0 ]; then
    echo "shared package 変更（複数アプリへの影響範囲）: packages/${packages_touched[*]}" >&2
    return 1
  fi
  return 0
}

# Pure: 公開コンテンツのパスリストを読み込む（コメント・空行除外）
# Args: paths_file（省略時 $PUBLIC_CONTENT_PATHS_FILE）
# Output: パス（改行区切り）。ファイルが無ければ空出力
_load_public_content_paths() {
  local file="${1:-$PUBLIC_CONTENT_PATHS_FILE}"
  if [ ! -f "$file" ]; then
    # 設定欠損時は fail-open（公開判定スキップ）。silent にせず警告を出す
    # （ui-change-detect.sh の frontend-apps 欠損時挙動と整合）。
    echo "[auto-merge] public-content-paths が見つかりません: ${file}（公開コンテンツ判定をスキップします）" >&2
    return 0
  fi
  grep -vE '^[[:space:]]*(#|$)' "$file" 2>/dev/null
}

# Pure: 変更ファイル一覧から公開コンテンツへの変更があるかを判定
# Args: file_list (改行区切り), paths_file（省略時 $PUBLIC_CONTENT_PATHS_FILE）
# Returns: 0=OK（公開コンテンツに触れていない）, 1=NG
#
# 公開判定パスは data/public-content-paths.txt で外部化（{ISSUE-ID}）。
# 各パスに対し「完全一致（README.md 等）」または「<path>/ 配下（<path>/* 等）」でマッチ。
# trailing slash 付き前方一致で <path>-clone のような誤検知を防ぐ。
check_public_content_from_files() {
  local file_list="$1"
  local paths_file="${2:-$PUBLIC_CONTENT_PATHS_FILE}"
  local public_files=()
  local patterns=()

  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    patterns+=("$pat")
  done < <(_load_public_content_paths "$paths_file")

  while IFS= read -r file; do
    [ -z "$file" ] && continue
    local pat
    for pat in "${patterns[@]:-}"; do
      [ -z "$pat" ] && continue
      if [ "$file" = "$pat" ] || [[ "$file" == "$pat"/* ]]; then
        public_files+=("$file")
        break
      fi
    done
  done <<< "$file_list"

  if [ "${#public_files[@]}" -gt 0 ]; then
    echo "公開コンテンツへの変更を検出: ${public_files[*]}" >&2
    return 1
  fi
  return 0
}

# Pure: レビューコメントテキストから Critical/Major を検出（A-2 / {ISSUE-ID}）
# Args: review_text
# Returns: 0=OK（未解決の指摘ゼロ）, 1=NG
#
# 検出対象の形式:
#   - [Critical] / [Major]（旧ラベル形式）
#   - ### Critical / ## Major（旧マークダウン見出し形式）
#   - 現行 4 軸表（| Critical | 95 | ... | 対応 |）の **未解決行**（_has_unresolved_critical_major_row）
# 旧ゲートは 4 軸表形式にマッチせず「Critical/Major ゼロ」条件が実質無効だった（{ISSUE-ID} A-2）。
# 解決済み（✅）/ 除外（⏭️ 除外（80未満））/ 別 Issue（📌）の Critical/Major 行はブロックしない
# （auto-merge を無効化しない）。`⏭️ スキップ` はブロックする（#1198 判断 2・詳細は
# _has_unresolved_critical_major_row のコメント）。
check_review_from_text() {
  local review_text="$1"
  if [ -z "$review_text" ]; then
    echo "レビューコメントが PR に投稿されていません（/review 未実行）" >&2
    return 1
  fi
  # 旧形式（[Critical] ラベル / ### Critical 見出し）
  if printf '%s' "$review_text" | grep -qiE '(\[(Critical|Major)\]|###?[[:space:]]+(Critical|Major)\b)'; then
    echo "/review に Critical / Major 指摘があります" >&2
    return 1
  fi
  # 現行 4 軸表形式（| Critical | 95 | ... | 対応 |）の未解決行
  if _has_unresolved_critical_major_row "$review_text"; then
    echo "/review の 4 軸表に未解決の Critical / Major 指摘があります" >&2
    return 1
  fi
  return 0
}

# Pure: /review 4 軸表（重要度 × 信頼度 × スコープ × 指摘 × 対応）から
# 「未解決の Critical / Major 行」を検出する（A-2 / {ISSUE-ID}、#1198 Phase 2 判断 2・3）
# Args: review_text
# Returns: 0=未解決の Critical/Major 行あり, 1=なし
#
# 判定:
#   - 重要度セル `| Critical |` / `| Major |`（前後空白許容・大小文字無視）を持つ表行が対象。
#     ヘッダ（| 重要度 |）・区切り（|---|）は Critical/Major セルを持たないため自然に除外される。
#     この重要度セル正規表現は maintenance-quality.sh の quality_count_findings_in_comment と同一
#     （4 軸表の重要度セル検知の共通イディオム）。
#   - 判定対象は **対応列（最終セル）のみ**（#1198 判断 3）。行全体マッチだと指摘本文中の
#     ✅ / 📌 に釣られて誤通過するため、末尾の非空セルだけを見る。
#   - 非ブロック（解決/除外/別 Issue 済み）は 3 パターンに限定:
#     ✅（完了/修正済み）・⏭️ 除外（80未満 = 誤検知フィルタ済み）・📌（別 Issue）。
#   - `⏭️ スキップ（理由）` は **未解決として block**（#1198 判断 2。review.md の定義上
#     スキップ = 信頼度 80 以上の実在指摘を見送った状態であり、自動マージは 4 軸表の意味論に
#     反する。正当なスキップは [manual-merge] で メンテナ マージに回すのが正道 = gate は緩和しない）。
#     対応列が ⏭️ のみで除外/スキップを判別できない場合もフェイルセーフで block（不明→block）。
#   - 判定ステータス（A-1・check_review_status_from_text）を主ゲートとした二重化（defense in depth）。
#     解決済み Critical をブロックせず auto-merge を無効化しないため、対応列を見る。
_has_unresolved_critical_major_row() {
  local text="$1" line cell
  while IFS= read -r line; do
    printf '%s' "$line" | grep -qiE '\|[[:space:]]*(Critical|Major)[[:space:]]*\|' || continue
    # 対応列 = 行末尾の非空セル（trailing `|` の有無に依存しない）
    cell=$(printf '%s' "$line" | awk -F'|' '{
      for (i = NF; i >= 1; i--) {
        gsub(/^[ \t]+|[ \t]+$/, "", $i)
        if ($i != "") { print $i; exit }
      }
    }')
    case "$cell" in
      *✅*) continue ;;      # 完了 / 修正済み
      *除外*) continue ;;    # ⏭️ 除外（80未満）= 誤検知フィルタ済み
      *📌*) continue ;;      # 別 Issue（既存問題として切り出し済み）
    esac
    # ⏭️ スキップ / ⚠️ 一部対応 / 未対応 / 不明マーカーはすべて未解決 → block
    return 0
  done <<< "$text"
  return 1
}

# Pure: /review コメント本文から 判定 セクション（### 判定 見出し以降）を切り出す（A-1 補助）
# Args: review_text
# Stdout: 判定セクション本文（見出し行を除く。次の ## 以上の見出し or EOF まで）
#
# 判定見出しはインデント / 引用（>）/ 絵文字付き（### ✅ 判定）を許容し、末尾が 判定 の見出しに
# 限定する（### 判定基準 のような別セクションを誤検知しないため）。サマリ等の外部言及に verdict
# 抽出が釣られるのを防ぐため、判定セクションだけを対象にする。
_extract_judgment_section() {
  local text="$1" line in_sec=0 out=""
  while IFS= read -r line; do
    if [ "$in_sec" -eq 0 ]; then
      if printf '%s' "$line" | grep -qE '^[[:space:]>]*#{2,6}[[:space:]]+.*判定[[:space:]]*$'; then
        in_sec=1
      fi
      continue
    fi
    # セクション中に次の見出し（## 以上）が来たら終了
    if printf '%s' "$line" | grep -qE '^[[:space:]>]*#{2,6}[[:space:]]'; then
      break
    fi
    out+="$line"$'\n'
  done <<< "$text"
  printf '%s' "$out"
}

# Pure: /review 判定ステータス（pass / 要確認 / fail）を抽出する（A-1 / {ISSUE-ID}）
# Args: review_text
# Stdout: pass | 要確認 | fail | unknown
#
# 設計:
#   - 判定セクション（### 判定 以降）だけを対象にする（サマリ等の 要確認 言及に釣られない）。
#   - full テンプレは判定ステータス定義 bullet（- **`pass`**: ...）を含むため、それを除外してから
#     verdict を探す（3 status 名を列挙する定義文に誤反応しない）。
#   - verdict token は行頭（任意の `判定:` ラベル・太字・バッククォート後）に現れるものに限定して
#     アンカーする（`pass（要確認事項なし）` を 要確認 と誤判定しない）。
#   - 悪い方から優先（fail > 要確認 > pass）。どれも検出できなければ unknown（フェイルセーフで block 側）。
extract_review_verdict_from_text() {
  local review_text="$1"
  [ -z "$review_text" ] && { echo "unknown"; return 0; }

  local section
  section=$(_extract_judgment_section "$review_text")
  [ -z "$section" ] && { echo "unknown"; return 0; }

  # 判定ステータス定義 bullet（- **`pass`**: ...）を除外
  local lines
  # backtick は grep 正規表現内のリテラル（コマンド置換ではない）ため単一引用符のまま
  # shellcheck disable=SC2016
  lines=$(printf '%s' "$section" | grep -vE '^[[:space:]>]*[*-][[:space:]].*\*\*`?(pass|要確認|fail)`?\*\*')

  # verdict 行アンカー: 行頭 → 任意の `判定[:：]` ラベル（太字可）→ 任意の太字/バッククォート → status token
  local anchor='^[[:space:]>]*((\*\*)?判定(ステータス)?(\*\*)?[[:space:]]*(:|：)[[:space:]]*)?(\*\*)?`?'
  if printf '%s' "$lines" | grep -qE "${anchor}fail([^a-zA-Z]|$)"; then echo "fail"; return 0; fi
  if printf '%s' "$lines" | grep -qE "${anchor}要確認"; then echo "要確認"; return 0; fi
  if printf '%s' "$lines" | grep -qE "${anchor}pass([^a-zA-Z]|$)"; then echo "pass"; return 0; fi
  echo "unknown"
}

# Pure: /review 判定ステータスが pass かを判定する（A-1 / {ISSUE-ID}）
# Args: review_text
# Returns: 0=pass（OK）, 1=pass 以外（要確認 / fail / 不明 → block）
#
# フェイルセーフ: 不明（判定セクション無し・verdict 抽出不可・未投稿）は必ず block に倒す
# （旧ゲートは判定ステータスを一切パースせず 要確認 / fail でも素通ししていた・{ISSUE-ID} A-1）。
check_review_status_from_text() {
  local review_text="$1"
  local verdict
  verdict=$(extract_review_verdict_from_text "$review_text")
  case "$verdict" in
    pass) return 0 ;;
    要確認)
      echo "/review の判定ステータスが『要確認』です（auto-merge ブロック）" >&2
      return 1 ;;
    fail)
      echo "/review の判定ステータスが『fail』です（auto-merge ブロック）" >&2
      return 1 ;;
    *)
      echo "/review の判定ステータスを検出できません（不明のため auto-merge ブロック）" >&2
      return 1 ;;
  esac
}

# Pure: 条件 4 のレビュー gate 統合判定（A-1 判定ステータス + A-2 Critical/Major）
# Args: review_text
# Returns: 0=OK（pass かつ 未解決の Critical/Major なし）, 1=block（理由を stderr）
#
# check_review_from_text（A-2 + 未投稿）と check_review_status_from_text（A-1 判定ステータス）の
# いずれかが block を返せば block。不明時は必ず block（フェイルセーフ）。
check_review_gate_from_text() {
  local review_text="$1"
  check_review_from_text "$review_text" || return 1
  check_review_status_from_text "$review_text" || return 1
  return 0
}

# Pure: 変更ファイルと PR 本文から危険操作を検出
# Args: file_list pr_body
# Returns: 0=OK, 1=NG
check_dangerous_from_data() {
  local file_list="$1" pr_body="$2"

  # ファイルパスベース
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    case "$file" in
      migrations/*|*/migrations/*)
        echo "migration ファイル変更: $file" >&2
        return 1
        ;;
      *.sql)
        echo "SQL ファイル変更: $file" >&2
        return 1
        ;;
      */auth/*|*/auth.ts|*/middleware.ts)
        echo "認証関連ファイル変更: $file" >&2
        return 1
        ;;
      */stripe/*|*/payment/*|*/billing/*)
        echo "課金関連ファイル変更: $file" >&2
        return 1
        ;;
    esac
  done <<< "$file_list"

  # PR 本文キーワード
  if [ -n "$pr_body" ]; then
    if printf '%s' "$pr_body" | grep -qiE '(DROP TABLE|DELETE FROM|TRUNCATE|rm -rf|force-delete)'; then
      echo "PR 本文に危険操作キーワードを検出" >&2
      return 1
    fi
  fi

  return 0
}

# Pure: PR 本文から opt-out タグを検出
# Args: pr_body
# Returns: 0=OK, 1=NG（[manual-merge] タグあり）
#
# タグ判定ルール（{ISSUE-ID} で誤検知対応）:
#   - PR 本文の独立行（前後が空白文字のみ）に [manual-merge] がある場合のみ NG
#   - 説明文中・インラインコード（`[manual-merge]`）・行頭末に他文字がある場合は無視
#   - 例: "[manual-merge] タグがあれば抑止" のような解説文は誤検知しない
check_optout_from_body() {
  local pr_body="$1"
  if printf '%s' "$pr_body" | grep -qE '^[[:space:]]*\[manual-merge\][[:space:]]*$'; then
    echo "[manual-merge] タグが PR 本文にあるため メンテナ 手動マージ待ち" >&2
    return 1
  fi
  return 0
}

# Pure: draft フラグを判定
# Args: is_draft (true|false)
# Returns: 0=OK, 1=NG
check_draft_from_flag() {
  local is_draft="$1"
  if [ "$is_draft" = "true" ]; then
    echo "PR が draft 状態のためマージ不可" >&2
    return 1
  fi
  return 0
}

# ============================================================
# {ISSUE-ID} Phase 2: UI 変更 PR の e2e enforcement
# ============================================================

# Pure: 変更ファイル一覧から「UI 変更を含むフロントアプリ」を列挙
# Args: file_list (改行区切り) frontend_apps (改行区切り)
# Stdout: UI 変更ありのフロントアプリ（frontend_apps の並び順・重複排除）
# Returns: 常に 0（該当なしは空出力）
#
# UI 拡張子・除外パスの判定は ui-change-detect.sh（SSoT）と同じルールを **意図的に複製** する。
# auto-merge.md は本 lib を zsh（Claude Code の Bash ツール）から source するため、
# BASH_SOURCE 依存の sibling source（bash/zsh 差異 + set -u で破綻）を避け自己完結させる。
# ルール変更時は ui-change-detect.sh と本関数を両方更新すること。
#   - UI 拡張子: tsx/ts/jsx/js/css/scss/html/svg（小文字限定）
#   - 除外: messages/*.json（i18n）, public 配下の画像（png/jpg/jpeg/webp/gif）
# 前方一致誤検知（apps/<public-app>-clone vs apps/<public-app>）は "${app}/" の trailing slash で防ぐ。
ui_changed_apps_from_files() {
  local file_list="$1" frontend_apps="$2"
  local app file
  [ -z "$file_list" ] && return 0
  [ -z "$frontend_apps" ] && return 0

  # frontend_apps の順で「そのアプリに UI 変更があるか」を判定して列挙（順序維持＋重複排除）
  while IFS= read -r app; do
    [ -z "$app" ] && continue
    while IFS= read -r file; do
      [ -z "$file" ] && continue
      # UI 拡張子か（小文字限定）
      case "$file" in
        *.tsx|*.ts|*.jsx|*.js|*.css|*.scss|*.html|*.svg) ;;
        *) continue ;;
      esac
      # 除外パス（i18n / 画像差し替え）はスキップ
      case "$file" in
        */messages/*.json|*/public/*.png|*/public/*.jpg|*/public/*.jpeg|*/public/*.webp|*/public/*.gif) continue ;;
      esac
      # frontend-apps 配下か（trailing slash で前方一致誤検知防止）
      case "$file" in
        "${app}/"*)
          printf '%s\n' "$app"
          break
          ;;
      esac
    done <<<"$file_list"
  done <<<"$frontend_apps"
}

# Pure: gh pr checks の bucket 値を e2e status enum に正規化
# Args: bucket（gh の bucket 値: pass|fail|pending|skipping|cancel。空文字 = 不明）
# Stdout: pass | fail | pending | skipped | cancelled | none
# Note: `state` ではなく `bucket` を使う理由（Codex 指摘）— gh の bucket は
#   ERROR / timed_out / action_required 等もすべて fail に分類済みのため、
#   map 側の default→none で「失敗を none にマスキングする」事故が起きない。
map_e2e_bucket() {
  case "$1" in
    pass) echo "pass" ;;
    fail) echo "fail" ;;
    pending) echo "pending" ;;
    skipping) echo "skipped" ;;
    cancel) echo "cancelled" ;;
    *) echo "none" ;;
  esac
}

# Pure: 複数 e2e check（matrix）の status を 1 つに集約
# Args: statuses（改行区切り、各行は map_e2e_bucket の出力）
# Stdout: pass|fail|pending|skipped|cancelled|neutral|none
# 優先順位: fail > cancelled > pending > pass > skipped > neutral > none
#   - fail / cancelled は 1 つでもあれば最優先（マージ阻止 / 待機）
#   - pending は「matrix の一部が未完了」を pass より優先（早すぎる pass 判定を防ぐ）
#   - pass は完了済みの中では skipped より優先
reduce_e2e_statuses() {
  local statuses="$1" s
  local seen_fail=0 seen_cancelled=0 seen_pending=0 seen_pass=0 seen_skipped=0 seen_neutral=0
  [ -z "$statuses" ] && { echo "none"; return 0; }
  while IFS= read -r s; do
    case "$s" in
      fail) seen_fail=1 ;;
      cancelled) seen_cancelled=1 ;;
      pending) seen_pending=1 ;;
      pass) seen_pass=1 ;;
      skipped) seen_skipped=1 ;;
      neutral) seen_neutral=1 ;;
    esac
  done <<<"$statuses"
  if [ "$seen_fail" -eq 1 ]; then echo "fail"
  elif [ "$seen_cancelled" -eq 1 ]; then echo "cancelled"
  elif [ "$seen_pending" -eq 1 ]; then echo "pending"
  elif [ "$seen_pass" -eq 1 ]; then echo "pass"
  elif [ "$seen_skipped" -eq 1 ]; then echo "skipped"
  elif [ "$seen_neutral" -eq 1 ]; then echo "neutral"
  else echo "none"
  fi
}

# Pure: UI 変更 PR の e2e enforcement 判定（graceful per-app rollout）
# Args: ui_changed_apps (改行区切り) l1_spec_apps (改行区切り) ci_status actions_usage_pct
#   ui_changed_apps: UI 変更を含むフロントアプリ（空 = UI 変更なし）
#   l1_spec_apps: L1 golden-path spec を持つアプリ（リポジトリ HEAD 時点）
#   ci_status: pass|fail|pending|skipped|cancelled|neutral|none|error（e2e_ci_status の出力）
#   actions_usage_pct: GitHub Actions 月次利用率（整数文字列、未取得は空）
# Returns: 0=OK（マージ可）, 1=block（理由を stderr）
#
# graceful rollout（{ISSUE-ID} Phase 1 コメント / メンテナ 承認）:
#   L1 spec を持つアプリ（= enforced）にのみ e2e CI 結果を要求する。
#   spec 未整備アプリの UI 変更は block しない（他セッションの作業を巻き込まないため）。
#   全フロントアプリの L1 spec が揃えば自然に全 PR が enforced になる。
check_e2e_from_data() {
  local ui_apps="$1" spec_apps="$2" ci_status="$3" usage="${4:-}"

  # UI 変更なし → N/A、常に OK
  [ -z "$ui_apps" ] && return 0

  # UI 変更ありアプリのうち L1 spec を持つもの（enforced）が 1 つでもあるか
  local enforced=0 app
  while IFS= read -r app; do
    [ -z "$app" ] && continue
    if printf '%s\n' "$spec_apps" | grep -qxF "$app"; then
      enforced=1
      break
    fi
  done <<<"$ui_apps"

  # enforced アプリなし → graceful skip（block しない。error でも巻き込まない）
  if [ "$enforced" -eq 0 ]; then
    echo "[e2e] UI 変更ありだが L1 spec 未整備アプリのため enforcement skip（graceful rollout）" >&2
    return 0
  fi

  case "$ci_status" in
    pass|neutral)
      return 0
      ;;
    pending)
      # e2e がまだ完了していない → OK 扱い。/auto-merge ステップ 2 の
      # `gh pr checks --watch --fail-fast` が完了を待ち失敗を捕捉するため、ここでは block しない。
      return 0
      ;;
    skipped)
      # 利用量 90% 超による自動 skip かつ UI 変更あり → メンテナ 手動マージ待ち
      if [ -n "$usage" ] && [[ "$usage" =~ ^[0-9]+$ ]] && [ "$usage" -ge 90 ]; then
        echo "e2e CI が GitHub Actions 利用量 ${usage}% 超で自動 skip。UI 変更を含むため メンテナ 手動マージ待ち" >&2
        return 1
      fi
      # path filter skip 等の通常 skip → OK（fail-safe = OK）
      return 0
      ;;
    none)
      # PR に e2e check が存在しない（対象アプリが e2e.yml CI matrix 未配線）→ graceful OK
      return 0
      ;;
    error)
      # e2e CI status を確認できない（gh 取得失敗等）。enforced アプリでは
      # fail-open を避けて block する（Codex 指摘）。確認不能を黙って通さない。
      echo "e2e CI 状態を確認できません（gh 取得失敗等）。UI 変更を含むため メンテナ 手動マージ待ち" >&2
      return 1
      ;;
    cancelled)
      echo "e2e CI cancelled（最新 push の concurrency cancel 想定）。次回ジョブ完了を待機" >&2
      return 1
      ;;
    fail)
      echo "e2e CI 失敗。UI 変更を含むため自動マージ不可" >&2
      return 1
      ;;
    *)
      # 未知 status → fail-safe で OK（勝手に block しない、 fail open）
      echo "[e2e] 未知の CI status '$ci_status' → fail-safe で OK 扱い" >&2
      return 0
      ;;
  esac
}

# Wrapper（fs）: リポジトリ HEAD 時点で L1 golden-path spec を持つフロントアプリを列挙
# Args: frontend_apps（改行区切り）
# Stdout: apps/<app>/e2e/golden-path.spec.ts が存在するアプリ（改行区切り）
# Note: /auto-merge は PR ブランチの worktree 内で走るため、PR で追加された spec も検出できる。
e2e_l1_spec_apps() {
  local frontend_apps="$1" app
  local root="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  while IFS= read -r app; do
    [ -z "$app" ] && continue
    if [ -f "$root/$app/e2e/golden-path.spec.ts" ]; then
      printf '%s\n' "$app"
    fi
  done <<<"$frontend_apps"
}

# Wrapper（gh）: PR の e2e workflow check 状態を取得し enum 化（matrix は reduce で集約）
# Args: pr_num
# Stdout: pass|fail|pending|skipped|cancelled|neutral|none|error
# Note:
#   - e2e.yml（name: "E2E (UI autopilot)" / job: e2e）の check を name/workflow の
#     大文字小文字無視 "e2e" マッチで抽出し、gh の `bucket` 値で判定する。
#   - **exit code で JSON を破棄しない**（Codex 指摘）: gh pr checks は fail で exit 1 /
#     pending で exit 8 を返すが、いずれも有効な JSON 配列を出力する。判定は JSON の
#     妥当性（有効な配列か）で行い、exit code には依存しない。
#   - 取得不能（gh/jq 不在・認証/network エラーで有効配列が得られない）は `error` を返す。
#     `error` は check 未存在の `none`（graceful OK）と区別され、enforced アプリでは
#     fail-open を防ぐため block 側に倒す（check_e2e_from_data 参照）。
#   - 有効配列だが e2e にマッチする check が無い（未配線）→ `none`。
e2e_ci_status() {
  local pr="$1"
  command -v gh >/dev/null 2>&1 || { echo "error"; return 0; }
  command -v jq >/dev/null 2>&1 || { echo "error"; return 0; }

  # exit code は無視し stdout のみ捕捉（fail=1 / pending=8 でも有効 JSON が来る）
  local checks_json
  checks_json=$(gh pr checks "$pr" --json name,bucket,workflow 2>/dev/null)

  # 有効な JSON 配列が取れなければ取得不能 = error（none と区別）
  if ! printf '%s' "$checks_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "error"
    return 0
  fi

  # e2e にマッチする check の bucket を小文字で抽出
  local buckets mapped="" b
  buckets=$(printf '%s' "$checks_json" \
    | jq -r '.[] | select((.workflow // "" | ascii_downcase | test("e2e")) or (.name // "" | ascii_downcase | test("e2e"))) | .bucket // "" | ascii_downcase' 2>/dev/null)

  # 配列は有効だが e2e 該当 check 無し → 未配線 = none（graceful）
  [ -z "$buckets" ] && { echo "none"; return 0; }
  while IFS= read -r b; do
    [ -z "$b" ] && continue
    mapped+="$(map_e2e_bucket "$b")"$'\n'
  done <<<"$buckets"

  reduce_e2e_statuses "$mapped"
}

# Wrapper（gh）: GitHub Actions 月次利用率 Variable（ACTIONS_USAGE_PCT）を取得
# Stdout: 整数文字列（取得失敗・未設定は空文字）
# Note: 外部 Worker が日次更新する Variable。取得失敗は空 → fail-safe。
e2e_actions_usage_pct() {
  command -v gh >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local repo val
  repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || return 0
  [ -z "$repo" ] && return 0
  val=$(gh api "repos/$repo/actions/variables/ACTIONS_USAGE_PCT" --jq '.value' 2>/dev/null) || return 0
  printf '%s' "$val"
}

# Wrapper（gh）: PR の failing check ごとに「実行されたステップ数」を列挙（{ISSUE-ID}）
# Args: pr_number
# Stdout: "check_name\texecuted_steps"（改行区切り。取得不能な check は -1）
# Note: bucket=fail / cancel の check を対象に、対応する workflow run の非 success ジョブの
#   実行済みステップ数を合算する。GitHub Actions 課金枯渇でジョブが起動しなかった場合、
#   ジョブの steps は空（= 0）になるため「CI 不発」と「実行されて失敗」を区別できる。
#   取得失敗はすべて -1 を出力し、check_ci_fallback_from_data 側で fail-closed に倒す。
ci_unstarted_failing_jobs() {
  local pr="$1"
  command -v gh >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local checks_json
  checks_json=$(gh pr checks "$pr" --json name,bucket,link 2>/dev/null)
  printf '%s' "$checks_json" | jq -e 'type == "array"' >/dev/null 2>&1 || return 0

  local name link run_id steps
  while IFS=$'\t' read -r name link; do
    [ -z "$name" ] && continue
    run_id=$(printf '%s' "$link" | grep -oE '/actions/runs/[0-9]+' | grep -oE '[0-9]+' | head -1)
    steps="-1"
    if [ -n "$run_id" ]; then
      steps=$(gh run view "$run_id" --json jobs \
        --jq '[.jobs[] | select(.conclusion != "success") | (.steps | length)] | add // 0' 2>/dev/null) || steps="-1"
      [[ "$steps" =~ ^[0-9]+$ ]] || steps="-1"
    fi
    printf '%s\t%s\n' "$name" "$steps"
  done < <(printf '%s' "$checks_json" \
    | jq -r '.[] | select(.bucket == "fail" or .bucket == "cancel") | "\(.name)\t\(.link // "")"')
}

# Pure: statusCheckRollup の長さ 1 観測から「CI 待ち step の次アクション」を分類する（{ISSUE-ID}）
# Args: rollup_len（gh の .statusCheckRollup | length。取得失敗時は空文字/非数値）
#       attempt（現在の試行回数、1 始まり） max_attempts（最大試行回数）
# Stdout: present | retry | absent
#
# 背景（本 Issue の核心）: PR 作成直後の数十秒は checks が未登録で rollup が一時的に空になる。
# 旧ロジックは「空 = CI 未設定」と即断して CI を待たずスキップ・マージしていた（レース素通し）。
# 本関数は「空」を即断せず、窓（max_attempts 回）内はリトライさせることで
# 「作成直後の空レース」と「真の CI 未設定リポジトリ（cc-autoship 配布先等）」を区別する。
#
# 判定（fail-safe = 迷ったら CI 待ち側 present に倒す。skip=absent は数値 0 を窓一杯まで観測した時のみ）:
#   - 数値 > 0            → present（checks 出現・CI 待ち watch へ。レース中に出現したケースを含む）
#   - 数値 == 0 かつ 途中 → retry（まだ窓の中。作成直後の空レースとして再ポーリング）
#   - 数値 == 0 かつ 最終 → absent（窓を使い切っても 0 = 真の CI 未設定。従来どおり graceful skip）
#   - 非数値（取得失敗）途中 → retry（一時的な gh 失敗はリトライ）
#   - 非数値（取得失敗）最終 → present（継続失敗を skip 側に倒さない。安全側で CI 待ちへ）
classify_ci_presence() {
  local rollup_len="$1" attempt="$2" max_attempts="$3"
  if [[ "$rollup_len" =~ ^[0-9]+$ ]]; then
    if [ "$rollup_len" -gt 0 ]; then
      echo "present"
    elif [ "$attempt" -ge "$max_attempts" ]; then
      echo "absent"
    else
      echo "retry"
    fi
  else
    # 取得失敗（空文字/非数値）: 一時的ならリトライ、継続失敗の最終試行は安全側 present（skip しない）
    if [ "$attempt" -ge "$max_attempts" ]; then
      echo "present"
    else
      echo "retry"
    fi
  fi
}

# Wrapper（gh）: CI 待ち step の前に statusCheckRollup をポーリングし、CI の有無を確定する（{ISSUE-ID}）
# Args: pr_number
# Stdout: present（CI checks あり → watch へ）| absent（真の CI 未設定 → skip 可）
# Returns: 常に 0
#
# 空 rollup を即「CI 未設定」と誤判定するレースを塞ぐため、classify_ci_presence の判定に従い
# 最大 AUTO_MERGE_CI_PRESENCE_ATTEMPTS 回（既定 9）× AUTO_MERGE_CI_PRESENCE_INTERVAL 秒（既定 10）
# = 約 90 秒まで checks の登録を待つ。checks が出現すれば即 present を返し無駄待ちしない。
# 真の CI 未設定リポジトリでは 90 秒の追加待ちのみで従来どおり absent（graceful）。
# 環境変数で試行回数/間隔を上書き可能（テストでは INTERVAL=0 で高速化する）。
auto_merge_wait_ci_presence() {
  local pr="$1"
  local max_attempts="${AUTO_MERGE_CI_PRESENCE_ATTEMPTS:-9}"
  local interval="${AUTO_MERGE_CI_PRESENCE_INTERVAL:-10}"
  local attempt=1 rollup_len decision
  while [ "$attempt" -le "$max_attempts" ]; do
    rollup_len=$(gh pr view "$pr" --json statusCheckRollup --jq '.statusCheckRollup | length' 2>/dev/null)
    decision=$(classify_ci_presence "$rollup_len" "$attempt" "$max_attempts")
    case "$decision" in
      present) echo "present"; return 0 ;;
      absent)  echo "absent";  return 0 ;;
      retry)   [ "$interval" -gt 0 ] 2>/dev/null && sleep "$interval" ;;
    esac
    attempt=$((attempt + 1))
  done
  # ループを抜ける＝最終試行が retry（理論上到達しない。classify は最終試行で present/absent を返す）。
  # 保険として安全側 present（CI 待ち）に倒す。
  echo "present"
}

# Wrapper（gh/git）: PR が「新規アプリ初期 PR」（サイズ上限免除対象）かを判定（{ISSUE-ID}）
# Args: pr_number
# Stdout: 1=免除対象, 0=非対象（判定不能はすべて 0 = fail-closed）
# 判定: new_app_candidate_from_files（全 added × 単一 apps/<app>/）+ 当該アプリが
#   origin/main（無ければ main）に存在しないこと。base ブランチを解決できない場合は免除しない。
auto_merge_new_app_exempt() {
  local pr="$1"
  command -v gh >/dev/null 2>&1 || { echo "0"; return 0; }

  local file_status_list candidate
  file_status_list=$(gh api "repos/{owner}/{repo}/pulls/$pr/files" --paginate \
    --jq '.[] | "\(.filename)\t\(.status)"' 2>/dev/null) || { echo "0"; return 0; }
  candidate=$(new_app_candidate_from_files "$file_status_list") || { echo "0"; return 0; }

  local base="origin/main"
  git rev-parse --verify -q "$base" >/dev/null 2>&1 || base="main"
  git rev-parse --verify -q "$base" >/dev/null 2>&1 || { echo "0"; return 0; }

  local tree
  if ! tree=$(git ls-tree -d "$base" -- "$candidate" 2>/dev/null); then
    echo "0"
    return 0
  fi
  if [ -n "$tree" ]; then
    echo "0"
    return 0
  fi
  echo "1"
}

# 集約関数: 全条件を評価し、Markdown テーブル形式で結果を stdout に出力
# Args: additions deletions file_count file_list review_text pr_body is_draft \
#       [td_additions] [td_deletions] [e2e_ui_apps] [e2e_spec_apps] [e2e_ci_status] [e2e_usage_pct]
# Returns: 0=全 OK（自動マージ可）, 1=いずれか NG（自動マージ不可）
#
# additions / deletions は **実コード行数**（テスト/.md 除外後）を渡す。
# td_additions / td_deletions（任意、省略時 0）はテスト/.md として除外された行数。
# 0 以外の値が渡された場合、判定ラベルに「テスト/.md XX 行除外」の注釈を付ける（{ISSUE-ID}）。
# e2e_* 引数（任意、{ISSUE-ID}）: UI 変更 PR の e2e enforcement 用。省略時は条件 8 を N/A（UI 変更なし）扱い。
# new_app_exempt（任意、{ISSUE-ID}）: 1 なら条件 1（サイズ）を新規アプリ初期 PR として免除。
#   免除フラグは wrapper（auto_merge_evaluate → auto_merge_new_app_exempt）が fail-closed に算出する。
evaluate_from_data() {
  local additions="$1" deletions="$2" file_count="$3"
  local file_list="$4" review_text="$5" pr_body="$6" is_draft="$7"
  local td_additions="${8:-0}" td_deletions="${9:-0}"
  local e2e_ui_apps="${10:-}" e2e_spec_apps="${11:-}" e2e_ci_status="${12:-none}" e2e_usage="${13:-}"
  local new_app_exempt="${14:-0}"
  local prod_total=$((additions + deletions))
  local td_total=$((td_additions + td_deletions))
  local size_label="1. 差分サイズ ≤ 500 行 / ≤ 10 ファイル"
  if [ "$td_total" -gt 0 ]; then
    # 実コード行の実数値も括弧内に含めて検証時の透明性を上げる（{ISSUE-ID} m3）
    size_label="1. 実コード差分 ${prod_total} 行 / 上限 500 行 / ≤ 10 ファイル（テスト/.md ${td_total} 行を除外）"
  fi
  if [ "$new_app_exempt" = "1" ]; then
    size_label="1. 差分サイズ（新規アプリ初期 PR につき上限免除: 実コード ${prod_total} 行 / ${file_count} ファイル）"
  fi

  local results=()
  local skipped=0
  local first_failure=""

  _eval() {
    local label="$1"
    shift
    if [ "$skipped" -eq 1 ]; then
      results+=("| $label | ⏭️ |")
      return
    fi
    local out
    out=$("$@" 2>&1)
    local rc=$?
    if [ "$rc" -eq 0 ]; then
      results+=("| $label | ✅ |")
    else
      results+=("| $label | ❌ $out |")
      skipped=1
      [ -z "$first_failure" ] && first_failure="$out"
    fi
  }

  if [ "$new_app_exempt" = "1" ]; then
    # 新規アプリ初期 PR（全ファイル added × 単一 apps/<app>/ × main に非存在）はサイズ免除。
    # 他条件（公開コンテンツ / 危険操作 / レビュー / e2e 等）は通常どおり評価する。
    _eval "$size_label" true
  else
    _eval "$size_label" \
      check_size_from_data "$additions" "$deletions" "$file_count"
  fi
  _eval "2. スコープ（infra / 単一内部アプリ）" \
    check_scope_from_files "$file_list"
  _eval "3. 公開コンテンツ非該当" \
    check_public_content_from_files "$file_list"
  _eval "4. レビュー判定 pass・Critical/Major ゼロ" \
    check_review_gate_from_text "$review_text"
  _eval "5. 危険操作なし" \
    check_dangerous_from_data "$file_list" "$pr_body"
  _eval "6. [manual-merge] タグなし" \
    check_optout_from_body "$pr_body"
  _eval "7. draft でない" \
    check_draft_from_flag "$is_draft"

  # 8. UI 変更時 e2e（L1 golden path）— {ISSUE-ID}。UI 変更なしは N/A で常に OK。
  local e2e_label="8. UI 変更時 e2e（L1 golden path）"
  if [ -z "$e2e_ui_apps" ]; then
    e2e_label="8. UI 変更時 e2e（UI 変更なし・N/A）"
  fi
  _eval "$e2e_label" \
    check_e2e_from_data "$e2e_ui_apps" "$e2e_spec_apps" "$e2e_ci_status" "$e2e_usage"

  # 9. self-modification guard（{ISSUE-ID} 自己改善ループ Phase 2a）。
  # [self-improve] マーカー付き PR（AI 起案の改善 PR）が保護パス（Tier P）に触れていないかを判定。
  # [self-improve] でない通常 PR は N/A で常に OK（既存 dev-flow の実装 PR は保護パスに正当に触れうる）。
  local self_improve_label="9. self-improve 保護パス非該当（[self-improve] でない・N/A）"
  if has_self_improve_marker_from_body "$pr_body"; then
    self_improve_label="9. [self-improve] PR は保護パス非該当"
  fi
  _eval "$self_improve_label" \
    check_self_improve_protected_paths_from_data "$file_list" "$pr_body"

  if [ "$skipped" -eq 1 ]; then
    echo "## 🤖 /auto-merge 判定結果: ❌ 自動マージ不可"
    echo
    echo "| 条件 | 結果 |"
    echo "|------|------|"
    printf '%s\n' "${results[@]}"
    echo
    echo "**結論**: ${first_failure}。メンテナ の手動マージが必要です。"
    return 1
  fi

  echo "## 🤖 /auto-merge 判定結果: ✅ 自動マージ可"
  echo
  echo "| 条件 | 結果 |"
  echo "|------|------|"
  printf '%s\n' "${results[@]}"
  echo
  echo "CI 完了を待って自動マージします。"
  return 0
}

# Pure: pr_data JSON 文字列から最新の一次レビューコメント本文を抽出
# Args: pr_data_json
# Stdout: 最新の一次レビューコメント本文（マッチなしなら空文字）
# 注: tail -1 は複数行 body の末尾改行を拾って空文字を返すため jq の `last` を使う
# 注: Codex 二次レビューコメント（マーカー `<!-- codex-secondary-review:` を持つ）は
#     脚注に「Claude 一次レビュー が authoritative」を含むため "一次レビュー" にマッチしてしまうが、
#     本来 Claude 一次レビューではないので除外する（{ISSUE-ID}）
extract_latest_review_from_pr_data() {
  local pr_data="$1"
  # 見出しパターンは検知 SSoT（lib/review-comment.sh の RC_REVIEW_HEADING_PATTERN）と
  # 同期を保つこと。`(^|\n)[ \t>]*##` で任意行の先頭（インデント / 引用 blockquote 付き
  # 含む）の見出しを許容する（SSoT の grep は `##` を任意行でマッチするため、本文 1 行目に
  # 見出しが無い＝先頭空行や前置き文がある場合でも検知だけ通って抽出に失敗し、auto-merge の
  # "レビュー存在" ゲートを誤ってブロックする回帰を防ぐ）。
  # 注: jq/Oniguruma の `"m"` フラグは DOTALL（`.` が改行にマッチ）であり、PCRE 的な行頭
  #     アンカーではない（`^` は本文全体の先頭にしかマッチしない）。そのため行頭アンカーは
  #     `(^|\n)` で明示し、見出し文字は `[^#\n]` で同一行に限定する（grep は行指向で SSoT が
  #     暗黙に同一行判定なのに合わせ、`##` 見出しと keyword が別行にまたがる誤マッチも防ぐ）。
  # 注: `## レビュー指摘修正結果`（--fix コメント）は判定根拠として扱わない（#1198 判断 1。
  #     判定ステータスを持たないため、gate は「最新の通常レビュー」のみを信頼し --fix 後は
  #     再 /review を必須とする）。見出しパターンの `レビュー指摘` は `レビュー指摘修正結果` を
  #     部分文字列として拾ってしまうため、先に --fix 見出しを持つコメントを明示除外する
  #     （見出し検知 SSoT: lib/review-comment.sh の RC_FIX_RESULT_HEADING_PATTERN と同期）。
  # {ISSUE-ID}（セキュリティ・作者非検証の封鎖）: レビューコメントは **信頼できる作者**
  # （自アカウント投稿 or repo write 権限保有者）のもののみを判定根拠にする。作者フィルタが
  # 無いと、公開/複数貢献者リポで PR にコメント可能な任意の GitHub ユーザーが偽の
  # `## レビュー結果 … 判定: pass` を投稿でき、last-wins で本物の判定を上書きして悪性 PR を
  # 自動マージさせられる（監査 deep-audit で実コード実行により再現）。
  #   - viewerDidAuthor == true: gh 認証中のアカウント（= cc-autoship 実行者）自身の投稿。
  #   - authorAssociation ∈ {OWNER, MEMBER, COLLABORATOR}: repo に write 権限を持つ作者
  #     （write があれば元々マージ可能なので信頼境界の内側）。CONTRIBUTOR / NONE /
  #     FIRST_TIME_CONTRIBUTOR 等の外部作者は除外する。
  #   - authorAssociation が null（＝フィールド欠落）は後方互換で信頼する。実 gh 出力
  #     （gh pr view --json comments）は authorAssociation を必ず含むため、この分岐は
  #     合成/レガシー入力（テスト等）にのみ効き、実運用の攻撃者は欠落を作れない。
  printf '%s' "$pr_data" \
    | jq -r '[.comments[]
        | select((.viewerDidAuthor == true)
                 or (.authorAssociation == null)
                 or (.authorAssociation == "OWNER")
                 or (.authorAssociation == "MEMBER")
                 or (.authorAssociation == "COLLABORATOR"))
        | select(.body | test("<!-- codex-secondary-review:") | not)
        | select(.body | test("(^|\n)[ \t>]*##[ \t]*[^#\n]*レビュー指摘修正結果") | not)
        | select(.body | test("(^|\n)[ \t>]*##[ \t]*[^#\n]*(レビュー結果|レビュー指摘|一次レビュー)"))
      ] | last | .body // ""'
}

# Pure: コメント一覧テキストから指定見出しの既存コメントの有無を判定（{ISSUE-ID}）
# Args: comments_text heading_substring
# Returns: 0=既存あり（投稿スキップすべき）, 1=既存なし（投稿すべき）
#
# 用途: /auto-merge ポーリング MERGED/CLOSED 検知時、Claude が手動操作で同等の
# 「マージ検知コメント」を既に投稿済みの状況で起床した場合に二重投稿を防ぐ。
# 検査は単純な部分文字列マッチ（grep -F）で行うため、絵文字付き見出し・
# 改行・前後空白の有無に robust。
check_comment_already_posted() {
  local comments_text="$1" heading="$2"
  if printf '%s' "$comments_text" | grep -qF -- "$heading"; then
    return 0
  fi
  return 1
}

# gh から PR コメント一覧を取得し、指定見出しの存在を判定
# Args: pr_number heading_substring
# Returns: 0=既存あり, 1=既存なし, 2=システムエラー
# 用途: /auto-merge スキルが MERGED / CLOSED 検知時の冪等投稿に使う
auto_merge_comment_exists() {
  local pr="$1" heading="$2"

  if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    return 2
  fi

  local comments_text
  if ! comments_text=$(gh pr view "$pr" --json comments --jq '.comments[].body' 2>/dev/null); then
    return 2
  fi

  check_comment_already_posted "$comments_text" "$heading"
}

# {ISSUE-ID}: closing issue が「未クローズ（要警告）」かを判定する純関数
# Args: issue_state（GitHub の "OPEN" / "CLOSED"、取得失敗時は空文字）
# Returns: 0=要警告（未クローズ or 状態不明）, 1=クローズ済み
# 大文字小文字を吸収し "CLOSED" のみクローズ扱いにする（gh は大文字で返す）
issue_needs_close_warning() {
  local state
  state=$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')
  [ "$state" = "CLOSED" ] && return 1
  return 0
}

# {ISSUE-ID}: Issue クローズ未確認の警告コメント本文を生成する純関数
# Args: issue_number issue_state
# stdout: PR コメント用 Markdown（状態が空なら「不明」と表示）
build_issue_close_warning() {
  local issue_num="$1" state="${2:-}"
  # backtick はリテラルの markdown 装飾（コマンド置換ではない）ため単一引用符のまま
  # shellcheck disable=SC2016
  printf '## ⚠️ /auto-merge Issue クローズ未確認\n\nPR にリンクされた Issue #%s が `%s` のまま閉じていません。手動 close するか PR 本文の `Closes` 記法（`Closes #{ISSUE-ID}` 混在など）を確認してください（`rules/dev-flow.md`「Closes 記法」参照）。' \
    "$issue_num" "${state:-不明}"
}

# {ISSUE-ID}: PR にリンクされた closing issue が auto-close されたか確認し、
# 未クローズなら警告コメントを 1 度だけ投稿する gh ラッパー（記法ミス / 伝播失敗の検知）。
# 判定・本文は上の純関数に委譲（テスト済み）。auto-close は非同期なので未クローズ時は
# 数秒の猶予を置いて 1 度だけ再確認し、伝播ラグによる誤検知を防ぐ。
# Args: pr_number
auto_merge_warn_unclosed_issues() {
  local pr="$1"
  command -v gh >/dev/null 2>&1 || return 0

  local issue_num state try
  for issue_num in $(gh pr view "$pr" --json closingIssuesReferences --jq '.closingIssuesReferences[].number' 2>/dev/null); do
    state=""
    for try in 1 2; do
      state=$(gh issue view "$issue_num" --json state --jq '.state' 2>/dev/null || echo "")
      issue_needs_close_warning "$state" || break
      [ "$try" = "1" ] && sleep 3
    done
    if issue_needs_close_warning "$state" \
       && ! auto_merge_comment_exists "$pr" "## ⚠️ /auto-merge Issue クローズ未確認"; then
      gh pr comment "$pr" --body "$(build_issue_close_warning "$issue_num" "$state")"
    fi
  done
}

# gh から PR メタデータを取得し、evaluate_from_data に渡す
# Args: pr_number
# Returns: 0=自動マージ可, 1=不可, 2=システムエラー
# stdout: PR コメント用 Markdown
auto_merge_evaluate() {
  local pr="$1"

  if ! command -v gh >/dev/null 2>&1; then
    echo "gh コマンドが見つかりません" >&2
    return 2
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq コマンドが見つかりません" >&2
    return 2
  fi

  local pr_data
  if ! pr_data=$(gh pr view "$pr" --json additions,deletions,files,body,isDraft,comments 2>&1); then
    echo "gh pr view 失敗: $pr_data" >&2
    return 2
  fi

  # zsh の `echo` はバックスラッシュエスケープを解釈し JSON を破壊するため
  # printf '%s' を使う（bash/zsh いずれから source されても安全）
  local file_count file_list pr_body is_draft review_text
  file_count=$(printf '%s' "$pr_data" | jq -r '.files | length')
  file_list=$(printf '%s' "$pr_data" | jq -r '.files[].path')
  pr_body=$(printf '%s' "$pr_data" | jq -r '.body // ""')
  is_draft=$(printf '%s' "$pr_data" | jq -r '.isDraft')
  review_text=$(extract_latest_review_from_pr_data "$pr_data")

  # {ISSUE-ID}: per-file diff を取り出してテスト/.md を除外した実コード行数で判定
  local file_diff_list categorized prod_add prod_del td_add td_del
  file_diff_list=$(printf '%s' "$pr_data" | jq -r '.files[] | "\(.path)\t\(.additions)\t\(.deletions)"')
  categorized=$(categorize_diff_lines_from_files "$file_diff_list")
  read -r prod_add prod_del td_add td_del <<< "$categorized"

  # {ISSUE-ID}: UI 変更 PR の e2e enforcement 用データを収集（graceful per-app）
  # UI 変更がある PR でのみ gh を叩く（非 UI PR で e2e CI / 利用量を取得する無駄な
  # round-trip と障害面を避ける。条件 8 は e2e_ui_apps 空なら N/A で即 OK のため）。
  local repo_root frontend_apps_file frontend_apps
  local e2e_ui_apps="" e2e_spec_apps="" e2e_status="none" e2e_usage=""
  repo_root="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  frontend_apps_file="${FRONTEND_APPS_FILE:-$repo_root/scripts/claude-hooks/data/frontend-apps.txt}"
  # frontend-apps.txt を読み込み（# 始まり・空行を除外）。ui-change-detect.sh の read_frontend_apps と同じ。
  frontend_apps=""
  [ -f "$frontend_apps_file" ] && frontend_apps=$(grep -vE '^[[:space:]]*(#|$)' "$frontend_apps_file" || true)
  e2e_ui_apps=$(ui_changed_apps_from_files "$file_list" "$frontend_apps")
  if [ -n "$e2e_ui_apps" ]; then
    e2e_spec_apps=$(e2e_l1_spec_apps "$frontend_apps")
    e2e_status=$(e2e_ci_status "$pr")
    e2e_usage=$(e2e_actions_usage_pct)
  fi

  # {ISSUE-ID}: 新規アプリ初期 PR のサイズ上限免除。
  # サイズ超過が確定するケースでのみ判定し、通常 PR で余計な gh api / git 呼び出しをしない。
  local new_app_exempt=0
  if [ $((prod_add + prod_del)) -gt "$AUTO_MERGE_MAX_LINES" ] || [ "$file_count" -gt "$AUTO_MERGE_MAX_FILES" ]; then
    new_app_exempt=$(auto_merge_new_app_exempt "$pr")
  fi

  evaluate_from_data \
    "$prod_add" "$prod_del" "$file_count" \
    "$file_list" "$review_text" "$pr_body" "$is_draft" \
    "$td_add" "$td_del" \
    "$e2e_ui_apps" "$e2e_spec_apps" "$e2e_status" "$e2e_usage" \
    "$new_app_exempt"
}