#!/usr/bin/env bash
# NDA-safe release guard. Greps for mae-specific identifiers.
# Exit non-zero if any pattern matches under rules/ skills/ commands/ scripts/ templates/.

set -euo pipefail

ROOT="${1:-.}"
SEARCH_DIRS=("rules" "skills" "commands" "scripts" "templates")

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
  # core 内部 PR / Issue 番号コメント（例: ref #654）
  ' #[0-9]+'
  # メンテナ実名のハードコード（散文中）
  'Kana Fujisawa'
)

FAIL=0
for dir in "${SEARCH_DIRS[@]}"; do
  [[ -d "$ROOT/$dir" ]] || continue
  for pattern in "${PATTERNS[@]}"; do
    # Skip self and test files (__tests__/ contains intentional pattern fixtures)
    if grep -rEn \
        --exclude="pollution-guard.sh" \
        --exclude-dir="__tests__" \
        "$pattern" "$ROOT/$dir" 2>/dev/null; then
      echo "POLLUTION: pattern '$pattern' found in $dir/" >&2
      FAIL=1
    fi
  done
done

if [[ $FAIL -ne 0 ]]; then
  echo "Pollution guard FAILED. Sanitize the matches above before releasing." >&2
  exit 1
fi
echo "Pollution guard PASSED."
