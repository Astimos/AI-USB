#!/usr/bin/env bash
# rescue-session.sh -- AI-USB rescue boot session (docs/ARCHITECTURE.md section 7).
#
# Started by /usr/local/sbin/aiusb-boot on tty1 (outer stage). The outer stage
# asks for the language, applies the keyboard layout and the TTY font, then
# tries to start a graphical terminal (cage + foot) which runs this script
# again with --inner. If cage exits non-zero within 10 s, it retries once with
# software rendering, then falls back to running --inner directly on the TTY.
set -uo pipefail

readonly USB="/mnt/aiusb"
readonly R="$USB/aiusb/rescue"
readonly L="$USB/aiusb/launcher/launcher.sh"
readonly LOGDIR="$USB/aiusb/logs"
readonly LANGDIR="$USB/aiusb/lang"
readonly LANG_CURRENT="$LANGDIR/current"
readonly NETURL="https://api.anthropic.com"
readonly BANNER="$USB/aiusb/launcher/banner.txt"

# TTY fonts for the Slovak letters on the text console (used only when the
# selected language is sk; wide screens get the big font).
readonly TTYFONT_WIDE="/usr/share/consolefonts/Uni2-TerminusBold28x14.psf.gz"
readonly TTYFONT_SMALL="/usr/share/consolefonts/Uni2-Terminus16.psf.gz"

# Language texts (aiusb/lang/en.txt overlaid with the selected language) and
# the code of the active language (en, sk).
declare -A TXT=()
LANG_CODE="en"

# Results of the last cage attempt (set by run_cage).
GUI_RC=0
GUI_DUR=0

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# log_action EVENT...: append one non-secret line to the rescue log.
log_action() {
    [ -d "$LOGDIR" ] || return 0
    printf '%s rescue-session %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOGDIR/rescue-actions.log" 2>/dev/null || true
}

# conf_get KEY: print the value of KEY from aiusb.conf. Plain-text parse,
# never sourced. Returns 1 if the file or the key is missing.
conf_get() {
    local key="$1"
    local conf="$USB/aiusb/aiusb.conf"
    local line="" k="" v=""
    [ -r "$conf" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" == "#"* ]] && continue
        [[ "$line" == *=* ]] || continue
        k="${line%%=*}"
        v="${line#*=}"
        [ "$k" = "$key" ] || continue
        printf '%s\n' "$v"
        return 0
    done <"$conf"
    return 1
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "$(t RS_MUST_ROOT)"
        exit 1
    fi
}

usage() {
    echo "$(t RS_USAGE_1)"
    echo "$(t RS_USAGE_2)"
}

step6_message() {
    echo
    echo "$(t RS_STEP6)"
}

# ---------------------------------------------------------------------------
# language
# ---------------------------------------------------------------------------

# t KEY [args...]: print the text of KEY from the language files with {0},
# {1}, ... replaced by the args and the two characters '\'+'n' turned into
# line breaks. English is always loaded first, so a key missing from the
# selected language shows the English text; a key missing everywhere shows
# the key itself. No trailing newline.
t() {
    local key="$1"
    shift
    local s="${TXT[$key]:-$key}"
    local i=0
    local a=""
    local nl=$'\n'
    for a in "$@"; do
        s="${s//"{$i}"/"$a"}"
        i=$((i + 1))
    done
    s="${s//'\n'/"$nl"}"
    printf '%s' "$s"
}

# lang_valid CODE: true when aiusb/lang/CODE.txt exists and defines
# COMMON_LANG_NAME.
lang_valid() {
    local code="$1"
    [[ "$code" =~ ^[a-z][a-z0-9_-]*$ ]] || return 1
    [ -r "$LANGDIR/$code.txt" ] || return 1
    grep -q '^COMMON_LANG_NAME=' "$LANGDIR/$code.txt" 2>/dev/null
}

# lang_read_current: print the code saved in aiusb/lang/current, or en when
# the file is missing or holds an invalid code.
lang_read_current() {
    local code=""
    if [ -r "$LANG_CURRENT" ]; then
        IFS= read -r code <"$LANG_CURRENT" || true
        code="${code%$'\r'}"
    fi
    if ! lang_valid "$code"; then
        code="en"
    fi
    printf '%s' "$code"
}

# lang_load CODE: load aiusb/lang/en.txt, then aiusb/lang/CODE.txt on top of
# it, so a key missing from the translation shows the English text.
lang_load() {
    local code="$1"
    local file="" line="" key="" val=""
    for file in "$LANGDIR/en.txt" "$LANGDIR/$code.txt"; do
        [ -r "$file" ] || continue
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%$'\r'}"
            [[ "$line" == "#"* ]] && continue
            [[ "$line" == *=* ]] || continue
            key="${line%%=*}"
            val="${line#*=}"
            TXT["$key"]="$val"
        done <"$file"
    done
    LANG_CODE="$code"
}

