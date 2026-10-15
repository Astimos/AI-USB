#!/usr/bin/env bash
#
# scripts/fetch-agents.sh - build the complete AI-USB data-partition tree in
# build/payload (the "$USB" of ARCHITECTURE.md section 3) on the developer
# machine. Downloads are cached by file name in build/cache/downloads.
# Normal user, no root required.
#
# Usage: scripts/fetch-agents.sh [--claude-channel stable|latest] [--clean] [--only STEP[,STEP...]]
#   --only fetches just the named agents (claude, codex, age, antigravity) and keeps the rest
#   of build/payload as it is.

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths and constants
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly REPO_ROOT
CACHE="$REPO_ROOT/build/cache/downloads"
readonly CACHE
OUT="$REPO_ROOT/build/payload"
readonly OUT

readonly CLAUDE_BASE="https://downloads.claude.ai/claude-code-releases"
readonly CLAUDE_KEY_URL="https://downloads.claude.ai/keys/claude-code.asc"
readonly CLAUDE_KEY_FPR="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"
readonly GITHUB_API="https://api.github.com"
# Antigravity CLI release manifests (the source its own install.sh/install.ps1 use): JSON with
# version, url and sha512 per platform.
readonly AGY_MANIFESTS="https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests"
readonly AGY_URL_PREFIX="https://storage.googleapis.com/antigravity-public/antigravity-cli/"

# ---------------------------------------------------------------------------
# Mutable state
# ---------------------------------------------------------------------------

CLAUDE_CHANNEL="stable"
DO_CLEAN=0
WORK=""
CLEANUP_DIRS=()
CLAUDE_VERSION=""
CODEX_VERSION=""
AGE_VERSION=""
AGY_VERSION=""
ONLY=""

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

info() {
    printf '==> %s\n' "$*"
}

usage() {
    printf 'Usage: scripts/fetch-agents.sh [--claude-channel stable|latest] [--clean] [--only STEP[,STEP...]]\n'
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

register_cleanup() {
    CLEANUP_DIRS+=("$1")
}

cleanup() {
    local dir
    if [[ "${#CLEANUP_DIRS[@]}" -eq 0 ]]; then
        return 0
    fi
    for dir in "${CLEANUP_DIRS[@]}"; do
        if [[ -d "$dir" ]]; then
            GNUPGHOME="$dir" gpgconf --kill all >/dev/null 2>&1 || true
            rm -rf -- "$dir"
        fi
    done
}

hash_sha256() {
    sha256sum "$1" | awk '{ print $1 }'
}

# hash_of <file> <sha256|sha512>
hash_of() {
    case "$2" in
        sha512) sha512sum "$1" | awk '{ print $1 }' ;;
        *)      hash_sha256 "$1" ;;
    esac
}

verify_sha256() {
    verify_hash "$1" "$2" sha256
}

# verify_hash <file> <expected> <sha256|sha512>
verify_hash() {
    local file="$1"
    local expected="$2"
    local algo="$3"
    local actual
    actual="$(hash_of "$file" "$algo" | tr '[:upper:]' '[:lower:]')"
    expected="$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')"
    if [[ "$actual" != "$expected" ]]; then
        die "$algo mismatch for $(basename "$file") (expected $expected, got $actual)"
    fi
}

# download <url> <final-path>
download() {
    local url="$1"
    local final="$2"
    local dir
    local tmp
    if [[ -s "$final" ]]; then
        return 0
    fi
    dir="$(dirname "$final")"
    mkdir -p "$dir"
    tmp="$(mktemp "$dir/.download.XXXXXXXX")"
    if ! curl -fsSL --retry 3 --retry-delay 2 -o "$tmp" "$url"; then
        rm -f -- "$tmp"
        die "download failed: $url"
    fi
    mv -- "$tmp" "$final"
}

