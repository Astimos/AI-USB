# Task: language switch (English / Slovak) and built-in explanations

The user wants (1) a language switch at the start of every launcher, and (2) explanations of how
the tool works and how to operate it. All user-facing text moves into language files; the scripts
stay pure ASCII (Windows PowerShell 5.1 reads BOM-less scripts as ANSI).

## Language files (shared by launcher.sh, launcher.ps1, rescue-session.sh)
- `$USB/aiusb/lang/en.txt` (master) and `$USB/aiusb/lang/sk.txt`. UTF-8 without BOM.
- Format: one `KEY=text` per line; first `=` splits; lines starting with `#` and empty lines are
  ignored. Keys: `[A-Z0-9_]+`. Placeholders `{0}`, `{1}`, ... (same in all scripts). The two
  characters backslash + `n` inside a text mean a line break. No other escapes.
- Lookup: English is always loaded first, the selected language overlays it, so a key missing in
  sk.txt shows English; a key missing everywhere shows the key itself (never crash).
- Key prefixes: `COMMON_` for the shared keys listed below (both launchers use them; do not invent
  other COMMON_ keys), `SH_` for launcher.sh, `PS_` for launcher.ps1, `RS_` for rescue-session.sh.
- The English text of every message that exists today must stay EXACTLY as it is now (the test
  suites match it). New texts may be added.

## Selected language
- `$USB/aiusb/lang/current`: one line with the code of the last chosen language (`en` or `sk`);
  default `en` when missing or invalid. Write errors are ignored.
- Env `AIUSB_LANG` (Linux) / script parameter `-Lang` (Windows): when it holds a valid code, use it
  and do NOT ask (used for the sudo re-exec, the UAC relaunch, the rescue chain and tests).
- Otherwise ask at the very beginning, right after the banner and before anything else:
  `Language / Jazyk:  1) English   2) Slovencina   [Enter = <name of current>]: `
  (this prompt line is a fixed ASCII string in the script, not from the files; the names come from
  the `COMMON_LANG_NAME` key of each file, but the prompt itself prints ASCII `Slovencina` so it
  renders on every console). Accept `1`/`2`/`en`/`sk`/empty; anything else = keep current. Save the
  choice to `lang/current`.
- Valid codes: the files present in `lang/` with a matching `COMMON_LANG_NAME`; at least `en`.
- Main menu gets two items (both launchers): `L) Language / Jazyk` (asks again, reloads texts,
  saves the choice, re-draws) and `H) How it works` (prints COMMON_HELP_TEXT, then waits for Enter).
- Linux elevation: `exec sudo env AIUSB_ELEVATED=1 AIUSB_LANG=<code> bash ...`.
  Windows elevation: the relaunch passes `-Lang <code>` after `-File <script>`; launcher.ps1 starts
  with `param([string]$Lang = '')` (only comments may precede it).
- The rescue session asks first (outer stage, before the keyboard layout question) and exports
  `AIUSB_LANG` so `--inner` and the launcher do not ask again. On the Linux text console (not inside
  foot), when the language is `sk`, load `/usr/share/consolefonts/Uni2-TerminusBold28x14.psf.gz`
  (wide screens, >= 160 columns) or `/usr/share/consolefonts/Uni2-Terminus16.psf.gz` so Slovak
  letters display (`setfont`, ignore failure); this replaces the current Uni3 font choice.
- Agents: the generated `## This machine (generated)` section (English, agents read it) gets one
  more line: `- User language: English (en). Talk to the user in English.` or
  `- User language: Slovak (sk). Talk to the user in Slovak.`

## Explanations
- First run (no vault yet), before the passphrase is created: print COMMON_FIRST_RUN, then the
  existing passphrase advice.
- `H) How it works` in the main menu: COMMON_HELP_TEXT.
- Before the passphrase prompt on unlock, keep the existing keyboard tip line.

