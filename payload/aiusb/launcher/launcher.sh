#!/usr/bin/env bash
# AI-USB launcher - Linux host mode and rescue mode.
# Contract: docs/ARCHITECTURE.md section 5. Usage: bash launcher.sh [--mode linux|rescue]

set -uo pipefail
set -m            # job control: each foreground agent gets its own process group
umask 077

# ------------------------------------------------------------------ globals
MODE="linux"
SELF=""
USB=""
V=""
CONF_FILE=""
BIN_DIR=""
S=""
H=""
T=""
CLAUDE_BIN=""
CODEX_BIN=""
AGE_BIN=""
AGEKEYGEN_BIN=""
AGY_BIN=""        # Antigravity CLI; empty when it cannot run (option 4 then explains)
WATCHER_PID=""
AUTONOMOUS=0
GLM_BASE_URL=""
GLM_OPUS_MODEL=""
GLM_SONNET_MODEL=""
GLM_HAIKU_MODEL=""
AIUSB_CLEANED=0
SESSION_READY=0   # 1 once the vault is unlocked/created: only then may cleanup save
STALE_PENDING=0   # 1 while an old session in RAM still waits to be saved: never wipe it then
BIN_CACHE=""      # RAM copy of the binaries when the stick cannot execute them (5.8)
STICK_NOEXEC=""   # yes/no once known: is the stick mounted noexec?
LOCK_OWNED=0      # 1 once this launcher wrote session.lock
RED="" GREEN="" YELLOW="" CYAN="" RESET=""
declare -A TXT=() # language texts: KEY -> text; en.txt loads first, the choice overlays it
LANG_CODE="en"    # the chosen language code (aiusb/lang/<code>.txt)
LANG_DIR=""       # aiusb/lang on the stick
LANG_FROM_ENV=0   # 1 when AIUSB_LANG held a valid code: the start-up question is skipped
IDENTITY=""       # the vault's private key, in this process's memory only (5.5)
declare -A HIST_DIRTY=()  # history groups whose agent ran since their last save

# Caches, logs and files the agents download again at every start never go into the vault:
# it stays small, so unlock and save are quick. Same list as launcher.ps1.
readonly -a VAULT_EXCLUDES=(
  claude/cache
  claude/debug
  claude/shell-snapshots
  claude/statsig
  claude/todos
  claude/file-history
  claude/paste-cache
  claude/image-cache
  claude/backups
  claude/telemetry
  claude/logs
  claude/plugins
  claude/skills/synced
  claude/sessions
  claude/session-env
  claude/ide
  claude/downloads
  claude-glm/cache
  claude-glm/debug
  claude-glm/shell-snapshots
  claude-glm/statsig
  claude-glm/todos
  claude-glm/file-history
  claude-glm/paste-cache
  claude-glm/image-cache
  claude-glm/backups
  claude-glm/telemetry
  claude-glm/logs
  claude-glm/plugins
  claude-glm/skills/synced
  claude-glm/sessions
  claude-glm/session-env
  claude-glm/ide
  claude-glm/downloads
  codex/tmp
  codex/.tmp
  codex/log
  codex/cache
  codex/plugins
  codex/packages
  codex/shell_snapshots
  codex/skills/.system
  'codex/sqlite/logs_*'
  'codex/logs_*'
  'codex/state_*'
  'codex/goals_*'
  'codex/queue_*'
  'codex/memories_*'
  'codex/thread_history_*'
  agy/.gemini/antigravity-cli/log
  agy/.gemini/antigravity-cli/crashes
  agy/.gemini/antigravity-cli/bin
  agy/.gemini/antigravity-cli/builtin
  agy/.gemini/antigravity-cli/updater
  agy/.gemini/antigravity-cli/cli.log
  agy/.gemini/antigravity-cli/last_check.timestamp
  agy/.cache
)

# Conversation history (ARCHITECTURE 5.5.1): one archive per group,
# vault/history/<group>.tgz.age, opened only when an agent of that group starts, so unlocking
# stays fast however many conversations are saved. Same groups and paths as launcher.ps1.
readonly -a HIST_GROUPS=(claude codex agy)
declare -rA HIST_PATHS=(
  [claude]="claude/projects claude-glm/projects"
  [codex]="codex/sessions codex/archived_sessions codex/session_index.jsonl codex/sqlite"
  [agy]="agy/.gemini/antigravity-cli/conversations agy/.gemini/antigravity-cli/brain agy/.gemini/antigravity-cli/conversation_summaries.db agy/.gemini/antigravity-cli/conversation_summaries.db-wal agy/.gemini/antigravity-cli/conversation_summaries.db-shm"
)
# Claude Code files its conversations under this one folder name on every PC and OS
# (CLAUDE_CODE_PROJECT_DIR_NAME), instead of one folder per workspace path.
readonly CLAUDE_PROJECT_DIR_NAME="aiusb-workspace"
# Antigravity CLI (5.10): it keeps its Google login in the PC's keyring unless it believes it
# runs over SSH; then it uses a file in its home, which is the agent home here (H/agy).
readonly AGY_SSH_MARK="127.0.0.1 0 127.0.0.1 0"