# fetch_cached <url> [expected_hash] [sha256|sha512]
# Caches the URL under $CACHE keyed by file name and prints the local path.
# When an expected hash is given, a cached copy that no longer matches (the
# upstream version moved on) is downloaded again, then verified.
fetch_cached() {
    local url="$1"
    local expected="${2:-}"
    local algo="${3:-sha256}"
    local final
    final="$CACHE/$(basename "$url")"
    if [[ -z "$expected" ]]; then
        # Nothing to check a cached copy against (names are not versioned): refetch.
        rm -f -- "$final"
    elif [[ -s "$final" ]]; then
        if [[ "$(hash_of "$final" "$algo" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')" ]]; then
            rm -f -- "$final"
        fi
    fi
    download "$url" "$final"
    if [[ -n "$expected" ]]; then
        verify_hash "$final" "$expected" "$algo"
    fi
    printf '%s\n' "$final"
}

# curl_api <url> <outfile> - fetch a small text/JSON resource to a file
curl_api() {
    local url="$1"
    local outfile="$2"
    local tmp
    tmp="$(mktemp "$WORK/.api.XXXXXXXX")"
    if ! curl -fsSL --retry 3 --retry-delay 2 -o "$tmp" "$url"; then
        rm -f -- "$tmp"
        die "request failed: $url"
    fi
    mv -- "$tmp" "$outfile"
}

# extract_archive <archive> <dir>
extract_archive() {
    local archive="$1"
    local dir="$2"
    mkdir -p "$dir"
    case "$archive" in
        *.tar.gz|*.tgz)
            tar -xzf "$archive" -C "$dir" || die "tar failed: $archive"
            ;;
        *.tar.xz)
            tar -xJf "$archive" -C "$dir" || die "tar failed: $archive"
            ;;
        *.zip)
            if command -v unzip >/dev/null 2>&1; then
                unzip -oq "$archive" -d "$dir" || die "unzip failed: $archive"
            elif command -v bsdtar >/dev/null 2>&1; then
                bsdtar -xf "$archive" -C "$dir" || die "bsdtar failed: $archive"
            else
                die "need unzip or bsdtar to extract $archive"
            fi
            ;;
        *)
            die "unknown archive type: $archive"
            ;;
    esac
}

# locate_file <dir> <name-pattern> [name-pattern...]
# Prints the first regular file matching any pattern; fails if none match.
locate_file() {
    local dir="$1"
    shift
    local pattern
    local path
    for pattern in "$@"; do
        path="$(find "$dir" -type f -name "$pattern" -print -quit)"
        if [[ -n "$path" ]]; then
            printf '%s\n' "$path"
            return 0
        fi
    done
    return 1
}

# asset_url <release.json> <asset-name> [alt-name...]
asset_url() {
    python3 -c '
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
names = sys.argv[2:]
for asset in data.get("assets", []):
    if asset.get("name") in names:
        print(asset.get("browser_download_url", ""))
        sys.exit(0)
sys.exit(1)
' "$@"
}

# asset_digest <release.json> <asset-name> [alt-name...]
# Prints the bare sha256 hex digest, or an empty string when there is none.
asset_digest() {
    python3 -c '
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
names = sys.argv[2:]
for asset in data.get("assets", []):
    if asset.get("name") in names:
        digest = asset.get("digest") or ""
        if digest.startswith("sha256:"):
            digest = digest.split(":", 1)[1]
        print(digest.strip().lower())
        sys.exit(0)
sys.exit(1)
' "$@"
}

release_tag() {
    python3 -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["tag_name"])' "$1"
}

manifest_checksum() {
    python3 -c '
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
value = data["platforms"][sys.argv[2]]["checksum"]
if value.startswith("sha256:"):
    value = value.split(":", 1)[1]
print(value.strip().lower())
' "$1" "$2"
}

shasum_for() {
    local sums="$1"
    local name="$2"
    local hash
    hash="$(awk -v f="$name" '$2 == f { print $1 }' "$sums")"
    if [[ -z "$hash" ]]; then
        die "no sha256 entry for $name in SHASUMS256.txt"
    fi
    printf '%s\n' "$hash"
}

