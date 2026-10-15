# Task: write `tests/test-launcher-ps1.ps1` (run the Windows launcher's functions on Linux)

`payload/aiusb/launcher/launcher.ps1` (attached) targets Windows PowerShell 5.1 and cannot be
started on Linux as a whole. Parse checks already exist; what is missing is EXECUTING its functions,
because a runtime bug (`$psi.EnvironmentVariables.Contains()`: StringDictionary only has
`ContainsKey`) reached the user. Write a test script that loads the launcher's functions into
PowerShell 7 (`pwsh`) on Linux and exercises them against a throwaway fake stick.

Run from the repo root: `build/tools/pwsh/pwsh -NoProfile -File tests/test-launcher-ps1.ps1`
Exit code 0 when every check passes, 1 otherwise. Print one line per check: `PASS <name>` or
`FAIL <name> - <detail>`, then a summary `N passed, M failed`.

## Facts about the environment (verified)
- pwsh 7 on Linux: `Join-Path '/tmp/x' 'aiusb\vault'` returns `/tmp/x/aiusb/vault`
  (backslashes are normalised by the FileSystem provider), `Split-Path -Parent` likewise.
- `Get-CimInstance` does not exist on Linux (CommandNotFoundException). The launcher catches it and
  falls back to `[System.IO.DriveInfo]`; that fallback is part of what you test.