# ------------------------------------------------------------------ output helpers
setup_colors() {
  if [[ -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
    RED=$'\033[31m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    CYAN=$'\033[36m'
    RESET=$'\033[0m'
  fi
}

info() { printf '%s%s%s %s\n' "$GREEN" 'info' "$RESET" "$*"; }
warn() { printf '%s%s%s %s\n' "$YELLOW" 'warn' "$RESET" "$*" >&2; }
die()  { printf '%s%s%s %s\n' "$RED" 'error' "$RESET" "$*" >&2; exit 1; }

host_name() { uname -n 2>/dev/null || printf '%s' unknown; }

# The PC user's home (under sudo: the invoking user's, not root's).
real_home() {
  local h=""
  if [[ -n "${SUDO_USER:-}" ]]; then
    h="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
  fi
  printf '%s' "${h:-${HOME:-unknown}}"
}

usage() {
  printf '%s\n' "$(t SH_USAGE)"
}

# The stick's logo (aiusb/launcher/banner.txt); plain title if it is missing.
show_banner() {
  local file="$USB/aiusb/launcher/banner.txt"
  printf '\n'
  if [[ -r "$file" ]]; then
    printf '%s' "$CYAN"
    cat -- "$file"
    printf '%s' "$RESET"
  else
    printf '%s\n' "$(t SH_BANNER_FALLBACK)"
  fi
}

# ------------------------------------------------------------------ language files (i18n)
# One KEY=text per line; the first '=' splits; '#' lines and empty lines are ignored.
# '\n' inside a text means a line break; {0}, {1}, ... are placeholders. English is the
# master file; the selected language overlays it; a key missing everywhere prints as
# the key itself. lang/current holds the last choice; write errors are ignored.
lang_read_file() {
  local file="$1" line key text
  [[ -r "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    text="${line#*=}"
    [[ "$key" =~ ^[A-Z0-9_]+$ ]] || continue
    TXT["$key"]="$text"
  done < "$file"
  return 0
}

lang_load() {
  local code="$1"
  TXT=()
  lang_read_file "$LANG_DIR/en.txt"
  if [[ "$code" != "en" ]]; then
    lang_read_file "$LANG_DIR/$code.txt"
  fi
  return 0
}

# A code is valid when lang/<code>.txt exists and names the language.
lang_code_ok() {
  local code="${1:-}"
  code="${code,,}"
  [[ "$code" =~ ^[a-z0-9_-]+$ ]] || return 1
  [[ -r "$LANG_DIR/$code.txt" ]] || return 1
  grep -q '^COMMON_LANG_NAME=' "$LANG_DIR/$code.txt" 2>/dev/null || return 1
  return 0
}

lang_read_current() {
  local code=""
  if [[ -r "$LANG_DIR/current" ]]; then
    IFS= read -r code < "$LANG_DIR/current" || code=""
  fi
  code="${code%$'\r'}"
  code="${code//[[:space:]]/}"
  code="${code,,}"
  if [[ -n "$code" ]] && lang_code_ok "$code"; then
    printf '%s' "$code"
  else
    printf 'en'
  fi
}

lang_save_current() {
  mkdir -p -- "$LANG_DIR" 2>/dev/null || return 0
  printf '%s\n' "$LANG_CODE" > "$LANG_DIR/current" 2>/dev/null || return 0
  return 0
}

# Ask for the language; the prompt itself is a fixed ASCII string so it renders on
# every console; only the current language's name comes from the language files.
lang_ask() {
  local answer="" want=""
  printf 'Language / Jazyk:  1) English   2) Slovencina   [Enter = %s]: ' "$(t COMMON_LANG_NAME)"
  read -r answer || return 0
  answer="${answer%$'\r'}"
  answer="${answer//[[:space:]]/}"
  case "${answer,,}" in
    1|en) want="en" ;;
    2|sk) want="sk" ;;
    '')   lang_save_current ;;
    *)    return 0 ;;
  esac
  if [[ -n "$want" ]] && lang_code_ok "$want"; then
    LANG_CODE="$want"
    lang_load "$LANG_CODE"
    lang_save_current
  fi
  return 0
}

# Load the texts before anything may print them. AIUSB_LANG wins when it holds a
# valid code (sudo re-exec, rescue chain, tests): then the question is skipped.
# The stick root is derived the same way locate_stick derives it, only without dying.
lang_boot() {
  local root=""
  root="$(readlink -f "$0" 2>/dev/null)" || root="$0"
  root="$(cd "$(dirname -- "$root")/../.." 2>/dev/null && pwd)" || root=""
  LANG_DIR="${root}/aiusb/lang"
  if [[ -n "${AIUSB_LANG:-}" ]] && lang_code_ok "${AIUSB_LANG}"; then
    LANG_CODE="${AIUSB_LANG,,}"
    LANG_FROM_ENV=1
  else
    LANG_CODE="$(lang_read_current)"
  fi
  lang_load "$LANG_CODE"
  return 0
}

# t KEY [args...]: print the text of KEY with {i} replaced by the i-th argument and
# '\n' turned into line breaks, without a trailing newline. A key missing everywhere
# prints as the key itself. Quoted replacements keep '&' and '\' in arguments literal.
t() {
  local key="$1"
  local s="${TXT[$key]-$key}"
  local i=0 a
  shift
  s="${s//\\n/$'\n'}"
  for a in "$@"; do
    s="${s//"{$i}"/"$a"}"
    i=$((i + 1))
  done
  printf '%s' "$s"
}

# ------------------------------------------------------------------ logging and config
log_event() {
  local text="$1"
  mkdir -p -- "$USB/aiusb/logs" 2>/dev/null || return 0
  printf '%s %s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MODE" \
    "$(host_name)" "$text" \
    >> "$USB/aiusb/logs/launcher.log" 2>/dev/null || return 0
  return 0
}

# Parse aiusb.conf as plain text. First '=' splits; spaces trimmed; '#' lines skipped.
conf_get() {
  local key="$1" default="${2:-}" line k v
  if [[ ! -f "$CONF_FILE" ]]; then
    printf '%s' "$default"
    return 0
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == \#* ]] && continue
    [[ "$line" == *=* ]] || continue
    k="${line%%=*}"
    v="${line#*=}"
    k="${k//[[:space:]]/}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    if [[ "$k" == "$key" ]]; then
      printf '%s' "$v"
      return 0
    fi
  done < "$CONF_FILE"
  printf '%s' "$default"
}

# ------------------------------------------------------------------ startup checks
# Runs before anything touches the TXT associative array (bash 3 has none), so this
# one message cannot come from the language files.
require_bash4() {
  if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    printf '%s%s%s %s\n' "$RED" 'error' "$RESET" 'bash 4 or newer is required.' >&2
    exit 1
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        [[ $# -ge 2 ]] || die "$(t SH_ERR_MODE_VALUE)"
        MODE="$2"
        shift 2
        ;;
      --mode=*)
        MODE="${1#--mode=}"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "$(t SH_ERR_UNKNOWN_OPT "$1")"
        ;;
    esac
  done
  [[ "$MODE" == "linux" || "$MODE" == "rescue" ]] || die "$(t SH_ERR_MODE_INVALID)"
}

check_environment() {
  if [[ "$(uname -m)" != "x86_64" ]]; then
    die "$(t SH_ERR_ARCH "$(uname -m)")"
  fi
}

locate_stick() {
  SELF="$(readlink -f "$0")"
  USB="$(cd "$(dirname "$SELF")/../.." && pwd)" || die "$(t SH_ERR_FIND_ROOT)"
  V="$USB/aiusb/vault"
  CONF_FILE="$USB/aiusb/aiusb.conf"
  BIN_DIR="$USB/aiusb/bin/linux-x64"
  LANG_DIR="$USB/aiusb/lang"
  [[ -f "$CONF_FILE" ]] || die "$(t SH_ERR_NOT_STICK "$CONF_FILE")"
  mkdir -p -- "$V" 2>/dev/null || die "$(t SH_ERR_VAULT_DIR)"
}

read_conf() {
  GLM_BASE_URL="$(conf_get GLM_BASE_URL https://api.z.ai/api/anthropic)"
  GLM_OPUS_MODEL="$(conf_get GLM_OPUS_MODEL '')"
  GLM_SONNET_MODEL="$(conf_get GLM_SONNET_MODEL '')"
  GLM_HAIKU_MODEL="$(conf_get GLM_HAIKU_MODEL '')"
  AUTONOMOUS=0
  if [[ "$(conf_get AUTONOMOUS_DEFAULT 0)" == "1" ]]; then
    AUTONOMOUS=1
  fi
}

# ------------------------------------------------------------------ elevation (5.2, linux mode only)
maybe_elevate() {
  local answer
  [[ "$MODE" == "linux" ]] || return 0
  [[ "$EUID" -eq 0 ]] && return 0
  [[ "${AIUSB_ELEVATED:-0}" == "1" ]] && return 0
  read -r -p "$(t SH_ASK_ROOT) " answer
  if [[ -n "$answer" && "$answer" != y && "$answer" != Y ]]; then
    warn "$(t SH_WARN_NO_ROOT)"
    return 0
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    warn "$(t SH_WARN_NO_SUDO)"
    return 0
  fi
  if ! sudo -v; then
    warn "$(t SH_WARN_SUDO_FAIL)"
    return 0
  fi
  exec sudo env AIUSB_ELEVATED=1 AIUSB_LANG="$LANG_CODE" bash "$SELF" --mode linux
}

# ------------------------------------------------------------------ session paths (5.3)
setup_session_paths() {
  local parent fstype xdg_fs="unknown"
  if [[ "$MODE" == "rescue" || "$EUID" -eq 0 ]]; then
    S="/run/aiusb-session"
  else
    if [[ -n "${XDG_RUNTIME_DIR:-}" && -d "$XDG_RUNTIME_DIR" ]]; then
      xdg_fs="$(stat -f -c %T "$XDG_RUNTIME_DIR" 2>/dev/null || printf '%s' unknown)"
    fi
    if [[ "$xdg_fs" == "tmpfs" || "$xdg_fs" == "ramfs" ]]; then
      S="${XDG_RUNTIME_DIR}/aiusb-session"
    else
      S="/dev/shm/aiusb-session-$UID"
    fi
  fi
  if [[ -f "$S/home/.aiusb-vault-id" ]]; then
    STALE_PENDING=1
  fi
  parent="$(dirname -- "$S")"
  fstype="$(stat -f -c %T "$parent" 2>/dev/null || printf '%s' unknown)"
  if [[ "$fstype" != "tmpfs" && "$fstype" != "ramfs" ]]; then
    die "$(t SH_ERR_NOT_RAMFS "$parent" "$fstype")"
  fi
  if ! (umask 077 && mkdir -p -- "$S"); then
    die "$(t SH_ERR_SESSION_DIR "$S")"
  fi
  chmod 700 "$S"
  H="$S/home"
  T="$S/tmp"
  mkdir -p -- "$H" "$T" "$S/bin" || die "$(t SH_ERR_SESSION_DIRS "$S")"
  chmod 700 "$H" "$T" "$S/bin"
  # Binaries are not secret but large: /run and $XDG_RUNTIME_DIR are small tmpfs,
  # /dev/shm usually has room. Used only when the stick's mount is noexec.
  if [[ "$(stat -f -c %T /dev/shm 2>/dev/null)" == "tmpfs" ]]; then
    BIN_CACHE="/dev/shm/aiusb-bin-$UID"
  else
    BIN_CACHE="$S/bin-cache"
  fi
}

# ------------------------------------------------------------------ binaries (5.8)
# Print a runnable path for $1: use it in place, or copy it into RAM and use that.
# Run "<bin> --version" with the agents' config dirs pointed into the RAM session,
# so the probe never creates ~/.claude or ~/.codex on the host.
probe_version() {
  mkdir -p -- "$T/probe/claude" "$T/probe/codex" 2>/dev/null
  CLAUDE_CONFIG_DIR="$T/probe/claude" CODEX_HOME="$T/probe/codex" TMPDIR="$T" \
    DISABLE_AUTOUPDATER=1 "$1" --version >/dev/null 2>&1
}

# Copy $1 to $2 in RAM if there is room; on failure remove the partial copy.
ram_copy() {
  local src="$1" dst="$2" need avail
  need="$(stat -c %s -- "$src" 2>/dev/null || printf 0)"
  avail="$(df -B1 --output=avail -- "$(dirname -- "$dst")" 2>/dev/null | tail -n 1 | tr -d ' ')"
  if [[ "$avail" =~ ^[0-9]+$ ]] && (( avail < need + 64 * 1024 * 1024 )); then
    warn "$(t SH_WARN_RAM_COPY "$(basename -- "$src")")"
    return 1
  fi
  if ! cp -- "$src" "$dst.part" 2>/dev/null; then
    rm -f -- "$dst.part"
    return 1
  fi
  chmod 755 "$dst.part" && mv -f -- "$dst.part" "$dst"
}

# Can programs run straight from the stick? Decided from the mount options, so the big
# agent binaries (~500 MB) are not read over USB just to test them.
stick_noexec() {
  local opts
  if [[ -z "$STICK_NOEXEC" ]]; then
    opts="$(findmnt -no OPTIONS --target "$BIN_DIR" 2>/dev/null | head -n 1)"
    if [[ -z "$opts" ]]; then
      STICK_NOEXEC="unknown"
    elif [[ ",$opts," == *,noexec,* ]]; then
      STICK_NOEXEC="yes"
    else
      STICK_NOEXEC="no"
    fi
  fi
  [[ "$STICK_NOEXEC" == "yes" ]]
}

# $1 = binary, $2 = "probe" to really run it (only for the small age tools)
runnable_copy() {
  local src="$1" mode="${2:-}" dst
  if [[ -f "$src" && -x "$src" ]] && ! stick_noexec; then
    if [[ "$mode" != "probe" && "$STICK_NOEXEC" == "no" ]] || probe_version "$src"; then
      printf '%s\n' "$src"
      return 0
    fi
  fi
  (umask 077 && mkdir -p -- "$BIN_CACHE") || return 1
  dst="$BIN_CACHE/$(basename -- "$src")"
  if [[ ! -f "$dst" ]] || ! probe_version "$dst"; then
    rm -f -- "$dst"
    ram_copy "$src" "$dst" || return 1
  fi
  if probe_version "$dst"; then
    printf '%s\n' "$dst"
    return 0
  fi
  return 1
}

noexec_hint() {
  warn "$(t SH_WARN_NOEXEC_1)"
  warn "$(t SH_WARN_NOEXEC_2)"
}

prepare_bins() {
  # age first: without it the vault cannot be opened at all.
  AGE_BIN="$(runnable_copy "$BIN_DIR/age" probe)" \
    || { noexec_hint; die "$(t SH_ERR_AGE_BIN "$BIN_DIR/age")"; }
  AGEKEYGEN_BIN="$(runnable_copy "$BIN_DIR/age-keygen" probe)" \
    || { noexec_hint; die "$(t SH_ERR_AGEKEYGEN_BIN "$BIN_DIR/age-keygen")"; }
  CLAUDE_BIN="$(runnable_copy "$BIN_DIR/claude")" \
    || { noexec_hint; die "$(t SH_ERR_CLAUDE_BIN "$BIN_DIR/claude")"; }
  CODEX_BIN="$(runnable_copy "$BIN_DIR/codex")" \
    || { noexec_hint; die "$(t SH_ERR_CODEX_BIN "$BIN_DIR/codex")"; }
  # Antigravity is optional: without it only option 4 is unavailable.
  AGY_BIN=""
  if [[ -f "$BIN_DIR/agy" ]]; then
    AGY_BIN="$(runnable_copy "$BIN_DIR/agy")" || AGY_BIN=""
  fi
  [[ -n "$AGY_BIN" ]] || warn "$(t SH_WARN_AGY_MISSING)"
}

# ------------------------------------------------------------------ agent home skeleton (5.4)
# Replace a 'key = ...' line in $1 with $3 (key given in $2), or append it.
set_config_line() {
  local file="$1" key="$2" newline="$3" tmp
  tmp="$file.tmp"
  if [[ -f "$file" ]] && grep -q "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null; then
    sed "s|^[[:space:]]*${key}[[:space:]]*=.*|${newline}|" "$file" > "$tmp" 2>/dev/null \
      && mv -f -- "$tmp" "$file"
  else
    # TOML: a top-level key must come before any [table], so put it first.
    { printf '%s\n' "$newline"; cat -- "$file" 2>/dev/null; } > "$tmp" && mv -f -- "$tmp" "$file"
  fi
}

ensure_home_skeleton() {
  mkdir -p -- "$H/claude" "$H/claude-glm" "$H/anthropic" "$H/codex" "$H/agy" "$H/secrets" \
    || die "$(t SH_ERR_HOME_DIRS)"
  chmod 700 "$H/claude" "$H/claude-glm" "$H/anthropic" "$H/codex" "$H/agy" "$H/secrets"
  # The Gemini CLI was replaced by Antigravity: drop what it left in the vault.
  rm -rf -- "$H/gemini"
  rm -f -- "$V/history/gemini.tgz.age" "$V/history/gemini.tgz.age.bak"
  touch "$H/codex/config.toml" || die "$(t SH_ERR_WRITE_CONFIG "$H/codex/config.toml")"
  set_config_line "$H/codex/config.toml" 'cli_auth_credentials_store' 'cli_auth_credentials_store = "file"'
  set_config_line "$H/codex/config.toml" 'mcp_oauth_credentials_store' 'mcp_oauth_credentials_store = "file"'
  if [[ -f "$V/vault.id" && ! -f "$H/.aiusb-vault-id" ]]; then
    cp -- "$V/vault.id" "$H/.aiusb-vault-id"
  fi
}

# ------------------------------------------------------------------ vault operations (5.5)
# The private key never touches a disk: age-keygen prints it, age reads it from a pipe
# (printf is a builtin, so the key is not visible in the process list either).
vault_create() {
  printf '\n%s\n\n' "$(t COMMON_FIRST_RUN)"
  info "$(t SH_INFO_VAULT_NEW)"
  info "$(t SH_INFO_PASS_PROTECT)"
  info "$(t SH_INFO_PASS_NORECOVER)"
  info "$(t SH_INFO_PASS_CHARSET)"
  IDENTITY="$("$AGEKEYGEN_BIN" 2>/dev/null)" || IDENTITY=""
  if [[ "$IDENTITY" != *AGE-SECRET-KEY-* ]]; then
    IDENTITY=""
    die "$(t SH_ERR_VAULT_KEY)"
  fi
  if ! printf '%s\n' "$IDENTITY" | "$AGEKEYGEN_BIN" -y > "$V/recipient.txt.new" 2>/dev/null; then
    rm -f -- "$V/recipient.txt.new"
    die "$(t SH_ERR_VAULT_PUBKEY)"
  fi
  info "$(t SH_INFO_PASS_TWICE)"
  info "$(t SH_INFO_PASS_NOT_EMPTY)"
  if ! printf '%s\n' "$IDENTITY" | "$AGE_BIN" -p -o "$V/identity.age.new"; then
    rm -f -- "$V/identity.age.new" "$V/recipient.txt.new"
    die "$(t SH_ERR_VAULT_CANCELLED)"
  fi
  mv -f -- "$V/recipient.txt.new" "$V/recipient.txt"
  mv -f -- "$V/identity.age.new" "$V/identity.age"
  od -An -N16 -tx1 /dev/urandom | tr -d ' \n' > "$V/vault.id"
  ensure_home_skeleton
  vault_save
  SESSION_READY=1
  log_event "vault-created"
  info "$(t SH_INFO_VAULT_CREATED)"
}

ms_now() { date +%s%3N; }

# Ask for the passphrase (age prompts on the terminal itself) and keep the decrypted
# private key in memory, so the history archives open later without asking again.
identity_unlock() {
  local attempt out=""
  for attempt in 1 2 3; do
    if out="$("$AGE_BIN" -d "$V/identity.age")" && [[ "$out" == *AGE-SECRET-KEY-* ]]; then
      IDENTITY="$out"
      return 0
    fi
    warn "$(t SH_WARN_WRONG_PASS "$attempt")"
  done
  return 1
}

vault_unlock() {
  local archive="$V/home.tar.age" answer t0
  if [[ ! -f "$archive" ]]; then
    if [[ -f "$V/home.tar.age.bak" ]]; then
      read -r -p "$(t SH_ASK_RESTORE_BACKUP) " answer
      if [[ -z "$answer" || "$answer" == y || "$answer" == Y ]]; then
        archive="$V/home.tar.age.bak"
      fi
    fi
    if [[ ! -f "$archive" ]]; then
      info "$(t SH_INFO_NO_HOME)"
      SESSION_READY=1
      return 0
    fi
  fi
  if ! identity_unlock; then
    log_event "unlock-fail"
    die "$(t SH_ERR_UNLOCK_FAIL)"
  fi
  # The passphrase was right: a failure from here on is an unpacking problem.
  t0="$(ms_now)"
  if ! printf '%s\n' "$IDENTITY" | "$AGE_BIN" -d -i - "$archive" | tar -xf - -C "$H"; then
    log_event "unpack-fail"
    die "$(t SH_ERR_UNPACK)"
  fi
  SESSION_READY=1
  log_event "unlock-ok $(( $(ms_now) - t0 ))ms"
  return 0
}

# vault_save [GROUP...] | --recover: save the logins and settings (always), then the given
# history groups; --recover = every group (a session left over by a crash, an unplug or
# another OS). Returns 1 when any part failed, so a leftover session is kept for next time.
vault_save() {
  local tmp="$V/home.tar.age.new" g rc=0
  local -a groups=()
  if [[ "${1:-}" == "--recover" ]]; then
    groups=("${HIST_GROUPS[@]}")
  else
    groups=("$@")
  fi
  [[ -d "$H" && -d "$V" ]] || return 0
  if [[ ! -r "$V/recipient.txt" ]]; then
    warn "$(t SH_WARN_SAVE_NO_PUBKEY)"
    return 1
  fi
  local -a excl=() names=()
  local e p
  for e in "${VAULT_EXCLUDES[@]}"; do excl+=(--exclude "$e"); done
  # history and the session's markers have their own archives
  for g in "${HIST_GROUPS[@]}"; do
    for p in ${HIST_PATHS[$g]}; do excl+=(--exclude "$p"); done
  done
  excl+=(--exclude '.aiusb-loaded-*')
  while IFS= read -r -d '' p; do excl+=(--exclude "$p"); done < <(find "$H" -type l -printf '%P\0' 2>/dev/null)
  # Archive the top-level names, not ".": a "./" member makes Windows' tar.exe create an
  # undeletable entry literally named "." on the exFAT stick.
  mapfile -d '' -t names < <(find "$H" -mindepth 1 -maxdepth 1 -printf '%P\0')
  if [[ "${#names[@]}" -eq 0 ]]; then
    warn "$(t SH_WARN_SAVE_EMPTY)"
    return 1
  fi
  if ! tar -cf - "${excl[@]}" -C "$H" -- "${names[@]}" | "$AGE_BIN" -R "$V/recipient.txt" -o "$tmp"; then
    rm -f -- "$tmp"
    warn "$(t SH_WARN_SAVE_FAILED)"
    log_event "save-fail"
    return 1
  fi
  if [[ ! -s "$tmp" ]]; then
    rm -f -- "$tmp"
    warn "$(t SH_WARN_SAVE_EMPTY_FILE)"
    log_event "save-fail"
    return 1
  fi
  if [[ -f "$V/home.tar.age" ]]; then
    mv -f -- "$V/home.tar.age" "$V/home.tar.age.bak"
  fi
  mv -f -- "$tmp" "$V/home.tar.age"
  log_event "save-ok"
  if [[ "${#groups[@]}" -gt 0 ]]; then
    for g in "${groups[@]}"; do
      hist_should_save "$g" || continue
      if hist_save "$g"; then
        unset 'HIST_DIRTY[$g]'
      else
        rc=1
      fi
    done
  fi
  sync
  return "$rc"
}

# ------------------------------------------------------------------ conversation history (5.5.1)
hist_label() {
  case "$1" in
    claude) printf 'Claude' ;;
    codex)  printf 'Codex' ;;
    agy)    printf 'Antigravity' ;;
    *)      printf '%s' "$1" ;;
  esac
}

