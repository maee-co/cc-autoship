#!/usr/bin/env bash
# codex-diagnostics.sh — codex runtime の可観測性プローブ
#
# 背景（{ISSUE-ID} / #N の後続・別レイヤ）:
#   可用性判定（codex-availability.sh の csr_codex_available_default）は
#   (1) CLI 実在 (2) enabledPlugins で有効 (3) agent 定義ファイル実在 を見るが、
#   これらが**すべて pass しても** companion runtime（`task`）が exit 1・stdout 空で
#   失敗することがある（PR #N / 2026-07-21 実測）。原因は runtime レイヤにあるが、
#   codex-rescue agent は仕様上 **stdout しか返さず**（"Return the stdout ... If the Bash
#   call fails or Codex cannot be invoked, return nothing"）、companion のエラーは
#   **stderr に出て破棄される**ため、失敗理由が呼び出し元（本スキル）に一切伝わらない。
#
#   本 lib は、その破棄されるシグナルをローカルで捕捉して「無音のブラックボックス失敗」を
#   診断可能にする。可用性判定を置き換えるものではなく、判定 pass 後に spawn 結果が空だった
#   ときの**事後の切り分け材料**を提供する（=「まず可観測性を上げる」= 本 Issue の主眼）。
#
# 設計方針:
#   - **非破壊・非投稿**: PR には投稿しない（"静かに失敗" 契約を維持）。診断はローカル報告用。
#   - **軽量・非課金**: liveness は `codex --version`（ローカル・非ネットワーク）のみ。
#     `codex exec` 等の API 課金・ネットワーク往復は踏まない（それは手動の深掘り手順）。
#   - **秘密を出さない**: auth.json は**実在（present/missing）だけ**を報告し、中身は読まない。
#   - **cmux shim 対策**: `command -v codex` で**解決される実体パス**と version を記録する。
#     PATH 解決が別 codex（cmux shim 等）を指していないかを事後に判別できる（本 Issue foothold 2）。
#   - bash 3.2（素の macOS）で動く / `set -u` の呼び出し元でも unbound を出さない。

# codex --version を軽量 timeout 付きで実行する（あれば timeout/gtimeout、無ければ直接）。
# 出力は呼び出し側で outfile/errfile へリダイレクトして捕捉する。
_csr_run_version() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 10 codex --version
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout 10 codex --version
    else
        codex --version
    fi
}

# ファイルの先頭 1 行を最大 200 文字に丸めて返す（CR 除去）。空/不在なら空文字。
_csr_first_line_trunc() {
    local f="${1:-}"
    [ -n "$f" ] && [ -s "$f" ] || return 0
    head -n1 "$f" 2>/dev/null | cut -c1-200 | tr -d '\r'
}

# codex runtime の診断を key=value 行で標準出力に出す（rc は常に 0 = レポータ）。
#   csr_runtime_diagnostics <auth_json_path> <plugin_cache_root>
# 出力キー（固定順）:
#   codex_bin      … command -v codex の解決パス / not-found
#   version        … codex --version の stdout 先頭行 / (empty) / na（codex 不在）
#   version_exit   … codex --version の exit code / na
#   version_stderr … codex --version の stderr 先頭行（丸め）/ (empty) / na
#   auth_json      … present / missing（**中身は読まない**）
#   plugin_cache   … present / missing
csr_runtime_diagnostics() {
    local auth_json="${1:-}" cache_root="${2:-}"
    local bin ver ver_exit ver_err

    bin=$(command -v codex 2>/dev/null || true)
    if [ -z "$bin" ]; then
        bin="not-found"
        ver="na"; ver_exit="na"; ver_err="na"
    else
        local outfile errfile
        outfile=$(mktemp 2>/dev/null) || outfile="${TMPDIR:-/tmp}/csr-diag-out.$$"
        errfile=$(mktemp 2>/dev/null) || errfile="${TMPDIR:-/tmp}/csr-diag-err.$$"
        _csr_run_version >"$outfile" 2>"$errfile"
        ver_exit=$?
        ver=$(_csr_first_line_trunc "$outfile")
        ver_err=$(_csr_first_line_trunc "$errfile")
        [ -n "$ver" ] || ver="(empty)"
        [ -n "$ver_err" ] || ver_err="(empty)"
        rm -f "$outfile" "$errfile"
    fi

    local auth="missing"
    [ -n "$auth_json" ] && [ -f "$auth_json" ] && auth="present"

    local cache="missing"
    [ -n "$cache_root" ] && [ -d "$cache_root" ] && cache="present"

    printf 'codex_bin=%s\n' "$bin"
    printf 'version=%s\n' "$ver"
    printf 'version_exit=%s\n' "$ver_exit"
    printf 'version_stderr=%s\n' "$ver_err"
    printf 'auth_json=%s\n' "$auth"
    printf 'plugin_cache=%s\n' "$cache"
    return 0
}

# 実環境の既定パスで診断するラッパー（SKILL.md から呼ぶ入口）。
#   ~/.codex/auth.json（存在のみ）/ ~/.claude/plugins/cache（存在のみ）
csr_runtime_diagnostics_default() {
    # HOME 未設定でも `set -u` の呼び出し元で落ちないよう既定値を与える。
    local home_dir="${HOME:-}"
    csr_runtime_diagnostics \
        "${home_dir}/.codex/auth.json" \
        "${home_dir}/.claude/plugins/cache"
}