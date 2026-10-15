# Task: update the two launcher test suites for the new session switching

The launchers changed (see TASK-session-switching.md and the attached launcher.sh / launcher.ps1):
there is no "Another session may be open ... Continue? [y/N]" question any more. Update the two
attached test files. Keep every existing check that is still valid unchanged (same names, same
style, same helpers). Output both complete files.

## tests/test_launcher_sh.py (pexpect, runs launcher.sh against a copy of the stick)
- T4 (crash recovery): after the SIGKILL the next start no longer asks. Instead expect the line
  `was not closed; cleaning it up` and then, as today, `Found a session left open`, then the
  passphrase. Keep all T4 checks.
- Replace T5 by:
  - T5a "foreign lock": write `host=OTHER-PC os=windows pid=4242 started=2026-01-01T00:00:00Z`
    to `vault/session.lock`; a start must NOT stop: expect `was not closed; cleaning it up`, then the
    passphrase prompt, unlock, menu; quit. Check: exit 0 and lock removed afterwards.
  - T5b "second window on this PC": start launcher A, unlock, wait for the menu. Start launcher B:
    it must print `already open in another window on this PC` and exit with 0 by itself (no
    passphrase prompt). Then A still works: quit A from its menu (exit 0) and the lock is gone.
  - T5c "old multi-line lock": write the old format (one KEY=VALUE per line:
    `host=OTHER-PC`, `os=Linux`, `pid=1`, `started=2026-01-01T00:00:00Z`); start, expect
    `was not closed`, unlock, quit.
- New T9 "unfinished Windows session on the stick": create `<USB>/aiusb/session/home/claude/` with
  `.credentials.json` containing `WIN-SESSION` and `<USB>/aiusb/session/home/.aiusb-vault-id` equal
  to `vault/vault.id`. Start: expect `Saving logins from an unfinished Windows session`, unlock,
  menu. Check: `<USB>/aiusb/session` no longer exists, and the RAM session's
  `home/claude/.credentials.json` contains `WIN-SESSION` (it was saved into the vault and unlocked).
  Quit. Then T9b: same folder but with `.aiusb-vault-id` = `0000` (other vault): after the start the
  folder is gone and the RAM session's `.credentials.json` does NOT contain `MISMATCH-MARK` (write
  that text into the planted file). Quit.
- The final checks (T7) stay. Total runtime should stay reasonable (each start ~2-4 s).

## tests/test-launcher-ps1.ps1 (pwsh on Linux, loads launcher.ps1 functions)
Add checks (numbering continues: 18, 19, 20, 21). `$env:COMPUTERNAME` is empty on Linux: set it to
`TESTPC` at the start of these checks and restore it after.
- 18 Read-LockInfo: parses (a) the new one-line format with CRLF ending, (b) the old multi-line
  Linux format (`os=Linux`), (c) the old Windows format with local time and no `Z`; returns `$null`
  when there is no lock file.
- 19 Test-LockLive: false for a lock with this process's own `$PID`; for a running child
  (`Start-Process` of the same pwsh executable with `-NoProfile -Command Start-Sleep 30`,
  `-PassThru`) and host `TESTPC`, os `windows`, pid = child pid, started = child's start time in UTC
  -> true; same but started 1 hour off -> false; same but host `OTHER` -> false; same but os
  `linux` -> false. Kill the child at the end. (On Linux the pwsh process name is `pwsh`.)
- 20 Write-Lock + Resolve-Lock: Write-Lock writes exactly one line matching
  `^host=TESTPC os=windows pid=\d+ started=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\r?\n$`; with a foreign lock
  (`host=OTHER ...`) Resolve-Lock returns normally (does not exit); run it and then continue.
- 21 Clear-Session fallback + Remove-OldSessions: make the session folder undeletable for the
  current user (create `S/home/locked/` with a file inside, then `chmod 0555 S/home/locked` via
  `/bin/chmod` so the file cannot be removed); Clear-Session must leave `$script:S` absent and
  create exactly one `<USB>/aiusb/session-old-*` folder. Then `chmod 0755` it back and call
  Remove-OldSessions: no `session-old-*` folder remains.

Rules: same coding style as the files; the PowerShell test file runs only under pwsh 7, so PS7 syntax
is fine there; the Python file must keep working with the existing helpers (start, unlock,
quit_menu, check, MENU, PASS...). Output format: two sections, each starting with
`===== FILE: tests/test_launcher_sh.py =====` / `===== FILE: tests/test-launcher-ps1.ps1 =====`
followed by the complete raw file. Nothing else.