hist_has_data() {
  local p
  for p in ${HIST_PATHS[$1]}; do
    [[ -e "$H/$p" ]] && return 0
  done
  return 1
}

# Write group $1 now? Only when its archive was opened this session (marker), or when the
# vault has none yet and the session holds data (first save, or a session left by an older
# launcher). An archive that could not be opened is never overwritten.
hist_should_save() {
  [[ -f "$H/.aiusb-loaded-$1" ]] && return 0
  [[ ! -f "$V/history/$1.tgz.age" ]] && hist_has_data "$1"
}

# Open group $1's archive into $H, once per session; the marker allows saving it later.
hist_load() {
  local g="$1" archive="$V/history/$1.tgz.age" t0
  [[ -f "$H/.aiusb-loaded-$g" ]] && return 0
  if [[ ! -f "$archive" && -f "$archive.bak" ]]; then
    archive="$archive.bak"
  fi
  if [[ -f "$archive" ]]; then
    if [[ -z "$IDENTITY" ]] && ! identity_unlock; then
      warn "$(t COMMON_HIST_LOAD_FAIL "$(hist_label "$g")")"
      return 1
    fi
    info "$(t COMMON_HIST_LOADING "$(hist_label "$g")")"
    t0="$(ms_now)"
    if ! printf '%s\n' "$IDENTITY" | "$AGE_BIN" -d -i - "$archive" | tar -xzf - -C "$H"; then
      warn "$(t COMMON_HIST_LOAD_FAIL "$(hist_label "$g")")"
      log_event "history-load-fail $g"
      return 1
    fi
    log_event "history-load $g $(( $(ms_now) - t0 ))ms"
  fi
  : > "$H/.aiusb-loaded-$g"
  return 0
}

