#!/bin/bash
# シンプルなテストランナー（bats 不要）
#
# 使い方:
#   bash test-runner.sh                       # 全件（CI・既定。この挙動は変えない）
#   bash test-runner.sh --only <pattern>      # ファイル名に <pattern> を含むテストだけ実行
#   bash test-runner.sh --only=<pattern>      # 同上（= 記法）
#
# --only は TDD の Red → Green ループ用。全件は 81 ファイル・2900 アサーション超で
# 4 分以上かかるため、1 サイクルごとに全件を待つコストが大きい。**ヘルパー注入の仕組みは
# 変えず、走らせる対象を絞るだけ**なので、テストファイルの単体実行が不可という設計
# （README / testing.md）はそのまま。
#
# fail-closed: マッチ 0 件は exit 1、未知のオプションは exit 2。
# 「絞ったつもりで 0 件 green」「タイポで黙って全件 4 分待つ」のどちらも起こさない。
set -uo pipefail

PASS=0
FAIL=0
ERRORS=()
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$(dirname "$SCRIPT_DIR")"

ONLY=""
# 空パターンを弾く（空だと全件実行に落ちて「絞ったつもりで 4 分待つ」事故になる）。
# `--only` を値なしで渡したときは shift 2 が失敗して**無限ループ**になるため、
# shift する前に引数の有無を確認する（実測でハングを再現・fail-closed で exit 2）。
_require_pattern() {
  if [ -z "${1:-}" ] || [ -z "${1//[[:space:]]/}" ]; then
    echo "--only にパターンを指定してください（使い方は --help）" >&2
    exit 2
  fi
}
while [ $# -gt 0 ]; do
  case "$1" in
    --only)
      _require_pattern "${2:-}"
      ONLY="$2"
      shift 2
      ;;
    --only=*)
      ONLY="${1#--only=}"
      _require_pattern "$ONLY"
      shift
      ;;
    -h|--help)
      # ヘッダコメントを sed の行番号で切り出すと、コメントを 1 行足しただけで
      # 無言でズレる（別の行が help として出る）。ここは literal で持つ。
      cat <<'USAGE'
使い方:
  bash test-runner.sh                    # 全件（CI・既定）
  bash test-runner.sh --only <pattern>   # ファイル名に <pattern> を含むテストだけ実行
  bash test-runner.sh --only=<pattern>   # 同上（= 記法）

exit: 0=全 pass / N=失敗数 / 1=マッチ 0 件 / 2=引数エラー
USAGE
      exit 0
      ;;
    *)
      echo "unknown option: ${1}（使い方は --help）" >&2
      exit 2
      ;;
  esac
done

# カラー出力
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

assert_eq() {
  local expected="$1" actual="$2" msg="${3:-}"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}✓${NC} $msg"
  else
    FAIL=$((FAIL + 1))
    ERRORS+=("$msg: expected='$expected' actual='$actual'")
    echo -e "  ${RED}✗${NC} $msg (expected='$expected', actual='$actual')"
  fi
}

assert_exit_code() {
  local expected="$1" actual="$2" msg="${3:-}"
  assert_eq "$expected" "$actual" "$msg (exit code)"
}

assert_contains() {
  local needle="$1" haystack="$2" msg="${3:-}"
  # here-string（<<<）で渡す: `echo ... | grep -qF` の 2 コマンドパイプラインだと、
  # GNU grep の -q は「マッチ発見時に即 exit（残りの stdin を読まない）」ため、
  # haystack が数 KB を超える（例: SKILL.md 構造テスト）と echo が書き込み中に
  # 読み手を失って SIGPIPE（`write error: Broken pipe`）で落ち、pipefail 下では
  # その echo の非 0 終了코드がパイプライン全体の終了コードとして扱われて
  # 「grep は見つけているのに if が false 判定」という偽陰性になる
  # （ubuntu-latest・GNU grep で実測。BSD grep の macOS ローカルでは再現しない
  # ため長期間気付かれなかった・#1295 Phase 2）。here-string は単一コマンドの
  # 標準入力になるため、この 2 プロセス間 SIGPIPE 競合が原理的に発生しない。
  if grep -qF -- "$needle" <<<"$haystack"; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}✓${NC} $msg"
  else
    FAIL=$((FAIL + 1))
    ERRORS+=("$msg: '$needle' not found in output")
    echo -e "  ${RED}✗${NC} $msg ('$needle' not found)"
  fi
}

