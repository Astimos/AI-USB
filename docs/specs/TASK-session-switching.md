# Task: clean session on every plug-in, across operating systems

The user moves the stick between Linux and Windows PCs (often by just unplugging). Today a start
after an unplug or crash asks "Another session may be open or did not close cleanly. Continue?
[y/N]" (default No = the launcher closes), and a Windows session folder left on the stick is only
cleaned by the Windows launcher. New rule: **every start gives a clean new session, on any OS,
without questions.** Leftovers of the previous session are handled automatically: its newer logins
are saved into the vault first (they may be newer than the vault), then it is wiped.

The ONLY case that still stops a start: a launcher of the stick is really running right now in
another window on the SAME PC (two launchers would share files). That is detected, never asked.

You write replacement / new functions for both launchers (attached: launcher.sh, launcher.ps1,
ARCHITECTURE.md, COMMON.md). Keep their style, helpers and variable names; use only helpers that
exist in the attached files.

## Common lock format (both launchers write the same)
`$V/session.lock` = ONE line, then a newline:
`host=<hostname> os=<windows|linux|rescue> pid=<launcher pid> started=<UTC yyyy-MM-ddTHH:mm:ssZ>`
Readers must also accept the older formats: the same KEY=VALUE pairs one per line (old Linux
launcher, `os=Linux`), and `started=` in local time without `Z` (old Windows launcher). Parse by
splitting the whole text on whitespace and taking tokens of the form key=value (first `=` splits).

"Live lock" = all of: lock host equals this machine's hostname (case-insensitive), lock os belongs
to this launcher (Windows: `windows`; Linux launcher: `linux` or `rescue`, case-insensitive, so
`Linux` from the old format counts), the pid is a running process that is a launcher:
- Linux: `/proc/<pid>/cmdline` exists and contains `launcher.sh` (read it with
  `tr '\0' ' ' < /proc/<pid>/cmdline`), and pid != `$$`.
- Windows: `Get-Process -Id <pid>` exists, its `ProcessName` is `powershell` or `pwsh`, pid !=
  `$PID`, and when `started` parses as a date, the process `StartTime` (converted to UTC) is within
  120 seconds of it (protects against pid reuse). If `started` does not parse, the name check is
  enough.

## Part A: bash, for launcher.sh. Output file `launcher-session.sh` with exactly these functions
- `lock_read`: reads `$V/session.lock` into globals `LOCK_HOST LOCK_OS LOCK_PID LOCK_STARTED`
  (empty when missing). Returns 1 if there is no lock file.
- `lock_is_live`: returns 0 for a live lock per the rules above, else 1.
- `lock_check` (replaces the old one): no lock -> return 0. Live lock -> print (via `warn`)
  `AISTiUSB is already open in another window on this PC (pid N). Use that window, or close it
  first.` then `exit 0`. Otherwise -> `info "The last session (on <host>, <os>) was not closed;
  cleaning it up."` and return 0 (no question, no deletion here; lock_write replaces the file).
- `lock_write` (replaces the old one): writes the common one-line format with `os=$MODE`,
  `host=$(host_name)`, `pid=$$`, UTC `started`; sets `LOCK_OWNED=1`; ignore write errors.
- `recover_stick_session`: the Windows launcher keeps its decrypted session ON the stick at
  `$USB/aiusb/session` (home in `$USB/aiusb/session/home`). If that folder exists:
  - if `home/.aiusb-vault-id` exists and equals `$V/vault.id` (first line, trimmed): print
    `info "Saving logins from an unfinished Windows session on the stick."`, then save that home
    into the vault by temporarily pointing the global `H` at it and calling the existing
    `vault_save` (restore `H` afterwards in all cases);
  - then delete `$USB/aiusb/session` with `rm -rf --` (guard: the path must end with
    `/aiusb/session`); if it still exists afterwards, rename it to
    `$USB/aiusb/session-old-<UTC yyyymmdd-HHMMSS>` (mv) so the next Windows start gets a fresh one;
  - finally try `rm -rf --` on every `$USB/aiusb/session-old-*` directory (silently, ignore errors).
  Requires `AGE_BIN` (prepare_bins ran before). Never print secrets.

## Part B: PowerShell 5.1, for launcher.ps1. Output file `launcher-session.ps1` with exactly these functions
(PowerShell 5.1 rules of COMMON.md: no `??`, `?.`, ternary, `&&`, `||`, no PS7-only cmdlets; it runs
under `Set-StrictMode -Version 2.0` and `$ErrorActionPreference = 'Stop'`.)
- `Read-LockInfo`: returns a hashtable with keys host, os, pid, started (strings, empty when
  missing), or `$null` when there is no lock file.
- `Test-LockLive`: `param($Info)` returns `$true` for a live lock per the rules above.
- `Resolve-Lock` (replaces the "Continue? [y/N]" block in the main flow): no lock -> return.
  Live -> `Write-Warn 'AISTiUSB is already open in another window on this PC. Use that window, or
  close it first.'`, `Read-Host 'Press Enter to close' | Out-Null`, `exit 0`. Otherwise ->
  `Write-Info ('The last session (on {0}, {1}) was not closed; cleaning it up.' -f host, os)`.
- `Write-Lock` (replaces the old one): the common one-line format, `os=windows`,
  `host=$env:COMPUTERNAME`, `pid=$PID`, `started` = `(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')`
  via `[System.IO.File]::WriteAllText(...)` (ASCII, trailing newline); sets `$script:OwnLock = $true`.
- `Move-SessionAside`: renames `$script:S` to `<USB>\aiusb\session-old-<UTC yyyyMMdd-HHmmss>`
  (`[System.IO.Directory]::Move`); returns `$true` on success. Used when the session folder cannot
  be deleted, so the next steps get a fresh, empty `$script:S`.
- `Clear-Session` (replaces the old one): same guard as today (`$script:S` must equal
  `Join-Path $script:USB 'aiusb\session'`); `Remove-Tree $script:S`; if that fails,
  `Move-SessionAside`; only if that also fails print the existing warning.
- `Remove-OldSessions`: try `Remove-Tree` on every directory matching `<USB>\aiusb\session-old-*`;
  silent, never throws.

Do not change any other function. Output format: the two files as two separate sections, each
starting with a line `===== FILE: launcher-session.sh =====` / `===== FILE: launcher-session.ps1 =====`
followed by the raw code (no markdown fences). Nothing else.