# Save group $1: gzip tar of its paths, encrypted to the vault's public key.
hist_save() {
  local g="$1" final="$V/history/$1.tgz.age" tmp t0 p e
  local -a members=() excl=()
  tmp="$final.new"
  for p in ${HIST_PATHS[$g]}; do
    [[ -e "$H/$p" ]] && members+=("$p")
  done
  if [[ "${#members[@]}" -eq 0 ]]; then
    # the group's folders were deleted on purpose: so are its archives (a .bak would be
    # opened again next time)
    rm -f -- "$final" "$final.bak"
    return 0
  fi
  mkdir -p -- "$V/history" || return 1
  for e in "${VAULT_EXCLUDES[@]}"; do excl+=(--exclude "$e"); done
  # symlinks never go into an archive: exFAT and Windows' tar.exe cannot recreate them
  while IFS= read -r -d '' p; do excl+=(--exclude "$p"); done < <(find "$H" -type l -printf '%P\0' 2>/dev/null)
  t0="$(ms_now)"
  if ! tar -czf - "${excl[@]}" -C "$H" -- "${members[@]}" \
       | "$AGE_BIN" -R "$V/recipient.txt" -o "$tmp" || [[ ! -s "$tmp" ]]; then
    rm -f -- "$tmp"
    warn "$(t COMMON_HIST_SAVE_FAIL "$(hist_label "$g")")"
    log_event "history-save-fail $g"
    return 1
  fi
  if [[ -f "$final" ]]; then
    mv -f -- "$final" "$final.bak"
  fi
  mv -f -- "$tmp" "$final"
  log_event "history-save $g $(( $(ms_now) - t0 ))ms"
  return 0
}

# The groups an agent uses; the shell can start any agent.
agent_groups() {
  case "$1" in
    claude|glm) printf '%s\n' claude ;;
    codex)      printf '%s\n' codex ;;
    agy)        printf '%s\n' agy ;;
    shell)      printf '%s\n' "${HIST_GROUPS[@]}" ;;
  esac
}

# merge_tree SRC DST: move SRC's entries into DST; on a clash the newer file wins.
merge_tree() {
  local src="$1" dst="$2" entry name
  mkdir -p -- "$dst" || return 1
  for entry in "$src"/* "$src"/.[!.]* "$src"/..?*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    name="${entry##*/}"
    if [[ ! -e "$dst/$name" && ! -L "$dst/$name" ]]; then
      mv -- "$entry" "$dst/$name"
    elif [[ -d "$entry" && ! -L "$entry" && -d "$dst/$name" && ! -L "$dst/$name" ]]; then
      merge_tree "$entry" "$dst/$name"
    elif [[ -f "$entry" && -f "$dst/$name" && "$entry" -nt "$dst/$name" ]]; then
      mv -f -- "$entry" "$dst/$name"
    else
      rm -rf -- "$entry"
    fi
  done
  rmdir -- "$src" 2>/dev/null || true
}

# Conversations from before CLAUDE_CODE_PROJECT_DIR_NAME sit in folders named after the
# workspace path of that PC (E--aiusb-workspace, -run-media-...-aiusb-workspace): move them
# into the one folder Claude Code now uses everywhere.
claude_merge_projects() {
  local cfg dir
  for cfg in claude claude-glm; do
    for dir in "$H/$cfg/projects"/*-aiusb-workspace; do
      [[ -d "$dir" && ! -L "$dir" ]] || continue
      merge_tree "$dir" "$H/$cfg/projects/$CLAUDE_PROJECT_DIR_NAME"
    done
  done
}

# Environment of the Antigravity CLI, as export lines (eval'd by run_agent, written into the
# agy wrapper): its home is the agent home H/agy (config, login file, conversations), the
# SSH marker keeps the login out of the PC's keyring, and it must not update itself.
agy_env_lines() {
  printf 'export HOME=%q XDG_CONFIG_HOME=%q XDG_DATA_HOME=%q XDG_STATE_HOME=%q XDG_CACHE_HOME=%q\n' \
    "$H/agy" "$H/agy/.config" "$H/agy/.local/share" "$H/agy/.local/state" "$T/agy-cache"
  printf 'export SSH_CONNECTION=%q AGY_CLI_DISABLE_AUTO_UPDATE=true\n' "$AGY_SSH_MARK"
}

agy_signed_in() {
  [[ -d "$H/agy/.gemini" ]] || return 1
  [[ -n "$(find "$H/agy/.gemini" -maxdepth 4 -name '*oauth-token*' -print -quit 2>/dev/null)" ]]
}

session_wipe() {
  if [[ -z "${S:-}" ]]; then
    return 0
  fi
  case "$S" in
    */aiusb-session|*/aiusb-session-"$UID") ;;
    *)
      warn "$(t SH_WARN_WIPE_PATH "$S")"
      return 1
      ;;
  esac
  [[ "$S" != "/" ]] || return 1
  # the vault id first: a half-wiped session must never be saved over the vault
  rm -f -- "$S/home/.aiusb-vault-id"
  rm -rf -- "$S"
  case "$BIN_CACHE" in
    /dev/shm/aiusb-bin-"$UID") rm -rf -- "$BIN_CACHE" ;;
  esac
  return 0
}

