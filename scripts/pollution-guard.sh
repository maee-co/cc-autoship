#!/usr/bin/env bash
# NDA-safe release guard. Greps for mae-specific identifiers.
#
# 走査は「除外リスト方式」（#N）: .git 等を除いた **全ツリー** を見る。
# 旧実装の「列挙したディレクトリだけ見る」方式は、新しいトップレベルディレクトリが
# 増えるたびに穴が空いた（.github/FUNDING.yml の社内オペ手順が PASSED のまま
# v0.1.12 から公開され続けた実害）。除外は理由が明示できるものだけに絞る:
#   - .git / node_modules / .sessions … 非配布・ローカル状態
#   - __tests__            … 意図的なパターン fixture を含む
#   - .claude-plugin       … plugin.json / marketplace.json の author 実名は意図的な公開 attribution
#   - LICENSE              … MIT の copyright 行の実名は意図的な公開 attribution
#   - docs/repo-meta.md    … release 配置時に rl_is_internal_ops_doc が除外する内部手順
#   - pollution-guard.sh   … 自分自身（パターン定義を含む）
set -euo pipefail

# バイト単位マッチで決定的にする。多バイト記号（・／（等）前置の #番号 は
# 継続バイトが [^0-9a-zA-Z_& ] にマッチすることで拾う（#N ③ の全角前置形）。
export LC_ALL=C

ROOT="${1:-.}"

# fail-close（#N round 2）: ROOT が実在しないのに grep が 1 件もマッチせず
# PASSED を返す「検査していないのに PASSED」を塞ぐ（#N 系と同型・8 例目の予防）。
if [[ ! -d "$ROOT" ]]; then
  echo "Pollution guard ERROR: root not found: $ROOT" >&2
  exit 2
fi

# Patterns that must NEVER appear in released artifacts.
PATTERNS=(
  'MAE-[0-9]+'
  '@maee\.co'
  'discord\.com/api/webhooks'
  '\bdiggly\b'
  '\bmiserun\b'
  '\bportfolio\b'
  '\bbook-scanner\b'
  '\bslack-notion-proxy\b'
  '\bgas-api-gateway\b'
  '\bdocbase-downloader\b'
  'mae-inc'
  # UUID v4 (36 chars with dashes)
  '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b'
  # プロジェクト固有 Slack チャンネル名（内部専用チャンネルは外部公開不可）
  '#ceo-asks'
  # マシン固有絶対パス
  '/Users/mae'
  # core 内部 PR / Issue 番号（半角スペース前置形。例: ref #N。
  # {2,5}\b で 6 桁 hex 色（ #112233）を除外しつつ 5 桁 Issue 番号（#N）まで捕捉する
  # （MAE-954: {2,4} 上限では 5 桁以上の内部番号が漏れていた）
  ' #[0-9]{2,5}\b'
  # 同・全角記号/かな前置形（例: ・#N / （#N / ／#N。#N ③ で素通りした書式）。
  # 6 桁 hex 色（#112233）は末尾 \b が成立しないためマッチしない
  '[^0-9a-zA-Z_& ]#[0-9]{2,5}\b'
  # private repo への実 URL（公開読者には 404。#N ②）
  'github\.com/maee-co/core\b'
  # メンテナ実名のハードコード（散文中）
  'Kana Fujisawa'
  # 社内ロール表記（配布物では「メンテナ」表記に統一する。#N round 2:
  # auto-merge-run.sh の実行時 PR コメント「CEO の対応待ちです」が素通りした）
  '\bCEO\b'
)

FAIL=0
for pattern in "${PATTERNS[@]}"; do
  if grep -rEnI \
      --exclude="pollution-guard.sh" \
      --exclude="repo-meta.md" \
      --exclude="LICENSE" \
      --exclude-dir="__tests__" \
      --exclude-dir=".git" \
      --exclude-dir="node_modules" \
      --exclude-dir=".sessions" \
      --exclude-dir=".claude-plugin" \
      "$pattern" "$ROOT" 2>/dev/null; then
    echo "POLLUTION: pattern '$pattern' found" >&2
    FAIL=1
  fi
done

if [[ $FAIL -ne 0 ]]; then
  echo "Pollution guard FAILED. Sanitize the matches above before releasing." >&2
  exit 1
fi
echo "Pollution guard PASSED."