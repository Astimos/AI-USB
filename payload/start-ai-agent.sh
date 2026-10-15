#!/usr/bin/env bash
# AI USB - Linux launcher. Run: bash start-ai-agent.sh
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
launcher="$here/aiusb/launcher/launcher.sh"

# Started from a file manager (no terminal): reopen inside a terminal window.
if [[ ! -t 0 || ! -t 1 ]]; then
    for term in x-terminal-emulator konsole gnome-terminal kgx ptyxis xfce4-terminal kitty alacritty foot xterm; do
        command -v "$term" >/dev/null 2>&1 || continue
        case "$term" in
            gnome-terminal|kgx|ptyxis) exec "$term" -- bash "$launcher" --mode linux "$@" ;;
            *) exec "$term" -e bash "$launcher" --mode linux "$@" ;;
        esac
    done
fi
exec bash "$launcher" --mode linux "$@"