# The private key is in memory since the unlock: only the new passphrase is asked.
vault_change_passphrase() {
  info "$(t SH_INFO_CHANGE_PASS)"
  if [[ -z "$IDENTITY" ]] && ! identity_unlock; then
    warn "$(t SH_WARN_PASS_CHANGE_FAIL)"
    return 0
  fi
  if printf '%s\n' "$IDENTITY" | "$AGE_BIN" -p -o "$V/identity.age.new"; then
    mv -f -- "$V/identity.age.new" "$V/identity.age"
    sync
    info "$(t SH_INFO_PASS_CHANGED)"
    log_event "passphrase-changed"
  else
    rm -f -- "$V/identity.age.new"
    warn "$(t SH_WARN_PASS_CHANGE_FAIL)"
  fi
}

vault_reset() {
  local confirm
  read -r -p "$(t SH_ASK_RESET) " confirm
  if [[ "$confirm" != "RESET" ]]; then
    info "$(t SH_INFO_RESET_CANCELLED)"
    return 0
  fi
  SESSION_READY=0
  IDENTITY=""
  HIST_DIRTY=()
  rm -f -- "$V/identity.age" "$V/recipient.txt" "$V/vault.id" \
        "$V/home.tar.age" "$V/home.tar.age.bak" "$V/home.tar.age.new"
  rm -rf -- "$V/history"
  session_wipe
  info "$(t SH_INFO_VAULT_RESET)"
  log_event "vault-reset"
  exit 0
}

# ------------------------------------------------------------------ lock and stale sessions (5.6)
# Session switching: every start gets a clean new session on any OS, without questions.
# Leftovers of the previous session (another PC/OS, an unplug or a crash) are saved into
# the vault first, then wiped. The only stop is a launcher really running right now in
# another window on this PC. Lock file (both launchers): one line
#   host=<hostname> os=<windows|linux|rescue> pid=<pid> started=<UTC yyyy-MM-ddTHH:mm:ssZ>
# LOCK_STARTED is part of the lock interface; the Linux live test needs no start time.
# shellcheck disable=SC2034
lock_read() {
  local content token key value
  local -a tokens=()
  LOCK_HOST=""
  LOCK_OS=""
  LOCK_PID=""
  LOCK_STARTED=""
  [[ -f "$V/session.lock" ]] || return 1
  content="$(< "$V/session.lock")" || content=""
  content="${content//$'\n'/ }"
  content="${content//$'\r'/ }"
  read -r -a tokens <<< "$content"
  [[ "${#tokens[@]}" -gt 0 ]] || return 0
  for token in "${tokens[@]}"; do
    [[ "$token" == *=* ]] || continue
    key="${token%%=*}"
    value="${token#*=}"
    case "$key" in
      host)    LOCK_HOST="$value" ;;
      os)      LOCK_OS="$value" ;;
      pid)     LOCK_PID="$value" ;;
      started) LOCK_STARTED="$value" ;;
    esac
  done
  return 0
}

lock_is_live() {
  local me="" cmd=""
  local lock_host="${LOCK_HOST:-}" lock_os="${LOCK_OS:-}" lock_pid="${LOCK_PID:-}"
  # This machine?
  [[ -n "$lock_host" ]] || return 1
  me="$(host_name)"
  [[ -n "$me" ]] || return 1
  [[ "${lock_host,,}" == "${me,,}" ]] || return 1
  # Written by a launcher of this family ("Linux" from the old format counts)?
  case "${lock_os,,}" in
    linux|rescue) ;;
    *) return 1 ;;
  esac
  # A running launcher process that is not us?
  [[ "$lock_pid" =~ ^[0-9]+$ ]] || return 1
  [[ "$lock_pid" -ne "$$" ]] || return 1
  [[ -e "/proc/$lock_pid/cmdline" ]] || return 1
  cmd="$(tr '\0' ' ' < "/proc/$lock_pid/cmdline" 2>/dev/null)" || return 1
  [[ "$cmd" == *launcher.sh* ]] || return 1
  return 0
}

lock_check() {
  lock_read || return 0
  if lock_is_live; then
    warn "$(t SH_WARN_ALREADY_OPEN "$LOCK_PID")"
    exit 0
  fi
  info "$(t SH_INFO_CLEAN_LAST "${LOCK_HOST:-unknown}" "${LOCK_OS:-unknown}")"
  return 0
}

# LOCK_OWNED is read by lock_clear() in launcher.sh.
# shellcheck disable=SC2034
lock_write() {
  LOCK_OWNED=1
  printf 'host=%s os=%s pid=%s started=%s\n' \
    "$(host_name)" "$MODE" "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$V/session.lock" 2>/dev/null || true
}

# The Windows launcher keeps its decrypted session ON the stick at
# $USB/aiusb/session. Save its newer logins into the vault (same vault id),
# then wipe the folder; if it cannot be deleted, rename it aside so the next
# Windows start gets a fresh one. When the save fails the folder is kept, so
# its (possibly newer) logins are not lost and are tried again next time.
# AGE_BIN must be ready (prepare_bins ran before). Never prints secrets.
recover_stick_session() {
  local stick_session="$USB/aiusb/session" sid_file vid_file
  local sid="" vid="" real_home="" stamp="" old_path="" save_rc=0 wipe=1
  [[ -d "$stick_session" ]] || return 0
  sid_file="$stick_session/home/.aiusb-vault-id"
  vid_file="$V/vault.id"
  if [[ -f "$sid_file" && -r "$vid_file" ]]; then
    IFS= read -r sid < "$sid_file" || true
    IFS= read -r vid < "$vid_file" || true
    sid="${sid#"${sid%%[![:space:]]*}"}"
    sid="${sid%"${sid##*[![:space:]]}"}"
    vid="${vid#"${vid%%[![:space:]]*}"}"
    vid="${vid%"${vid##*[![:space:]]}"}"
    if [[ -n "$vid" && "$sid" == "$vid" ]]; then
      info "$(t SH_INFO_SAVE_WINDOWS)"
      real_home="$H"
      H="$stick_session/home"
      vault_save --recover
      save_rc=$?
      H="$real_home"
      if [[ "$save_rc" -ne 0 ]]; then
        warn "$(t SH_WARN_WINDOWS_KEPT)"
        wipe=0
      fi
    fi
  fi
  if [[ "$wipe" -eq 1 ]]; then
    case "$stick_session" in
      */aiusb/session) ;;
      *)
        warn "$(t SH_WARN_STICK_SESSION_PATH "$stick_session")"
        return 0
        ;;
    esac
    rm -f -- "$stick_session/home/.aiusb-vault-id" 2>/dev/null || true
    rm -rf -- "$stick_session" 2>/dev/null || true
    if [[ -d "$stick_session" ]]; then
      stamp="$(date -u +%Y%m%d-%H%M%S)"
      mv -- "$stick_session" "$USB/aiusb/session-old-$stamp" 2>/dev/null || true
    fi
  fi
  for old_path in "$USB/aiusb"/session-old-*; do
    [[ -d "$old_path" ]] || continue
    rm -rf -- "$old_path" 2>/dev/null || true
  done
  return 0
}

lock_clear() {
  [[ "$LOCK_OWNED" -eq 1 ]] || return 0
  rm -f -- "$V/session.lock" 2>/dev/null || true
  LOCK_OWNED=0
}

stale_recover() {
  local sid="" vid=""
  if [[ ! -f "$H/.aiusb-vault-id" ]]; then
    STALE_PENDING=0
    return 0
  fi
  IFS= read -r sid < "$H/.aiusb-vault-id" || true
  if [[ -r "$V/vault.id" ]]; then
    IFS= read -r vid < "$V/vault.id" || true
  fi
  if [[ -n "$vid" && "$sid" == "$vid" ]]; then
    info "$(t SH_INFO_STALE_FOUND)"
    vault_save --recover
  fi
  STALE_PENDING=0
  session_wipe
  mkdir -p -- "$S" "$H" "$T" "$S/bin" || die "$(t SH_ERR_RECREATE_SESSION)"
  chmod 700 "$S" "$H" "$T" "$S/bin"
  prepare_bins
}