- `$env:SystemRoot` is empty on Linux.
- Real binaries for tests: age at `build/payload/aiusb/bin/linux-x64/age` and
  `build/payload/aiusb/bin/linux-x64/age-keygen`; use `/usr/bin/bsdtar` as `$script:TAREXE`
  (it is libarchive, the same tar implementation as Windows' tar.exe).
- age accepts an UNENCRYPTED identity file with `-i`, so for tests put a plain `age-keygen` identity
  at `vault/identity.age` (then `Unlock-Vault` does not prompt). Never test New-Vault or
  Set-VaultPassphrase (they need an interactive passphrase).

## How to load the functions (do not run the launcher's main flow)
Parse the file with `[System.Management.Automation.Language.Parser]::ParseFile(...)`, collect every
`FunctionDefinitionAst` (`$ast.FindAll({ $args[0] -is [...FunctionDefinitionAst] }, $true)`) and
define each one by `. ([scriptblock]::Create($fn.Extent.Text))` at the script's top level so they
land in script scope. Do NOT execute any other top-level statement of launcher.ps1. Then set the
`$script:` variables the functions use yourself (names exactly as in launcher.ps1): `USB`, `CONF`,
`V`, `LOGDIR`, `LOGFILE`, `CTXDIR`, `WORKSPACE`, `BINWIN`, `NODEBIN`, `AGE`, `AGEKEYGEN`, `TAREXE`,
`UNSET_ENV`, `GLM_MODEL_MAP`, `VAULT_EXCLUDES` (take `UNSET_ENV`, `GLM_MODEL_MAP` and
`VAULT_EXCLUDES` from the launcher by evaluating ONLY those top-level assignment statements found
in the AST), `S`, `H`, `T`, `Admin`, `Autonomous`, `SessionReady`, `OwnLock`, `OwnSession`,
`CtrlGuard = $false`. Note: functions in launcher.ps1 use `$PSScriptRoot` to find
`claude-nocredman.ps1`; when defined from the test, `$PSScriptRoot` is the tests folder, so copy
`payload/aiusb/launcher/claude-nocredman.ps1` next to where it is looked up OR test that helper by
calling it directly (preferred) and make sure Start-Agent is not needed for it.

Fake stick: a fresh temp dir (`[System.IO.Path]::GetTempPath()` + random name) containing
`aiusb/aiusb.conf` (copy the repo's `payload/aiusb/aiusb.conf`), `aiusb/vault/`, `aiusb/context/`
(copy the repo's context files), `aiusb/workspace/`, `aiusb/logs/`. Remove it at the end
(try/finally). Never touch `build/payload` or anything outside the temp dir and the repo's tests.

## Checks (all required)
1. Get-Conf: returns `GLM_BASE_URL` from the conf, the default for a missing key, ignores `#` lines,
   keeps text after the first `=` (write a conf line `X_TEST=a=b` and expect `a=b`).
2. ConvertTo-WinArg: `C:\` -> `C:\`, `C:\My Dir\` -> `"C:\My Dir\\"`, empty -> `""`,
   `say "hi"` -> `"say \"hi\""`.
3. Set-CommonEnv: before building the ProcessStartInfo set these in the current process:
   `ANTHROPIC_API_KEY`, `ANTHROPIC_MODEL`, `CLAUDE_CODE_USE_BEDROCK`, `CLAUDECODE`, `OPENAI_API_KEY`,
   `CODEX_HOME`, `GEMINI_API_KEY`, `GOOGLE_CLOUD_PROJECT` (any dummy values) and a harmless
   `AIUSB_KEEP_ME=1`. Create `New-Object System.Diagnostics.ProcessStartInfo`, call
   `Set-CommonEnv $psi`. Expect: none of the 8 host variables remain (use `.ContainsKey`), the
   harmless one remains, and these are set: `AIUSB_ROOT`, `AIUSB_MODE`=`windows`, `AIUSB_SESSION`,
   `TMPDIR`/`TMP`/`TEMP` = `$script:T`, `DISABLE_AUTOUPDATER`=`1`, `ANTHROPIC_CONFIG_DIR`, `CODEX_HOME`,
   `GEMINI_CLI_HOME`, `GEMINI_FORCE_FILE_STORAGE`=`true`,
   `CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL`=`1`; `Path` starts with
   `$script:S` + `\bin;` (string compare, Windows separators are expected in that value).
   Remove the dummy variables from the process afterwards.
4. Initialize-Session + Initialize-Home: directories `claude claude-glm anthropic codex gemini
   secrets` exist under H; `.aiusb-vault-id` equals vault.id. codex `config.toml` case: pre-write
   a file whose lines are `cli_auth_credentials_store = "keyring"`, `[projects."/x"]`,
   `trust_level = "trusted"`; after Initialize-Home the first two lines must be
   `cli_auth_credentials_store = "file"` and `mcp_oauth_credentials_store = "file"`, the keyring line
   is gone, the `[projects."/x"]` table and its `trust_level` line are still there after them, and
   the file has no UTF-8 BOM.
5. Write-Wrappers: `claude.cmd claude-glm.cmd codex.cmd gemini.cmd` exist in `S\bin`; first write a
   dummy key `ZAI-SECRET-123` to `H\secrets\zai.key` and `GEM-SECRET-456` to `H\secrets\gemini.key`
   and assert neither string appears in any wrapper; wrappers use CRLF line endings; `claude.cmd`
   and `claude-glm.cmd` contain `claude-nocredman.ps1` and `CLAUDE_CODE_USE_POWERSHELL_TOOL=1`.
6. Get-Context 'claude' does not throw on Linux, contains `## This machine (generated)` and the
   contents of `context/host-windows.md` (check its first line); Write-Context 'codex' writes
   `H\codex\AGENTS.md`.
7. Vault round trip: put a plain identity at `vault/identity.age` and its public key in
   `vault/recipient.txt`, write `H\claude\.credentials.json` = `{"t":1}`,
   `H\claude\cache\big.bin` (1 MB), `H\claude\projects\p\s.jsonl`, `H\codex\sessions\s.jsonl`,
   `H\codex\auth.json`, `H\gemini\.gemini\tmp\x.log`. Call Save-Vault twice: expect
   `home.tar.age` and `home.tar.age.bak` exist, no `home.tar.age.new` and no `S\home.tar` left.
   Decrypt with age + `bsdtar -tf` and assert the listing contains `./claude/.credentials.json` and
   `./codex/auth.json` but nothing under `./claude/cache`, `./claude/projects`, `./codex/sessions`,
   `./gemini/.gemini/tmp`. Then delete everything under H, call Unlock-Vault: expect `$true`,
   `.credentials.json` content restored, `claude\cache` absent, `S\home.tar` removed.
8. Restore-StaleSession: (a) with `H\.aiusb-vault-id` equal to vault.id and a new file
   `H\claude\marker.txt`: after the call the vault was re-saved (decrypted listing contains
   `./claude/marker.txt`) and S exists again but `H\claude\marker.txt` does not (session wiped and
   re-created); (b) with S containing junk but NO `.aiusb-vault-id`: the junk is gone afterwards.
9. Clear-Session guard: with `$script:S` set to a different existing temp folder, Clear-Session
   must not delete it. With the real S, it is deleted.
10. claude-nocredman.ps1 (call `& <repo>/payload/aiusb/launcher/claude-nocredman.ps1 <dir>`):
   a `.claude.json` with `{"a":1,"cachedGrowthBookFeatures":{"tengu_windows_credman":true,"x":2}}`
   becomes the same text with `false`; a `.config.json` with `"tengu_windows_credman" : true`
   (spaces) is fixed too; a file without the key is byte-identical afterwards; a missing dir
   does not throw; the result has no BOM.
11. Invoke-AgentProcess returns the child's exit code: run `/bin/sh -c "exit 3"` through a
   ProcessStartInfo (`UseShellExecute=$false`) with vault.id present -> 3.
12. Unplug watcher: in a CHILD process (`build/tools/pwsh/pwsh -NoProfile -NonInteractive -File
   <temp>.ps1`) load the same functions and variables, then call Invoke-AgentProcess on
   `/bin/sleep 30`. From the parent, after the child has started (wait ~2 s), rename `vault.id`
   away. Expect the child to exit with code 2 within 15 s and the `sleep` to be gone. Rename
   vault.id back. (`taskkill.exe` does not exist on Linux; the launcher also calls `$proc.Kill()`;
   the test must still pass.)
13. Write-Log appends a line containing ` windows ` and the event text to `logs/launcher.log`.

Write clean, commented PowerShell 7 code (this test only runs under pwsh 7, so PS7 syntax is
allowed here). ASCII only. Output ONLY the raw file contents, no fences, no commentary.
