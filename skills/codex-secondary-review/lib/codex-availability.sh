#!/usr/bin/env bash
# codex-availability.sh — Codex 二次レビューの可用性判定（純関数・#N / {ISSUE-ID}）
#
# 背景:
#   {ISSUE-ID} で「spawn 前に可用性を判定してエラー表示を無音化する」を入れたが、判定が
#   (1) CLI 実在 (2) agent 定義ファイル実在 の 2 条件だけだった。plugin cache は残るが
#   プラグインが**有効化されていない**状態（installed ≠ enabled）を可用と誤判定し、
#   `Agent type 'codex:codex-rescue' not found` が再発した（PR #N で実測）。
#   本 lib は「有効化されているか」を第 3 条件として加える。
#
# 設計方針（{ISSUE-ID} から継承）:
#   - 非ネットワーク・決定的（ファイル読みのみ。同一入力で必ず同一結果）
#   - 誤って「可用」と出た場合は呼び出し側で spawn 失敗 → 静かに失敗にフォールバック
#     （安全側の二段構え。本判定は最終権威ではない）
#   - 判定不能（jq 不在・JSON 破損）は**不可用に倒す**。二次レビューは補助情報であり、
#     スキップしても /auto-merge をブロックしない = 取りこぼしより誤エラー表示を避ける
#
# `codex_autolaunch_enabled`（scripts/claude-hooks/lib/codex-trigger-criteria.sh）との違い:
#   あちらは「**自動起動してよいか**」のポリシーゲート（privacy / opt-in。明示 [codex-review]
#   は無視して常時通す）。本 lib は「**そもそも起動できるか**」の能力チェック。直交する概念で、
#   両方 true のときだけ hook 経由の自動二次レビューが成立する。

# プラグインが enabledPlugins で明示的に有効化されているか。
#   csr_plugin_enabled <plugin_key> <settings_file>...
# settings は**優先順に**渡す（local > project > user）。最初に明示値（true/false）を
# 持つファイルが確定させ、以降は見ない。どこにも明示値が無ければ「無効」。
#
# 「不在 = 無効」の根拠（実測・{ISSUE-ID}）: 同一マシンで enabledPlugins に true のものは
# ロードされ、false のもの・エントリが無いものはロードされていない。不在を「既定で有効」と
# 読むと、まさに今回の誤判定になる。
csr_plugin_enabled() {
    local key="${1:-}"
    shift || true
    [ -n "$key" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1

    local file value
    for file in "$@"; do
        [ -f "$file" ] || continue
        # 破損 JSON は jq が非ゼロ終了 → 明示値なし扱いで次スコープへ。
        # `// "unset"` は使わない: jq の `//` は null だけでなく **false も「空」扱い**するため、
        # 明示 false が「未設定」に化けて次スコープへ漏れる（{ISSUE-ID} の TDD で検出）。
        value=$(jq -r --arg k "$key" \
            'if ((.enabledPlugins // {}) | has($k)) then (.enabledPlugins[$k] | tostring) else "unset" end' \
            "$file" 2>/dev/null) || continue
        case "$value" in
            true)  return 0 ;;
            false) return 1 ;;
            *)     continue ;;  # unset / null / 想定外の型は確定させない
        esac
    done
    return 1
}

# codex-rescue の agent 定義ファイルが実在するか。
#   csr_agent_definition_exists <plugin_cache_root> <project_dir>
# plugin cache（marketplace/codex/version/agents/）とプロジェクト直下の両方を見る。
csr_agent_definition_exists() {
    local cache_root="${1:-}" project_dir="${2:-}" p
    # 空文字を渡されたときにファイルシステムのルートから glob しないようガードする
    if [ -n "$cache_root" ]; then
        for p in "$cache_root"/*/codex/*/agents/codex-rescue.md; do
            [ -f "$p" ] && return 0
        done
    fi
    if [ -n "$project_dir" ] && [ -f "$project_dir/.claude/agents/codex-rescue.md" ]; then
        return 0
    fi
    return 1
}

# Codex 二次レビューが実行可能か（3 条件の AND）。
#   csr_codex_available <plugin_key> <plugin_cache_root> <project_dir> <settings_file>...
# 1. codex CLI が PATH にある
# 2. プラグインが enabledPlugins で有効（{ISSUE-ID} で追加）
# 3. codex-rescue の agent 定義が実在する
csr_codex_available() {
    local key="${1:-}" cache_root="${2:-}" project_dir="${3:-}"
    shift 3 2>/dev/null || return 1

    command -v codex >/dev/null 2>&1 || return 1
    csr_plugin_enabled "$key" "$@" || return 1
    csr_agent_definition_exists "$cache_root" "$project_dir" || return 1
    return 0
}

# 実環境の既定パスで判定するラッパー（SKILL.md から呼ぶ入口）。
# settings は優先順（local > project > user）で渡す。
csr_codex_available_default() {
    # HOME / CLAUDE_PROJECT_DIR とも既定値を与える。`set -u` の呼び出し元で未設定だと
    # unbound variable エラーが表示され、本スキルが消そうとしているエラー行そのものになる。
    local project_dir="${CLAUDE_PROJECT_DIR:-.}"
    local home_dir="${HOME:-}"
    csr_codex_available \
        "codex@openai-codex" \
        "${home_dir}/.claude/plugins/cache" \
        "$project_dir" \
        "${project_dir}/.claude/settings.local.json" \
        "${project_dir}/.claude/settings.json" \
        "${home_dir}/.claude/settings.json"
}