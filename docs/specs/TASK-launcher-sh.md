# Task: write `payload/aiusb/launcher/launcher.sh`

The Linux launcher for modes `linux` (normal Linux PC) and `rescue` (the rescue
live system). Implements ARCHITECTURE.md §5 completely for Linux.

## Invocation
`bash launcher.sh [--mode linux|rescue]` (default `linux`). Also reads env
`AIUSB_ELEVATED=1` (set by the sudo re-exec; do not ask again).
Require x86_64 (`uname -m`), bash >= 4.

## Required structure (functions; you may add helpers)
- `die`, `info`, `warn` (colors only when stdout is a tty and `TERM != dumb`).
- `log_event <text>` → append to `$USB/aiusb/logs/launcher.log` (mkdir -p; ignore failures).
- `conf_get <KEY> <default>` → parse `aiusb.conf` as text (first `=` splits; trim spaces; ignore `#` lines). Never `source`.
- `maybe_elevate` (§5.2, linux mode only).
- `setup_session_paths` (§5.3 table; tmpfs check; `umask 077`).
- `prepare_bins` (§5.8): sets globals `CLAUDE_BIN CODEX_BIN AGE_BIN AGEKEYGEN_BIN NODE_BIN GEMINI_JS`.
  Test runnability with `"$bin" --version >/dev/null 2>&1` for claude/codex/age and
  `"$NODE_BIN" --version`; if a test fails, copy to `$S/bin-cache/` and chmod 755.
- `write_wrappers`: create `$S/bin/{claude,claude-glm,codex,gemini}` bash wrappers
  (mode 700) that exec the right binary with the same env/args logic as the menu
  (they may source a generated `$S/agent-env.sh` that contains ONLY non-secret
  exports; secrets are read from `H/secrets/*.key` at exec time inside the wrapper).
- `vault_create`, `vault_unlock`, `vault_save`, `session_wipe`, `vault_change_passphrase`, `vault_reset` (§5.5 exactly).
- `lock_check`, `lock_write`, `lock_clear`, `stale_recover` (§5.6).
- `watcher_start`, `watcher_stop` (§5.7): background subshell; stores its pid in a global; reads `$S/agent.pgid`.
- `ensure_home_skeleton` (dirs of §5.4 + codex config.toml lines: if a line with the key exists replace it, else append).
- `build_context <agent>` (§5.10 context; generated section uses `hostname`, `/etc/os-release` PRETTY_NAME, `id -u`, `lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS` (fallback `df -h`), and in rescue mode the output of `bash "$USB/aiusb/rescue/win-mount.sh" --status`).
- `agent_status_line <agent>` for the menu.
- `run_agent <claude|glm|codex|gemini|shell>`:
  - computes args per §5.10 (as a bash array),
  - runs in a subshell: `unset` the §5.9 list, `export` the §5.9 set + agent vars (secrets read with `$(<file)` inside the subshell only),
    `cd "$USB/aiusb/workspace"`, then run the agent in the FOREGROUND of the terminal.
    The agent must keep the controlling terminal (interactive TUI), so do NOT use `setsid`
    (it drops the controlling tty). Instead enable job control in the launcher (`set -m`), so each
    foreground job gets its own process group and the terminal is handed to it, and start the agent
    as `bash -c 'echo $$ > "$1"; shift; exec "$@"' _ "$S/agent.pgid" "$exe" "${args[@]}"`, with job
    control on, that bash's `$$` is the job's pgid, which the watcher (§5.7) kills on unplug.
    Note §5.7's "started with setsid" is superseded by this paragraph.
  - after it exits: `log_event`, `vault_save`, return to menu.
- `keys_menu` (§5.11 submenu), `main_menu`, `cleanup` (trap EXIT INT TERM HUP: stop watcher; if `$V/vault.id` readable → `vault_save`; `session_wipe`; `lock_clear`).
- Rescue-only menu items: `N` → `nmtui`; `W` → `bash "$USB/aiusb/rescue/win-mount.sh" --mount-all` (then `--status`).

## Details that matter
- Autonomous flag and root: `id -u` = 0 → Claude uses `--permission-mode acceptEdits` instead of `--dangerously-skip-permissions`.
- Codex login: use `--device-auth` when mode is rescue OR when running as root.
- Gemini command: `"$NODE_BIN" "$GEMINI_JS" ...`.
- Shell option: `bash --noprofile --norc -i` with PS1 set to `(ai-usb) \w \$ ` and the full env exported (same subshell technique).
- Hidden key input: `read -rs -p 'Paste the key, then press Enter: ' k; printf '%s' "$k" > file; unset k; chmod 600 file` and confirm by showing only the length.
- Before unlocking, print one line: `Keyboard layout tip: type the passphrase exactly as when you created it.`
- First-run passphrase advice (vault_create): "Use letters, digits and spaces only, so it types the same on every keyboard layout."
- Never `rm -rf` a variable that could be empty or `/`: validate that `S` ends with `aiusb-session` or `aiusb-session-<uid>`.
- Exit codes: 0 normal quit; 1 fatal error.
- Keep it readable: roughly 500-800 lines, with short comments at section boundaries.