total_size() {
    local out
    out="$(du -sch -- "$@" | tail -n 1 | cut -f1)"
    printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# GPG verification of the Claude Code manifest
# ---------------------------------------------------------------------------

verify_claude_manifest() {
    local manifest="$1"
    local sig="$2"
    local ghome
    local keyfile
    local fingerprints

    ghome="$(mktemp -d)"
    register_cleanup "$ghome"
    keyfile="$WORK/claude-code.asc"

    if ! curl -fsSL --retry 3 --retry-delay 2 -o "$keyfile" "$CLAUDE_KEY_URL"; then
        die "failed to download the Claude Code signing key"
    fi
    if ! GNUPGHOME="$ghome" gpg --batch --import "$keyfile" >/dev/null 2>&1; then
        die "failed to import the Claude Code signing key"
    fi
    fingerprints="$(GNUPGHOME="$ghome" gpg --batch --with-colons --fingerprint 2>/dev/null \
        | awk -F: '$1 == "fpr" { print $10 }')"
    if [[ "$fingerprints" != *"$CLAUDE_KEY_FPR"* ]]; then
        die "Claude Code signing key fingerprint mismatch (wanted $CLAUDE_KEY_FPR)"
    fi
    if ! GNUPGHOME="$ghome" gpg --batch --verify "$sig" "$manifest" >/dev/null 2>&1; then
        die "Claude Code manifest signature verification FAILED"
    fi
    printf '    manifest signature verified (gpg)\n'
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

step_payload() {
    info "[1/7] copying the repo payload tree"
    if [[ ! -d "$REPO_ROOT/payload" ]]; then
        die "payload directory not found: $REPO_ROOT/payload"
    fi
    mkdir -p \
        "$OUT/aiusb/bin/linux-x64" \
        "$OUT/aiusb/bin/win-x64" \
        "$OUT/aiusb/vault" \
        "$OUT/aiusb/workspace" \
        "$OUT/aiusb/logs" \
        "$OUT/aiusb/backups"
    cp -r "$REPO_ROOT/payload/." "$OUT/" || die "failed to copy the payload tree"
}

step_claude() {
    local raw
    local linux_sha
    local win_sha
    local manifest
    local sig
    local linux_file
    local win_file

    info "[2/7] fetching Claude Code (channel: $CLAUDE_CHANNEL)"

    if ! raw="$(curl -fsSL --retry 3 --retry-delay 2 "$CLAUDE_BASE/$CLAUDE_CHANNEL")"; then
        die "failed to get the Claude Code version for channel '$CLAUDE_CHANNEL'"
    fi
    CLAUDE_VERSION="$(printf '%s' "$raw" | tr -d '\r' | awk 'NF { print; exit }')"
    if [[ -z "$CLAUDE_VERSION" ]]; then
        die "the Claude Code '$CLAUDE_CHANNEL' channel returned no version"
    fi
    if [[ ! "$CLAUDE_VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        die "unexpected Claude Code version string: $CLAUDE_VERSION"
    fi
    printf '    version %s\n' "$CLAUDE_VERSION"

    manifest="$CACHE/claude-code-$CLAUDE_VERSION-manifest.json"
    sig="$manifest.sig"
    download "$CLAUDE_BASE/$CLAUDE_VERSION/manifest.json" "$manifest"
    download "$CLAUDE_BASE/$CLAUDE_VERSION/manifest.json.sig" "$sig"

    if command -v gpg >/dev/null 2>&1; then
        verify_claude_manifest "$manifest" "$sig"
    else
        printf 'warning: gpg not found, skipping Claude Code manifest signature check\n' >&2
    fi

    if ! linux_sha="$(manifest_checksum "$manifest" "linux-x64")"; then
        die "manifest has no linux-x64 checksum"
    fi
    if ! win_sha="$(manifest_checksum "$manifest" "win32-x64")"; then
        die "manifest has no win32-x64 checksum"
    fi

    linux_file="$(fetch_cached "$CLAUDE_BASE/$CLAUDE_VERSION/linux-x64/claude" "$linux_sha")"
    win_file="$(fetch_cached "$CLAUDE_BASE/$CLAUDE_VERSION/win32-x64/claude.exe" "$win_sha")"

    install -m 755 "$linux_file" "$OUT/aiusb/bin/linux-x64/claude" \
        || die "failed to install claude (linux-x64)"
    install -m 644 "$win_file" "$OUT/aiusb/bin/win-x64/claude.exe" \
        || die "failed to install claude.exe (win-x64)"
}

step_codex() {
    local json="$WORK/codex-release.json"
    local linux_name="codex-x86_64-unknown-linux-musl.tar.gz"
    local win_name="codex-x86_64-pc-windows-msvc.exe.zip"
    local linux_url
    local win_url
    local linux_dig
    local win_dig
    local linux_file
    local win_file
    local xdir="$WORK/codex-linux"
    local wdir="$WORK/codex-win"
    local bin

    info "[3/7] fetching OpenAI Codex CLI"

    curl_api "$GITHUB_API/repos/openai/codex/releases/latest" "$json"
    if ! CODEX_VERSION="$(release_tag "$json")"; then
        die "cannot read the latest Codex release tag"
    fi
    printf '    version %s\n' "$CODEX_VERSION"

    if ! linux_url="$(asset_url "$json" "$linux_name")"; then
        die "Codex release has no asset named $linux_name"
    fi
    if ! win_url="$(asset_url "$json" "$win_name")"; then
        die "Codex release has no asset named $win_name"
    fi
    if ! linux_dig="$(asset_digest "$json" "$linux_name")"; then
        die "cannot read the digest for $linux_name"
    fi
    if ! win_dig="$(asset_digest "$json" "$win_name")"; then
        die "cannot read the digest for $win_name"
    fi

    linux_file="$(fetch_cached "$linux_url" "$linux_dig")"
    win_file="$(fetch_cached "$win_url" "$win_dig")"

    rm -rf -- "$xdir" "$wdir"
    extract_archive "$linux_file" "$xdir"
    extract_archive "$win_file" "$wdir"

    if ! bin="$(locate_file "$xdir" 'codex' 'codex-*')"; then
        die "no Codex binary found inside $linux_name"
    fi
    install -m 755 "$bin" "$OUT/aiusb/bin/linux-x64/codex" \
        || die "failed to install codex (linux-x64)"
    if ! bin="$(locate_file "$wdir" 'codex.exe' 'codex-*.exe')"; then
        die "no Codex executable found inside $win_name"
    fi
    install -m 644 "$bin" "$OUT/aiusb/bin/win-x64/codex.exe" \
        || die "failed to install codex.exe (win-x64)"
}

step_age() {
    local json="$WORK/age-release.json"
    local linux_name
    local win_name
    local linux_nov
    local win_nov
    local linux_url
    local win_url
    local linux_dig
    local win_dig
    local linux_file
    local win_file
    local xdir="$WORK/age-linux"
    local wdir="$WORK/age-win"
    local bin

    info "[4/7] fetching age"

    curl_api "$GITHUB_API/repos/FiloSottile/age/releases/latest" "$json"
    if ! AGE_VERSION="$(release_tag "$json")"; then
        die "cannot read the latest age release tag"
    fi
    printf '    version %s\n' "$AGE_VERSION"

    linux_name="age-$AGE_VERSION-linux-amd64.tar.gz"
    win_name="age-$AGE_VERSION-windows-amd64.zip"
    linux_nov="age-${AGE_VERSION#v}-linux-amd64.tar.gz"
    win_nov="age-${AGE_VERSION#v}-windows-amd64.zip"

    if ! linux_url="$(asset_url "$json" "$linux_name" "$linux_nov")"; then
        die "age release has no linux-amd64 archive"
    fi
    if ! win_url="$(asset_url "$json" "$win_name" "$win_nov")"; then
        die "age release has no windows-amd64 archive"
    fi
    if ! linux_dig="$(asset_digest "$json" "$linux_name" "$linux_nov")"; then
        die "cannot read the digest for the age linux archive"
    fi
    if ! win_dig="$(asset_digest "$json" "$win_name" "$win_nov")"; then
        die "cannot read the digest for the age windows archive"
    fi

    linux_file="$(fetch_cached "$linux_url" "$linux_dig")"
    win_file="$(fetch_cached "$win_url" "$win_dig")"

    rm -rf -- "$xdir" "$wdir"
    extract_archive "$linux_file" "$xdir"
    extract_archive "$win_file" "$wdir"

    if ! bin="$(locate_file "$xdir" 'age')"; then
        die "no age binary inside the linux-amd64 archive"
    fi
    install -m 755 "$bin" "$OUT/aiusb/bin/linux-x64/age" || die "failed to install age"
    if ! bin="$(locate_file "$xdir" 'age-keygen')"; then
        die "no age-keygen binary inside the linux-amd64 archive"
    fi
    install -m 755 "$bin" "$OUT/aiusb/bin/linux-x64/age-keygen" || die "failed to install age-keygen"
    if ! bin="$(locate_file "$wdir" 'age.exe')"; then
        die "no age.exe inside the windows-amd64 archive"
    fi
    install -m 644 "$bin" "$OUT/aiusb/bin/win-x64/age.exe" || die "failed to install age.exe"
    if ! bin="$(locate_file "$wdir" 'age-keygen.exe')"; then
        die "no age-keygen.exe inside the windows-amd64 archive"
    fi
    install -m 644 "$bin" "$OUT/aiusb/bin/win-x64/age-keygen.exe" || die "failed to install age-keygen.exe"
}

# agy_field <manifest.json> <key>
agy_field() {
    python3 -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8"))[sys.argv[2]])' "$1" "$2"
}

# Antigravity CLI (agy), Google's terminal agent that replaced the Gemini CLI: one
# self-contained binary per platform, no Node.js needed.
step_antigravity() {
    local lin_json="$WORK/agy-linux.json"
    local win_json="$WORK/agy-windows.json"
    local lin_ver win_ver lin_url win_url lin_sha win_sha lin_file win_file
    local xdir="$WORK/agy-linux"
    local got

    info "[5/7] fetching Antigravity CLI"

    curl_api "$AGY_MANIFESTS/linux_amd64.json" "$lin_json"
    curl_api "$AGY_MANIFESTS/windows_amd64.json" "$win_json"
    lin_ver="$(agy_field "$lin_json" version)" || die "cannot read the Antigravity linux manifest"
    win_ver="$(agy_field "$win_json" version)" || die "cannot read the Antigravity windows manifest"
    [[ "$lin_ver" == "$win_ver" ]] || die "Antigravity manifests disagree: linux $lin_ver, windows $win_ver"
    [[ "$lin_ver" =~ ^[0-9]+(\.[0-9]+)+$ ]] || die "unexpected Antigravity version string: $lin_ver"
    AGY_VERSION="$lin_ver"
    printf '    version %s\n' "$AGY_VERSION"
    lin_url="$(agy_field "$lin_json" url)"
    win_url="$(agy_field "$win_json" url)"
    lin_sha="$(agy_field "$lin_json" sha512)"
    win_sha="$(agy_field "$win_json" sha512)"
    for got in "$lin_url" "$win_url"; do
        [[ "$got" == "$AGY_URL_PREFIX"* ]] || die "unexpected Antigravity download URL: $got"
    done
    [[ "$lin_sha" =~ ^[0-9a-f]{128}$ && "$win_sha" =~ ^[0-9a-f]{128}$ ]] \
        || die "Antigravity manifests carry no valid sha512"

    lin_file="$(fetch_cached "$lin_url" "$lin_sha" sha512)"
    win_file="$(fetch_cached "$win_url" "$win_sha" sha512)"
    printf '    sha512 verified against the release manifests\n'

    rm -rf -- "$xdir"
    extract_archive "$lin_file" "$xdir"
    [[ -f "$xdir/antigravity" ]] || die "no antigravity binary inside $(basename "$lin_url")"
    install -m 755 "$xdir/antigravity" "$OUT/aiusb/bin/linux-x64/agy" \
        || die "failed to install agy (linux-x64)"
    install -m 644 "$win_file" "$OUT/aiusb/bin/win-x64/agy.exe" \
        || die "failed to install agy.exe (win-x64)"

    got="$(env -i PATH=/usr/bin:/bin HOME="$WORK/agy-home" AGY_CLI_DISABLE_AUTO_UPDATE=true \
        "$OUT/aiusb/bin/linux-x64/agy" --version 2>/dev/null | tr -d '\r' | awk 'NF { print; exit }')"
    [[ "$got" == "$AGY_VERSION" ]] || die "agy --version printed '$got', expected $AGY_VERSION"

    # replaced by agy: the Gemini CLI and the Node.js it needed
    rm -rf -- "$OUT/aiusb/gemini" "$OUT/aiusb/bin/linux-x64/node" "$OUT/aiusb/bin/win-x64/node"
}

# The data partition is exFAT: no symlinks, case-insensitive names, and no
# \ : * ? " < > | in names. Fix or refuse before the user copies the tree.
step_exfat_check() {
    local links collisions badnames link target
    info "checking that the payload fits exFAT"
    links="$(find "$OUT" -type l)"
    if [[ -n "$links" ]]; then
        while IFS= read -r link; do
            target="$(readlink -f -- "$link" || true)"
            if [[ -n "$target" && -f "$target" ]]; then
                cp --remove-destination -- "$target" "$link" || die "cannot dereference $link"
                printf '    replaced symlink with a copy: %s\n' "${link#"$OUT"/}"
            else
                rm -f -- "$link"
                printf '    removed symlink: %s\n' "${link#"$OUT"/}"
            fi
        done <<< "$links"
    fi
    collisions="$(find "$OUT" -mindepth 1 | tr '[:upper:]' '[:lower:]' | sort | uniq -d)"
    if [[ -n "$collisions" ]]; then
        printf '%s\n' "$collisions" >&2
        die "these paths differ only by case and cannot coexist on exFAT"
    fi
    badnames="$(find "$OUT" -mindepth 1 -name '*[\\:*?"<>|]*')"
    if [[ -n "$badnames" ]]; then
        printf '%s\n' "$badnames" >&2
        die "these names contain characters exFAT does not allow"
    fi
}

# Versions of the agents present in build/payload (also the ones --only kept).
installed_version() {
    local bin="$1"
    shift
    [[ -x "$bin" ]] || { printf 'missing'; return 0; }
    env -i PATH=/usr/bin:/bin HOME="$WORK/version-home" AGY_CLI_DISABLE_AUTO_UPDATE=true \
        DISABLE_AUTOUPDATER=1 CLAUDE_CONFIG_DIR="$WORK/version-home/claude" \
        CODEX_HOME="$WORK/version-home/codex" "$bin" "$@" 2>/dev/null \
        | tr -d '\r' | awk 'NF { print; exit }'
}

step_version() {
    local bindir="$OUT/aiusb/bin/linux-x64"
    info "[6/7] writing aiusb/VERSION"
    mkdir -p "$WORK/version-home/claude" "$WORK/version-home/codex"
    [[ -n "$CLAUDE_VERSION" ]] || CLAUDE_VERSION="$(installed_version "$bindir/claude" --version | awk '{ print $1 }')"
    [[ -n "$CODEX_VERSION" ]] || CODEX_VERSION="$(installed_version "$bindir/codex" --version | awk '{ print $NF }')"
    [[ -n "$AGE_VERSION" ]] || AGE_VERSION="$(installed_version "$bindir/age" --version)"
    [[ -n "$AGY_VERSION" ]] || AGY_VERSION="$(installed_version "$bindir/agy" --version)"
    {
        printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'claude-code %s\n' "$CLAUDE_VERSION"
        printf 'codex %s\n' "$CODEX_VERSION"
        printf 'age %s\n' "$AGE_VERSION"
        printf 'antigravity-cli %s\n' "$AGY_VERSION"
    } > "$OUT/aiusb/VERSION" || die "failed to write $OUT/aiusb/VERSION"
}

step_summary() {
    local total
    info "[7/7] done"
    printf '\n'
    printf '%-16s %-28s %10s\n' 'component' 'version' 'size'
    printf '%-16s %-28s %10s\n' 'claude-code' "$CLAUDE_VERSION" "$(total_size \
        "$OUT/aiusb/bin/linux-x64/claude" \
        "$OUT/aiusb/bin/win-x64/claude.exe")"
    printf '%-16s %-28s %10s\n' 'codex' "$CODEX_VERSION" "$(total_size \
        "$OUT/aiusb/bin/linux-x64/codex" \
        "$OUT/aiusb/bin/win-x64/codex.exe")"
    printf '%-16s %-28s %10s\n' 'age' "$AGE_VERSION" "$(total_size \
        "$OUT/aiusb/bin/linux-x64/age" \
        "$OUT/aiusb/bin/linux-x64/age-keygen" \
        "$OUT/aiusb/bin/win-x64/age.exe" \
        "$OUT/aiusb/bin/win-x64/age-keygen.exe")"
    printf '%-16s %-28s %10s\n' 'antigravity-cli' "$AGY_VERSION" "$(total_size \
        "$OUT/aiusb/bin/linux-x64/agy" \
        "$OUT/aiusb/bin/win-x64/agy.exe")"
    printf '\n'
    total="$(du -sh "$OUT" | cut -f1)"
    printf 'total payload size: %s (%s)\n' "$total" "$OUT"
}

# ---------------------------------------------------------------------------
# Argument parsing and main
# ---------------------------------------------------------------------------

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --claude-channel)
                if [[ $# -lt 2 ]]; then
                    die "--claude-channel needs a value: stable or latest"
                fi
                CLAUDE_CHANNEL="$2"
                shift 2
                ;;
            --claude-channel=*)
                CLAUDE_CHANNEL="${1#*=}"
                shift
                ;;
            --clean)
                DO_CLEAN=1
                shift
                ;;
            --only)
                [[ $# -ge 2 ]] || die "--only needs a value, e.g. antigravity or claude,codex"
                ONLY="$2"
                shift 2
                ;;
            --only=*)
                ONLY="${1#*=}"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                printf 'error: unknown argument: %s\n' "$1" >&2
                usage >&2
                exit 1
                ;;
        esac
    done
    case "$CLAUDE_CHANNEL" in
        stable|latest)
            ;;
        *)
            die "--claude-channel must be 'stable' or 'latest'"
            ;;
    esac
    local step
    for step in ${ONLY//,/ }; do
        case "$step" in
            claude|codex|age|antigravity) ;;
            *) die "--only knows claude, codex, age and antigravity, not '$step'" ;;
        esac
    done
    if [[ -n "$ONLY" && "$DO_CLEAN" -eq 1 ]]; then
        die "--only and --clean together would leave the other agents out"
    fi
}