# ------------------------------------------------------------------ unplug watcher (5.7)
watcher_start() {
  if [[ -n "$WATCHER_PID" ]]; then
    return 0
  fi
  local marker="$V/vault.id" session="$S" parent="$$" usb_dev=""
  usb_dev="$(findmnt -no SOURCE --target "$USB" 2>/dev/null | head -n 1)"
  usb_dev="${usb_dev%%\[*}"   # btrfs/bind mounts report /dev/xxx[/subvol]
  [[ "$usb_dev" == /dev/* && -b "$usb_dev" ]] || usb_dev=""
  (
    fails=0
    while :; do
      sleep 2
      if [[ -r "$marker" ]] && { [[ -z "$usb_dev" ]] || [[ -b "$usb_dev" ]]; }; then
        fails=0
      else
        fails=$((fails + 1))
        if [[ "$fails" -ge 2 ]]; then
          break
        fi
      fi
    done
    pgid=""
    if [[ -r "$session/agent.pgid" ]]; then
      IFS= read -r pgid < "$session/agent.pgid" || pgid=""
    fi
    if [[ "$pgid" =~ ^[0-9]+$ ]]; then
      kill -TERM -- -"$pgid" 2>/dev/null || true
      ( sleep 3; kill -KILL -- -"$pgid" 2>/dev/null ) &
    fi
    rm -rf -- "$session" 2>/dev/null || true
    log_event "usb-removed"
    printf '\n%s\n' "$(t SH_USB_REMOVED)" > /dev/tty 2>/dev/null \
      || printf '\n%s\n' "$(t SH_USB_REMOVED)"
    kill -TERM "$parent" 2>/dev/null || true
  ) &
  WATCHER_PID=$!
}

watcher_stop() {
  if [[ -z "$WATCHER_PID" ]]; then
    return 0
  fi
  kill "$WATCHER_PID" 2>/dev/null || true
  wait "$WATCHER_PID" 2>/dev/null || true
  WATCHER_PID=""
}

# ------------------------------------------------------------------ agent environment (5.9) and wrappers (5.10)
# Drop every host variable that could steer or sign in an agent (credentials,
# endpoints, providers, models): the stick's agents use only the stick's setup.
scrub_agent_env() {
  local name
  for name in $(compgen -e); do
    case "$name" in
      ANTHROPIC_*|CLAUDE_*|CLAUDECODE|OPENAI_*|CODEX_*|GEMINI_*|GOOGLE_*|AGY_*|ANTIGRAVITY_*|JETSKI_*) unset "$name" ;;
    esac
  done
}

apply_common_env() {
  scrub_agent_env
  umask 022   # the session dir itself is 0700; files the agents create on the PC stay normal
  export AIUSB_ROOT="$USB" AIUSB_MODE="$MODE" AIUSB_SESSION="$S"
  export TMPDIR="$T" TMP="$T" TEMP="$T" CLAUDE_CODE_TMPDIR="$T"
  export DISABLE_AUTOUPDATER=1 DISABLE_UPDATES=1
  export ANTHROPIC_CONFIG_DIR="$H/anthropic"
  export CODEX_HOME="$H/codex"
  export CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL=1
  # one conversation folder for Claude Code on every PC; Codex databases in one folder
  export CLAUDE_CODE_PROJECT_DIR_NAME="$CLAUDE_PROJECT_DIR_NAME" CODEX_SQLITE_HOME="$H/codex/sqlite"
  if [[ "$MODE" == "rescue" ]]; then
    export BROWSER=firefox-esr
  fi
  PATH="$S/bin:$BIN_DIR:$PATH"
  export PATH
}

write_agent_env() {
  {
    printf '#!/usr/bin/env bash\n'
    printf '# Generated by the AI-USB launcher. Non-secret environment only.\n'
    printf '%s\n' 'for _n in $(compgen -e); do case "$_n" in ANTHROPIC_*|CLAUDE_*|CLAUDECODE|OPENAI_*|CODEX_*|GEMINI_*|GOOGLE_*|AGY_*|ANTIGRAVITY_*|JETSKI_*) unset "$_n" ;; esac; done; unset _n'
    printf 'umask 022\n'
    printf 'export AIUSB_ROOT=%q\n' "$USB"
    printf 'export AIUSB_MODE=%q\n' "$MODE"
    printf 'export AIUSB_SESSION=%q\n' "$S"
    printf 'export TMPDIR=%q TMP=%q TEMP=%q CLAUDE_CODE_TMPDIR=%q\n' "$T" "$T" "$T" "$T"
    printf 'export DISABLE_AUTOUPDATER=1 DISABLE_UPDATES=1\n'
    printf 'export ANTHROPIC_CONFIG_DIR=%q\n' "$H/anthropic"
    printf 'export CODEX_HOME=%q\n' "$H/codex"
    printf 'export CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL=1\n'
    printf 'export CLAUDE_CODE_PROJECT_DIR_NAME=%q CODEX_SQLITE_HOME=%q\n' \
      "$CLAUDE_PROJECT_DIR_NAME" "$H/codex/sqlite"
    if [[ "$MODE" == "rescue" ]]; then
      printf 'export BROWSER=firefox-esr\n'
    fi
    printf 'export PATH=%q\n' "$S/bin:$BIN_DIR:$PATH"
  } > "$S/agent-env.sh"
  chmod 700 "$S/agent-env.sh"
}

# Claude Code and Claude Code on GLM share one wrapper generator.
gen_claude_wrapper() {
  local out="$1" config_dir="$2" flavor="$3"
  {
    printf '#!/usr/bin/env bash\n'
    printf '# Generated by the AI-USB launcher.\n'
    printf 'source %q\n' "$S/agent-env.sh"
    printf 'export CLAUDE_CONFIG_DIR=%q\n' "$config_dir"
    if [[ "$flavor" == "glm" ]]; then
      printf 'export ANTHROPIC_BASE_URL=%q\n' "$GLM_BASE_URL"
      printf 'export API_TIMEOUT_MS=3000000\n'
      if [[ -n "$GLM_OPUS_MODEL" ]]; then
        printf 'export ANTHROPIC_DEFAULT_OPUS_MODEL=%q\n' "$GLM_OPUS_MODEL"
      fi
      if [[ -n "$GLM_SONNET_MODEL" ]]; then
        printf 'export ANTHROPIC_DEFAULT_SONNET_MODEL=%q\n' "$GLM_SONNET_MODEL"
      fi
      if [[ -n "$GLM_HAIKU_MODEL" ]]; then
        printf 'export ANTHROPIC_DEFAULT_HAIKU_MODEL=%q\n' "$GLM_HAIKU_MODEL"
      fi
      printf 'if [[ -s %q ]]; then\n' "$H/secrets/zai.key"
      printf '  export ANTHROPIC_AUTH_TOKEN="$(<%q)"\n' "$H/secrets/zai.key"
      printf 'else\n'
      printf '  printf "No z.ai key saved. Use menu option K, then 1.\\n" >&2\n'
      printf '  exit 1\n'
      printf 'fi\n'
    fi
    printf 'cd %q 2>/dev/null || cd -- "$HOME" 2>/dev/null || true\n' "$USB/aiusb/workspace"
    printf 'args=( --add-dir / )\n'
    if [[ "$AUTONOMOUS" == "1" ]]; then
      printf 'if [[ "$(id -u)" -eq 0 ]]; then\n'
      printf '  args+=( --permission-mode acceptEdits )\n'
      printf 'else\n'
      printf '  args+=( --dangerously-skip-permissions )\n'
      printf 'fi\n'
    fi
    printf 'exec %q "${args[@]}" "$@"\n' "$CLAUDE_BIN"
  } > "$out"
  chmod 700 "$out"
}

gen_codex_wrapper() {
  local out="$1"
  {
    printf '#!/usr/bin/env bash\n'
    printf '# Generated by the AI-USB launcher.\n'
    printf 'source %q\n' "$S/agent-env.sh"
    printf 'cd %q 2>/dev/null || true\n' "$USB/aiusb/workspace"
    if [[ "$AUTONOMOUS" == "1" ]]; then
      printf 'exec %q --no-daemon -C %q --dangerously-bypass-approvals-and-sandbox "$@"\n' \
        "$CODEX_BIN" "$USB/aiusb/workspace"
    else
      printf 'exec %q --no-daemon -C %q -s danger-full-access -a on-request "$@"\n' \
        "$CODEX_BIN" "$USB/aiusb/workspace"
    fi
  } > "$out"
  chmod 700 "$out"
}

gen_agy_wrapper() {
  local out="$1"
  {
    printf '#!/usr/bin/env bash\n'
    printf '# Generated by the AI-USB launcher.\n'
    if [[ -z "$AGY_BIN" ]]; then
      printf 'printf "%%s\\n" %q >&2\nexit 1\n' "$(t SH_WARN_AGY_MISSING)"
    else
      printf 'source %q\n' "$S/agent-env.sh"
      agy_env_lines
      printf 'cd %q 2>/dev/null || true\n' "$USB/aiusb/workspace"
      if [[ "$AUTONOMOUS" == "1" ]]; then
        printf 'exec %q --add-dir / --dangerously-skip-permissions "$@"\n' "$AGY_BIN"
      else
        printf 'exec %q --add-dir / "$@"\n' "$AGY_BIN"
      fi
    fi
  } > "$out"
  chmod 700 "$out"
}

write_wrappers() {
  mkdir -p -- "$S/bin"
  write_agent_env
  gen_claude_wrapper "$S/bin/claude" "$H/claude" "claude"
  gen_claude_wrapper "$S/bin/claude-glm" "$H/claude-glm" "glm"
  gen_codex_wrapper "$S/bin/codex"
  gen_agy_wrapper "$S/bin/agy"
  printf '%s\n' "PS1='(ai-usb) \\w \\\$ '" > "$S/shellrc"
}

# ------------------------------------------------------------------ agent context (5.10)
os_pretty_name() {
  local line=""
  if [[ -r /etc/os-release ]]; then
    line="$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | head -n 1)"
    line="${line%\"}"
    line="${line#\"}"
  fi
  if [[ -z "$line" ]]; then
    line="$(uname -s 2>/dev/null || printf '%s' unknown)"
  fi
  printf '%s' "$line"
}

build_context() {
  local agent="$1" mode_file target
  case "$MODE" in
    rescue) mode_file="rescue.md" ;;
    *)      mode_file="host-linux.md" ;;
  esac
  case "$agent" in
    claude) target="$H/claude/CLAUDE.md" ;;
    glm)    target="$H/claude-glm/CLAUDE.md" ;;
    codex)  target="$H/codex/AGENTS.md" ;;
    agy)    target="$H/agy/.gemini/GEMINI.md" ;;
    *)      return 0 ;;
  esac
  mkdir -p -- "$(dirname -- "$target")"
  {
    if [[ -f "$USB/aiusb/context/$mode_file" ]]; then
      cat -- "$USB/aiusb/context/$mode_file"
      printf '\n'
    fi
    printf '## This machine (generated)\n\n'
    printf -- '- Hostname: %s\n' "$(host_name)"
    printf -- '- OS: %s\n' "$(os_pretty_name)"
    printf -- '- Mode: %s\n' "$MODE"
    if [[ "$EUID" -eq 0 ]]; then
      printf -- '- Administrator (root): yes\n'
    else
      printf -- '- Administrator (root): no\n'
    fi
    if [[ "$LANG_CODE" == "sk" ]]; then
      printf -- '- User language: Slovak (sk). Talk to the user in Slovak.\n'
    else
      printf -- '- User language: English (en). Talk to the user in English.\n'
    fi
    printf -- '- USB stick: %s\n' "$USB"
    printf -- '- Workspace: %s\n' "$USB/aiusb/workspace"
    printf -- '- Backups: %s\n' "$USB/aiusb/backups"
    if [[ "$agent" == "agy" ]]; then
      printf -- '- Your HOME (%s) is your own folder inside the encrypted session on the stick, wiped\n' "$H/agy"
      printf -- '  after the session. The home folder of the PC user is %s.\n' "$(real_home)"
    fi
    printf -- '- Drives and mounts:\n\n'
    printf '```\n'
    if command -v lsblk >/dev/null 2>&1; then
      lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS 2>/dev/null || df -h 2>/dev/null || true
    else
      df -h 2>/dev/null || true
    fi
    printf '```\n'
    if [[ "$MODE" == "rescue" && -f "$USB/aiusb/rescue/win-mount.sh" ]]; then
      printf '\nWindows disks:\n\n```\n'
      bash "$USB/aiusb/rescue/win-mount.sh" --status 2>/dev/null || true
      printf '```\n'
    fi
  } > "$target"
}

# ------------------------------------------------------------------ status lines (5.11)
agent_status_line() {
  case "$1" in
    claude)
      if [[ -f "$H/claude/.credentials.json" ]]; then
        t COMMON_STATUS_SIGNED_IN
      else
        t COMMON_STATUS_NOT_SIGNED_IN
      fi
      ;;
    glm)
      if [[ -s "$H/secrets/zai.key" ]]; then
        t COMMON_STATUS_KEY_SAVED
      else
        t COMMON_STATUS_NO_KEY
      fi
      ;;
    codex)
      if [[ -f "$H/codex/auth.json" ]]; then
        t COMMON_STATUS_SIGNED_IN
      else
        t COMMON_STATUS_NOT_SIGNED_IN
      fi
      ;;
    agy)
      if agy_signed_in; then
        t COMMON_STATUS_SIGNED_IN
      else
        t COMMON_STATUS_NOT_SIGNED_IN
      fi
      ;;
  esac
}

# ------------------------------------------------------------------ keys helpers (5.11)
set_key() {
  local file="$1" k=""
  read -rs -p "$(t SH_ASK_PASTE_KEY) " k
  printf '\n'
  if [[ -z "$k" ]]; then
    unset k
    info "$(t SH_INFO_KEY_EMPTY)"
    return 1
  fi
  printf '%s' "$k" > "$file"
  unset k
  chmod 600 "$file"
  info "$(t SH_INFO_KEY_SAVED "$(wc -c < "$file")")"
  return 0
}

run_codex_login() {
  local rc
  local -a login_args=(login)
  if [[ "$MODE" == "rescue" || "$EUID" -eq 0 ]]; then
    login_args+=(--device-auth)
  fi
  rm -f -- "$S/agent.pgid"
  log_event "agent-start codex-login"
  (
    apply_common_env
    cd "$USB/aiusb/workspace" 2>/dev/null || cd "$H" || true
    exec bash -c 'echo $$ > "$1"; shift; exec "$@"' _ "$S/agent.pgid" "$CODEX_BIN" "${login_args[@]}"
  )
  rc=$?
  log_event "agent-exit codex-login rc=$rc"
  vault_save
}

sign_out_menu() {
  local a=""
  printf '  %s\n' "$(t SH_SIGNOUT_TITLE)"
  printf '  %s\n' "$(t SH_SIGNOUT_ITEMS)"
  read -rsn1 a || return 0
  printf '\n'
  case "$a" in
    1)
      rm -f -- "$H/claude/.credentials.json"
      info "$(t SH_INFO_SIGNED_OUT_CLAUDE)"
      ;;
    2)
      rm -f -- "$H/secrets/zai.key"
      info "$(t SH_INFO_REMOVED_ZAI_KEY)"
      ;;
    3)
      rm -f -- "$H/codex/auth.json"
      info "$(t SH_INFO_SIGNED_OUT_CODEX)"
      ;;
    4)
      [[ -d "$H/agy/.gemini" ]] && find "$H/agy/.gemini" -name '*oauth-token*' -type f -delete
      info "$(t SH_INFO_SIGNED_OUT_AGY)"
      ;;
    *)
      return 0
      ;;
  esac
  vault_save
}

keys_menu() {
  local choice=""
  while :; do
    printf '\n'
    printf '  %s\n' "$(t COMMON_KEYS_TITLE)"
    printf '  --------------\n'
    printf '  %s\n' "$(t COMMON_KEYS_NOTE)"
    printf '  %s\n' "$(t COMMON_KEYS_1)"
    printf '  %s\n' "$(t COMMON_KEYS_2)"
    printf '  %s\n' "$(t COMMON_KEYS_3)"
    printf '  %s\n' "$(t COMMON_KEYS_4)"
    printf '  %s\n' "$(t COMMON_KEYS_5)"
    printf '  %s\n' "$(t COMMON_KEYS_B)"
    read -rsn1 choice || return 0
    printf '\n'
    case "$choice" in
      1) set_key "$H/secrets/zai.key" && vault_save ;;
      2) run_codex_login ;;
      3) sign_out_menu ;;
      4) vault_change_passphrase ;;
      5) vault_reset ;;
      b|B) return 0 ;;
      *) : ;;
    esac
  done
}

# ------------------------------------------------------------------ running agents (5.10)
# run_agent AGENT [resume]: "resume" opens the agent's list of saved conversations.
run_agent() {
  local which="$1" resume="${2:-}" rc=0 exe="" g
  local -a args=() groups=()
  mkdir -p -- "$USB/aiusb/workspace" 2>/dev/null || true
  case "$which" in
    claude)
      exe="$CLAUDE_BIN"
      build_context "claude"
      args=( --add-dir / )
      if [[ "$AUTONOMOUS" == "1" ]]; then
        if [[ "$EUID" -eq 0 ]]; then
          args+=( --permission-mode acceptEdits )
          info "$(t SH_INFO_ROOT_ACCEPTEDITS)"
        else
          args+=( --dangerously-skip-permissions )
        fi
      fi
      [[ -n "$resume" ]] && args+=( --resume )
      ;;
    glm)
      if [[ ! -s "$H/secrets/zai.key" ]]; then
        info "$(t SH_INFO_GLM_NEEDS_KEY)"
        if ! set_key "$H/secrets/zai.key"; then
          return 0
        fi
        vault_save
      fi
      exe="$CLAUDE_BIN"
      build_context "glm"
      args=( --add-dir / )
      if [[ "$AUTONOMOUS" == "1" ]]; then
        if [[ "$EUID" -eq 0 ]]; then
          args+=( --permission-mode acceptEdits )
          info "$(t SH_INFO_ROOT_ACCEPTEDITS)"
        else
          args+=( --dangerously-skip-permissions )
        fi
      fi
      [[ -n "$resume" ]] && args+=( --resume )
      ;;
    codex)
      exe="$CODEX_BIN"
      build_context "codex"
      args=( --no-daemon -C "$USB/aiusb/workspace" )
      if [[ "$AUTONOMOUS" == "1" ]]; then
        args+=( --dangerously-bypass-approvals-and-sandbox )
      else
        args+=( -s danger-full-access -a on-request )
      fi
      # --all: also the conversations started on other PCs (another workspace path)
      [[ -n "$resume" ]] && args=( resume --all "${args[@]}" )
      if [[ ! -f "$H/codex/auth.json" ]]; then
        info "$(t SH_INFO_CODEX_SIGNIN_FIRST)"
        run_codex_login
      fi
      ;;
    agy)
      if [[ -z "$AGY_BIN" ]]; then
        warn "$(t SH_WARN_AGY_MISSING)"
        return 0
      fi
      exe="$AGY_BIN"
      build_context "agy"
      args=( --add-dir / )
      if [[ "$AUTONOMOUS" == "1" ]]; then
        args+=( --dangerously-skip-permissions )
      fi
      [[ -n "$resume" ]] && info "$(t COMMON_RESUME_AGY)"
      ;;
    shell)
      exe="/bin/bash"
      # PS1 comes from an rcfile: the non-interactive bash that records the
      # pgid would drop an exported PS1.
      args=( --noprofile --rcfile "$S/shellrc" -i )
      info "$(t SH_INFO_EXIT_HINT)"
      ;;
    *)
      return 0
      ;;
  esac
  # this agent's saved conversations, opened on first use in this session
  mapfile -t groups < <(agent_groups "$which")
  for g in "${groups[@]}"; do
    if hist_load "$g"; then
      HIST_DIRTY[$g]=1
    fi
  done
  case "$which" in
    claude|glm) claude_merge_projects ;;
    shell)      claude_merge_projects ;;
  esac
  rm -f -- "$S/agent.pgid"
  log_event "agent-start $which${resume:+ resume}"
  (
    apply_common_env
    case "$which" in
      claude)
        export CLAUDE_CONFIG_DIR="$H/claude"
        ;;
      glm)
        export CLAUDE_CONFIG_DIR="$H/claude-glm"
        export ANTHROPIC_BASE_URL="$GLM_BASE_URL"
        ANTHROPIC_AUTH_TOKEN="$(<"$H/secrets/zai.key")"
        export ANTHROPIC_AUTH_TOKEN
        export API_TIMEOUT_MS=3000000
        if [[ -n "$GLM_OPUS_MODEL" ]]; then
          export ANTHROPIC_DEFAULT_OPUS_MODEL="$GLM_OPUS_MODEL"
        fi
        if [[ -n "$GLM_SONNET_MODEL" ]]; then
          export ANTHROPIC_DEFAULT_SONNET_MODEL="$GLM_SONNET_MODEL"
        fi
        if [[ -n "$GLM_HAIKU_MODEL" ]]; then
          export ANTHROPIC_DEFAULT_HAIKU_MODEL="$GLM_HAIKU_MODEL"
        fi
        ;;
      agy)
        eval "$(agy_env_lines)"
        ;;
      shell)
        export CLAUDE_CONFIG_DIR="$H/claude"
        ;;
      *) : ;;
    esac
    cd "$USB/aiusb/workspace" 2>/dev/null || cd "$H" || true
    # With job control on, this process is the foreground job leader: $$ == pgid.
    exec bash -c 'echo $$ > "$1"; shift; exec "$@"' _ "$S/agent.pgid" "$exe" "${args[@]}"
  )
  rc=$?
  log_event "agent-exit $which rc=$rc"
  vault_save "${groups[@]}"
  return 0
}

resume_menu() {
  local a=""
  printf '\n  %s\n' "$(t COMMON_RESUME_TITLE)"
  printf '  %s\n' "$(t COMMON_RESUME_ITEMS)"
  read -rsn1 a || return 0
  printf '\n'
  case "$a" in
    1) run_agent claude resume ;;
    2) run_agent glm resume ;;
    3) run_agent codex resume ;;
    4) run_agent agy resume ;;
    *) return 0 ;;
  esac
}

# ------------------------------------------------------------------ main menu (5.11)
main_menu() {
  local choice="" admin="" host=""
  host="$(host_name)"
  while :; do
    if [[ "$EUID" -eq 0 ]]; then admin="$(t COMMON_YES)"; else admin="$(t COMMON_NO)"; fi
    show_banner
    printf ' +-- AISTiUSB -- %s -- %s -- %s: %s -----------+\n' \
      "$MODE" "$host" "$(t COMMON_ADMIN)" "$admin"
    printf ' | %-28s[%s]\n' "$(t COMMON_MENU_1)" "$(agent_status_line claude)"
    printf ' | %-28s[%s]\n' "$(t COMMON_MENU_2)" "$(agent_status_line glm)"
    printf ' | %-28s[%s]\n' "$(t COMMON_MENU_3)" "$(agent_status_line codex)"
    printf ' | %-28s[%s]\n' "$(t COMMON_MENU_4)" "$(agent_status_line agy)"
    printf ' | %s\n' "$(t COMMON_MENU_5)"
    printf ' | %s\n' "$(t COMMON_MENU_R)"
    if [[ "$AUTONOMOUS" == "1" ]]; then
      printf ' | %s%s%s\n' "$RED" "$(t COMMON_MENU_A_ON)" "$RESET"
    else
      printf ' | %s\n' "$(t COMMON_MENU_A_OFF)"
    fi
    printf ' | %s\n' "$(t COMMON_MENU_K)"
    if [[ "$MODE" == "rescue" ]]; then
      printf ' | %s\n' "$(t COMMON_MENU_N)"
      printf ' | %s\n' "$(t COMMON_MENU_W)"
    fi
    printf ' | %s\n' "$(t COMMON_MENU_L)"
    printf ' | %s\n' "$(t COMMON_MENU_H)"
    printf ' | %s\n' "$(t COMMON_MENU_Q)"
    printf ' +------------------------------------------------+\n'
    read -rsn1 choice || { printf '\n'; info "$(t SH_INFO_INPUT_CLOSED)"; exit 0; }
    printf '\n'
    case "$choice" in
      1) run_agent claude ;;
      2) run_agent glm ;;
      3) run_agent codex ;;
      4) run_agent agy ;;
      5) run_agent shell ;;
      r|R) resume_menu ;;
      a|A)
        if [[ "$AUTONOMOUS" == "1" ]]; then
          AUTONOMOUS=0
        else
          AUTONOMOUS=1
        fi
        write_wrappers
        ;;
      k|K) keys_menu ;;
      l|L)
        lang_ask
        ;;
      h|H)
        printf '\n%s\n\n' "$(t COMMON_HELP_TEXT)"
        printf '%s' "$(t COMMON_PRESS_ENTER)"
        read -r choice || :
        ;;
      n|N)
        if [[ "$MODE" == "rescue" ]]; then
          if command -v nmtui >/dev/null 2>&1; then
            nmtui
          else
            warn "$(t SH_WARN_NO_NMTUI)"
          fi
        fi
        ;;
      w|W)
        if [[ "$MODE" == "rescue" ]]; then
          if [[ -f "$USB/aiusb/rescue/win-mount.sh" ]]; then
            bash "$USB/aiusb/rescue/win-mount.sh" --mount-all
            bash "$USB/aiusb/rescue/win-mount.sh" --status
          else
            warn "$(t SH_WARN_NO_WINMOUNT)"
          fi
        fi
        ;;
      q|Q)
        info "$(t SH_INFO_GOODBYE)"
        log_event "quit"
        exit 0
        ;;
      *) : ;;
    esac
  done
}

# ------------------------------------------------------------------ cleanup and main
cleanup() {
  if [[ "$AIUSB_CLEANED" -eq 1 ]]; then
    return 0
  fi
  AIUSB_CLEANED=1
  # The final save must finish even if the terminal window is closed (SIGHUP) or
  # Ctrl+C is pressed right after Q: ignore those signals from here on.
  trap '' INT TERM HUP
  watcher_stop
  if [[ "$SESSION_READY" -eq 1 && -n "${S:-}" && -r "$V/vault.id" ]]; then
    if [[ "${#HIST_DIRTY[@]}" -gt 0 ]]; then
      vault_save "${!HIST_DIRTY[@]}"
    else
      vault_save
    fi
  fi
  IDENTITY=""
  if [[ "$STALE_PENDING" -eq 1 ]]; then
    warn "$(t SH_WARN_STALE_RAM)"
  else
    session_wipe
  fi
  lock_clear
}

main() {
  trap cleanup EXIT
  trap 'cleanup; exit 130' INT
  trap 'cleanup; exit 143' TERM
  trap 'cleanup; exit 129' HUP
  if [[ "${AIUSB_ELEVATED:-0}" != "1" ]]; then
    show_banner
  fi
  if [[ "$LANG_FROM_ENV" -eq 0 ]]; then
    lang_ask
  fi
  maybe_elevate
  log_event "start"
  mkdir -p -- "$USB/aiusb/workspace" 2>/dev/null || true
  mkdir -p -- "$USB/aiusb/logs" 2>/dev/null || true
  lock_check
  setup_session_paths
  prepare_bins
  stale_recover
  recover_stick_session
  info "$(t SH_INFO_KBD_TIP)"
  if [[ ! -f "$V/identity.age" ]]; then
    vault_create
  else
    vault_unlock
    ensure_home_skeleton
  fi
  lock_write
  watcher_start
  write_wrappers
  printf '\n'
  info "$(t SH_INFO_READY "$MODE" "$USB")"
  info "$(t SH_INFO_WORKSPACE "$USB/aiusb/workspace")"
  main_menu
}

# ------------------------------------------------------------------ entry point
setup_colors
require_bash4
lang_boot
parse_args "$@"
check_environment
locate_stick
readonly MODE SELF USB V CONF_FILE BIN_DIR
read_conf
readonly GLM_BASE_URL GLM_OPUS_MODEL GLM_SONNET_MODEL GLM_HAIKU_MODEL
main