## COMMON keys (English master text; use exactly these keys)
```
COMMON_LANG_NAME=English
COMMON_MENU_1=1) Claude Code
COMMON_MENU_2=2) Claude Code on GLM
COMMON_MENU_3=3) Codex (OpenAI)
COMMON_MENU_4=4) Gemini (Google)
COMMON_MENU_5=5) Shell with the agents on PATH
COMMON_MENU_A_OFF=A) Autonomous mode: OFF
COMMON_MENU_A_ON=A) Autonomous mode: ON
COMMON_MENU_K=K) Keys & sign-in
COMMON_MENU_N=N) Network setup (nmtui)
COMMON_MENU_W=W) Windows disks (mount/unlock)
COMMON_MENU_L=L) Language / Jazyk
COMMON_MENU_H=H) How it works
COMMON_MENU_Q=Q) Save, lock and quit
COMMON_ADMIN=admin
COMMON_YES=yes
COMMON_NO=NO
COMMON_STATUS_SIGNED_IN=signed in
COMMON_STATUS_NOT_SIGNED_IN=not signed in
COMMON_STATUS_KEY_SAVED=key saved
COMMON_STATUS_NO_KEY=no key
COMMON_STATUS_API_KEY=API key
COMMON_STATUS_GOOGLE_LOGIN=Google login
COMMON_KEYS_TITLE=Keys & sign-in
COMMON_KEYS_NOTE=Note: Google sign-in is tied to each computer's name; an API key works on every PC.
COMMON_KEYS_1=1) Set z.ai key
COMMON_KEYS_2=2) Set Gemini API key
COMMON_KEYS_3=3) Sign in to Codex
COMMON_KEYS_4=4) Sign out of an agent
COMMON_KEYS_5=5) Change passphrase
COMMON_KEYS_6=6) Reset vault (forget all logins)
COMMON_KEYS_B=B) Back
COMMON_PRESS_ENTER=Press Enter to continue
COMMON_FIRST_RUN=Welcome to AISTiUSB.\nThis stick carries AI assistants that can inspect and repair this computer.\nFirst you choose a passphrase for the stick. It protects every sign-in stored on it.\nIt cannot be recovered: if you forget it, you reset the vault and sign in again.\nAfter that, sign in to the assistants you want to use: option 1 starts Claude's own login,\nK opens the other sign-ins (z.ai key, Gemini key, Codex). Press H in the menu for help.
COMMON_HELP_TEXT=How AISTiUSB works\n\n- The stick carries AI assistants: Claude Code, Claude Code on GLM (z.ai), Codex (OpenAI)\n  and Gemini (Google). They can inspect and repair this computer.\n- Your sign-ins are stored only on the stick, in an encrypted vault opened by your passphrase.\n- While a session is open they are unlocked temporarily: in memory on Linux, in a session\n  folder on the stick on Windows. Nothing secret is written to this computer.\n- Pick an assistant with its number and describe the problem in your own words. It explains\n  what it found and asks before it changes anything.\n- A switches Autonomous mode: the assistants then act without asking. Keep it OFF unless\n  you are watching.\n- K opens Keys & sign-in: add or remove sign-ins, change the passphrase, reset the vault.\n- 5 opens a shell where you can run claude, claude-glm, codex and gemini yourself.\n- Q saves, locks and quits. Closing the window or pulling the stick out also ends the\n  session; the next start cleans up automatically, on any computer.\n- Reports and backups stay on the stick in aiusb/workspace and aiusb/backups.
```

## What each worker delivers
For ONE script (named in the prompt): the complete rewritten script, plus the list of the
non-COMMON keys it uses with their English text. Implement the helpers in that script:
- bash: `declare -A TXT=()`, `lang_load <code>` (en first, then overlay), `t <KEY> [args...]`
  prints the text with `{i}` replaced (use quoted replacement `${s//"{$i}"/"$a"}`; bash 5.2's
  patsub_replacement would otherwise treat `&` in args specially) and `\n` turned into newlines;
  no trailing newline. Usage: `info "$(t SH_SOMETHING "$x")"`. Read files with
  `while IFS= read -r line || [[ -n "$line" ]]` and strip a trailing `\r`.
- PowerShell 5.1: `$script:Txt = @{}`, `Import-Lang <code>`, `T <Key> [args...]` (use
  `[Parameter(ValueFromRemainingArguments=$true)]`), read with
  `[System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)`; replace `{i}` with
  `.Replace()` (never `-f`, texts may contain braces); return the string.
Keep all logic, all non-text code and all comments unchanged; only route user-facing text through
the helpers and add the features above. Bash must pass `shellcheck -S warning`; PowerShell must be
PS 5.1 compatible (COMMON.md); scripts ASCII only.

Output format: two sections, `===== FILE: <path of the script> =====` with the complete script,
then `===== FILE: lang-keys-<SH|PS|RS>.txt =====` with the `KEY=English text` lines it uses
(non-COMMON keys only). Nothing else.