# lang_save CODE: remember the choice in aiusb/lang/current. Write errors
# are ignored (the stick may be missing or read-only).
lang_save() {
    printf '%s\n' "$1" >"$LANG_CURRENT" 2>/dev/null || true
}

# lang_init: load the language without asking: AIUSB_LANG when it holds a
# valid code, else the saved choice, else en.
lang_init() {
    local code="${AIUSB_LANG:-}"
    lang_valid "$code" || code="$(lang_read_current)"
    lang_load "$code"
}

# language_step: ask which language to use (not at all when AIUSB_LANG
# already holds a valid code), load the texts, save the choice and export
# AIUSB_LANG so --inner and the launcher do not ask again. The read times
# out like the keyboard question so unattended boots keep moving.
language_step() {
    local code="$LANG_CODE"
    local input=""
    if lang_valid "${AIUSB_LANG:-}"; then
        return 0
    fi
    printf 'Language / Jazyk:  1) English   2) Slovencina   [Enter = %s]: ' "$(t COMMON_LANG_NAME)"
    if ! read -r -t 15 input; then
        input=""
        echo
    fi
    case "$input" in
        1|en)
            lang_valid "en" && code="en"
            ;;
        2|sk)
            lang_valid "sk" && code="sk"
            ;;
        *)
            ;;
    esac
    lang_load "$code"
    lang_save "$code"
    export AIUSB_LANG="$code"
    log_action "language=$code"
}

# ---------------------------------------------------------------------------
# outer stage (tty1)
# ---------------------------------------------------------------------------

# Ask for the keyboard layout (default from aiusb.conf), load it on the TTY,
# and export it for cage/foot and the inner stage.
keyboard_step() {
    local def="" input="" layout=""
    local re='^[A-Za-z0-9][A-Za-z0-9_-]*$'
    def="$(conf_get KEYBOARD_LAYOUT)"
    [ -n "$def" ] || def="us"
    printf '%s' "$(t RS_KBD_PROMPT "$def")"
    if ! read -r -t 15 input; then
        input=""
        echo
    fi
    input="${input:-$def}"
    if [[ "$input" =~ $re ]]; then
        layout="$input"
    else
        echo "$(t RS_KBD_UNKNOWN "$def")"
        layout="$def"
    fi
    if command -v ckbcomp >/dev/null 2>&1 && command -v loadkeys >/dev/null 2>&1; then
        ckbcomp -layout "$layout" 2>/dev/null | loadkeys -q 2>/dev/null || true
    fi
    export XKB_DEFAULT_LAYOUT="$layout"
    export AIUSB_KBD="$layout"
    log_action "keyboard layout=$layout"
}

# Text console font: very wide screens get the big Terminus font (any language);
# otherwise load the Uni2 Terminus font only for sk so the Slovak letters display.
tty_font_step() {
    local size="" cols="" font=""
    local re='^[0-9]+$'
    command -v setfont >/dev/null 2>&1 || return 0
    size="$(stty size </dev/tty 2>/dev/null || true)"
    cols="${size##* }"
    if [[ "$cols" =~ $re ]] && [ "$cols" -ge 160 ]; then
        font="$TTYFONT_WIDE"        # very wide screen: big font, any language
    elif [ "$LANG_CODE" = "sk" ]; then
        font="$TTYFONT_SMALL"       # normal screen: Latin-2 glyphs for Slovak
    else
        return 0
    fi
    [ -f "$font" ] || return 0
    setfont "$font" >/dev/null 2>&1 || true
    log_action "tty font set ($cols columns)"
}

# cage (wlroots) needs XDG_RUNTIME_DIR.
ensure_xdg_runtime() {
    if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
        XDG_RUNTIME_DIR="/run/user/0"
    fi
    export XDG_RUNTIME_DIR
    mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
    chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
}

# True when the graphical terminal may be attempted.
gui_available() {
    if [ "${AIUSB_INNER:-0}" = "1" ]; then
        return 1
    fi
    if grep -qs 'aiusb.nogui' /proc/cmdline; then
        return 1
    fi
    ls /dev/dri/card* >/dev/null 2>&1 || return 1
    command -v cage >/dev/null 2>&1 || return 1
    command -v foot >/dev/null 2>&1 || return 1
    return 0
}

# One cage attempt. $1 = forced WLR_RENDERER ("" for the default renderer).
# Records the exit code in GUI_RC and the runtime in seconds in GUI_DUR.
run_cage() {
    local renderer="$1"
    local t0=0
    t0=$SECONDS
    (
        export AIUSB_INNER=1
        # foot refuses to start without a UTF-8 locale.
        case "${LANG:-}" in
            *UTF-8*|*utf8*) ;;
            *) export LANG=C.UTF-8 ;;
        esac
        if [ -n "$renderer" ]; then
            export WLR_RENDERER="$renderer"
        fi
        exec cage -s -- foot --font=monospace:size=12 bash "$R/rescue-session.sh" --inner
    )
    GUI_RC=$?
    GUI_DUR=$((SECONDS - t0))
}