assert_not_contains() {
  local needle="$1" haystack="$2" msg="${3:-}"
  # here-string の理由は assert_contains のコメント参照（SIGPIPE + pipefail 偽陰性回避）。
  if ! grep -qF -- "$needle" <<<"$haystack"; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}✓${NC} $msg"
  else
    FAIL=$((FAIL + 1))
    ERRORS+=("$msg: '$needle' should not be in output")
    echo -e "  ${RED}✗${NC} $msg ('$needle' found but should not be)"
  fi
}

assert_valid_json() {
  local json="$1" msg="${2:-}"
  # here-string の理由は assert_contains のコメント参照（SIGPIPE + pipefail 偽陰性回避）。
  # jq は基本フルパースだが、巨大 JSON の早期構文エラー検出等で同型の race を踏む
  # 可能性を構造的に排除するため同じパターンに統一する。
  if jq . <<<"$json" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}✓${NC} $msg"
  else
    FAIL=$((FAIL + 1))
    ERRORS+=("$msg: invalid JSON")
    echo -e "  ${RED}✗${NC} $msg (invalid JSON)"
  fi
}

# テストファイルを実行
run_test_file() {
  local test_file="$1"
  local test_name="$2"
  local result_file
  result_file=$(mktemp -t claude-hooks-test-result.XXXXXX)

  (
    PASS=0
    FAIL=0
    ERRORS=()
    source "$test_file"
    {
      printf '%s\n' "$PASS"
      printf '%s\n' "$FAIL"
      printf '%s\n' "${ERRORS[@]}"
    } > "$result_file"
    exit "$FAIL"
  )
  local rc=$?

  if [ -s "$result_file" ]; then
    local file_pass file_fail
    file_pass=$(sed -n '1p' "$result_file")
    file_fail=$(sed -n '2p' "$result_file")
    PASS=$((PASS + file_pass))
    FAIL=$((FAIL + file_fail))
    if [ "$file_fail" -gt 0 ]; then
      while IFS= read -r err; do
        [ -n "$err" ] && ERRORS+=("$test_name: $err")
      done < <(sed '1,2d' "$result_file")
    fi
  else
    FAIL=$((FAIL + 1))
    ERRORS+=("$test_name: テストファイルが結果集計前に終了しました (exit=$rc)")
  fi

  rm -f "$result_file"
}

MATCHED=0

run_tests() {
  for test_file in "$SCRIPT_DIR"/test-*.sh; do
    [ "$test_file" = "$SCRIPT_DIR/test-runner.sh" ] && continue
    [ -f "$test_file" ] || continue
    local test_name
    test_name=$(basename "$test_file" .sh)
    # --only 指定時はファイル名（basename）に部分一致するものだけ走らせる
    if [ -n "$ONLY" ]; then
      case "$test_name" in
        *"$ONLY"*) ;;
        *) continue ;;
      esac
    fi
    MATCHED=$((MATCHED + 1))
    echo -e "\n${YELLOW}=== $test_name ===${NC}"
    run_test_file "$test_file" "$test_name"
  done
}

run_tests

# 0 件マッチは fail（「絞ったつもりで 1 件も走らず green」を green と誤認させない）
if [ "$MATCHED" -eq 0 ]; then
  if [ -n "$ONLY" ]; then
    echo -e "\n${RED}❌ --only '$ONLY' にマッチするテストがありません（0 件実行は green ではない）${NC}" >&2
  else
    echo -e "\n${RED}❌ テストファイルが 1 件も見つかりません（glob 破損の疑い）${NC}" >&2
  fi
  exit 1
fi

echo -e "\n${YELLOW}=== 結果 ===${NC}"
echo -e "${GREEN}Pass: $PASS${NC}  ${RED}Fail: $FAIL${NC}"

if [ ${#ERRORS[@]} -gt 0 ]; then
  echo -e "\n${RED}失敗詳細:${NC}"
  for err in "${ERRORS[@]}"; do
    echo -e "  ${RED}• $err${NC}"
  done
fi

exit $FAIL