# wanted <step>: run this step? (all of them unless --only names a list)
wanted() {
    [[ -z "$ONLY" || ",$ONLY," == *",$1,"* ]]
}

main() {
    parse_args "$@"

    require_cmd curl
    require_cmd python3
    require_cmd tar
    require_cmd sha256sum
    require_cmd sha512sum
    require_cmd install
    require_cmd du

    if [[ "$EUID" -eq 0 ]]; then
        printf 'warning: this script does not need root; files in build/ will be root-owned\n' >&2
    fi

    if [[ "$DO_CLEAN" -eq 1 ]]; then
        case "$OUT" in
            */build/payload)
                info "cleaning $OUT"
                rm -rf -- "$OUT"
                ;;
            *)
                die "refusing to clean unexpected path: $OUT"
                ;;
        esac
    fi

    mkdir -p "$CACHE"
    trap cleanup EXIT
    WORK="$(mktemp -d)"
    register_cleanup "$WORK"

    printf 'building payload in %s (cache: %s)\n' "$OUT" "$CACHE"

    step_payload
    if wanted claude; then step_claude; fi
    if wanted codex; then step_codex; fi
    if wanted age; then step_age; fi
    if wanted antigravity; then step_antigravity; fi
    step_exfat_check
    step_version
    step_summary
}

main "$@"