outer_stage() {
    require_root
    log_action "start (outer)"
    show_logo
    if [ ! -d "$USB/aiusb" ]; then
        echo "$(t RS_USB_NOT_MOUNTED "$USB")"
    fi
    language_step
    keyboard_step
    tty_font_step
    ensure_xdg_runtime
    if gui_available; then
        echo "$(t RS_GUI_STARTING)"
        run_cage ""
        log_action "gui default rc=$GUI_RC secs=$GUI_DUR"
        if [ "$GUI_RC" -ne 0 ] && [ "$GUI_DUR" -lt 10 ]; then
            echo "$(t RS_GUI_RETRY)"
            run_cage "pixman"
            log_action "gui pixman rc=$GUI_RC secs=$GUI_DUR"
        fi
        if [ "$GUI_RC" -ne 0 ] && [ "$GUI_DUR" -lt 10 ]; then
            echo "$(t RS_GUI_TEXT)"
            log_action "gui failed; inner on tty"
            bash "$R/rescue-session.sh" --inner
        fi
    else
        log_action "gui unavailable; inner on tty"
        bash "$R/rescue-session.sh" --inner
    fi
    step6_message
    exec bash -l
}

# ---------------------------------------------------------------------------
# inner stage (inside foot, or on the tty fallback)
# ---------------------------------------------------------------------------

# The stick's logo (aiusb/launcher/banner.txt); plain title if it is missing.
show_logo() {
    echo
    if [ -r "$BANNER" ]; then
        cat -- "$BANNER"
    else
        echo "$(t RS_LOGO_FALLBACK)"
    fi
}

banner() {
    show_logo
    echo "$(t RS_RESCUE_MODE)"
    echo
    echo "$(t RS_KBD_SHOW "${AIUSB_KBD:-us}")"
    echo "$(t RS_NET_INTERFACES)"
    ip -br addr 2>/dev/null || echo "$(t RS_NET_NO_INFO)"
    echo
}

network_online() {
    command -v curl >/dev/null 2>&1 || return 1
    curl -s -o /dev/null --max-time 6 "$NETURL"
}

# Returns 0 when online. Shows the offline menu until online or skipped.
network_step() {
    local choice=""
    while true; do
        if network_online; then
            echo "$(t RS_NET_ONLINE)"
            return 0
        fi
        echo "$(t RS_NET_OFFLINE)"
        echo
        echo "$(t RS_NET_MENU_1)"
        echo "$(t RS_NET_MENU_2)"
        echo "$(t RS_NET_MENU_3)"
        printf '%s' "$(t RS_NET_CHOICE)"
        if ! read -r choice; then
            echo
            echo "$(t RS_NET_CONTINUE_OFFLINE)"
            return 1
        fi
        case "$choice" in
            1)
                if command -v nmtui >/dev/null 2>&1; then
                    nmtui
                else
                    echo "$(t RS_NMTUI_MISSING)"
                fi
                ;;
            2|'')
                ;;
            3)
                echo "$(t RS_NET_OFFLINE_AGENTS)"
                return 1
                ;;
            *)
                echo "$(t RS_NET_INVALID)"
                ;;
        esac
    done
}

windows_disks_step() {
    if [ ! -f "$R/win-mount.sh" ]; then
        echo "$(t RS_WIN_MOUNT_MISSING)"
        return 0
    fi
    echo
    echo "$(t RS_WIN_DISKS)"
    bash "$R/win-mount.sh" --scan
    local ans=""
    printf '%s' "$(t RS_WIN_MOUNT_ASK)"
    if ! read -r ans; then
        ans=""
    fi
    case "${ans:-Y}" in
        [nN]*)
            log_action "win-mount --mount-all --ro"
            bash "$R/win-mount.sh" --mount-all --ro
            ;;
        *)
            log_action "win-mount --mount-all"
            bash "$R/win-mount.sh" --mount-all
            ;;
    esac
}

inner_stage() {
    require_root
    log_action "start (inner)"
    clear 2>/dev/null || true
    banner
    if network_step; then
        log_action "network online"
    else
        log_action "network offline"
    fi
    windows_disks_step
    if [ -f "$L" ]; then
        echo
        echo "$(t RS_OPENING_MENU)"
        log_action "launcher start"
        bash "$L" --mode rescue
        log_action "launcher exit rc=$?"
    else
        echo
        echo "$(t RS_LAUNCHER_MISSING "$L")"
        log_action "launcher missing"
    fi
    step6_message
    exec bash -l
}

# ---------------------------------------------------------------------------

main() {
    local arg="${1:-}"
    lang_init
    case "$arg" in
        --inner)
            inner_stage
            ;;
        "")
            if [ "${AIUSB_INNER:-0}" = "1" ]; then
                inner_stage
            else
                outer_stage
            fi
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 1
            ;;
    esac
}

main "$@"
