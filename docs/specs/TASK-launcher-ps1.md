# Task: write `payload/aiusb/launcher/launcher.ps1`

The Windows launcher (mode `windows`). Implements ARCHITECTURE.md §5 completely
for Windows. Started by `Start AI Agent.cmd` as
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<USB>\aiusb\launcher\launcher.ps1"`.

Must run on Windows PowerShell 5.1 (see COMMON.md restrictions). ASCII only.
Use `Write-Host -ForegroundColor` for color (no ANSI escapes).

## Required functions (you may add helpers)
- `Write-Info`, `Write-Warn`, `Write-Err`, `Write-Log <text>` (append to `$USB\aiusb\logs\launcher.log`, `-Encoding ASCII`, ignore failures).
- `Get-Conf <key> <default>` (parse aiusb.conf as text).
- `Test-Admin`, `Invoke-Elevate` (§5.2; on UAC cancel continue non-elevated with a yellow warning).
- `Initialize-Session` (§5.3: `$S = "$USB\aiusb\session"`, `$H = "$S\home"`, `$T = "$S\tmp"`).
- `New-Vault`, `Unlock-Vault`, `Save-Vault`, `Clear-Session` (= wipe), `Set-VaultPassphrase`, `Reset-Vault` (§5.5).
  - Run age/tar with a helper `Invoke-Native <exe> <string[] args>` that uses the call operator `&`
    with an argument array, lets age talk to the console directly (no redirection of stdin/stdout/stderr
    for passphrase prompts), and checks `$LASTEXITCODE`.
  - tar: `"$env:SystemRoot\System32\tar.exe"`. If missing (Windows older than 1803), stop with a clear message.
- `Test-Lock`, `Write-Lock`, `Remove-Lock`, `Restore-StaleSession` (§5.6).
- `Initialize-Home` (skeleton + codex config.toml lines; write config.toml as UTF-8 without BOM using
  `[System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))`).
- `Get-Roots` (fixed drives + `$USB`), `Get-Context <agent>` and `Write-Context` (§5.10; generated
  section: `$env:COMPUTERNAME`, `(Get-CimInstance Win32_OperatingSystem).Caption` + Version,
  admin yes/no, drives with size/free/filesystem/label, paths).
- `Get-AgentStatus <agent>`.
- `ConvertTo-WinArg <string>`: quote one argument for the MSVCRT/CommandLineToArgvW rules:
  if it has no space/tab/quote and is not empty → as is; otherwise wrap in quotes, double every run
  of backslashes that precedes a quote or the closing quote, escape quotes as `\"`.
  Example: `C:\` must become `C:\` (no quotes needed) and `C:\My Dir\` must become `"C:\My Dir\\"`.
- `Start-Agent <claude|glm|codex|gemini|shell>`:
  - Build `System.Diagnostics.ProcessStartInfo`: `FileName` = exe, `Arguments` = joined
    `ConvertTo-WinArg` values, `UseShellExecute = $false`, `WorkingDirectory = "$USB\aiusb\workspace"`.
  - Environment: `$psi.EnvironmentVariables`: remove the §5.9 unset list, set the §5.9 set and the
    agent-specific vars. Secrets: read `H\secrets\*.key` with `[System.IO.File]::ReadAllText(...).Trim()`
    directly into `$psi.EnvironmentVariables[...]`; never into a long-lived variable.
  - `PATH` = `$S\bin;$USB\aiusb\bin\win-x64;$USB\aiusb\bin\win-x64\node;` + current PATH.
  - Start, then loop: `while (-not $p.WaitForExit(1500)) { unplug check (§5.7) }`. On unplug:
    `taskkill.exe /PID $p.Id /T /F`, `Write-Host 'USB removed - agents stopped. Nothing was left on this PC.'`, exit 2
    (no save/wipe possible; the stale session on the stick is recovered next time).
  - After exit: `Write-Log`, `Save-Vault`.
  - Codex: if `H\codex\auth.json` is missing, first run `codex.exe login` the same way (not `--device-auth`;
    a browser is available on Windows), then Save.
  - Gemini: FileName = `$USB\aiusb\bin\win-x64\node\node.exe`, first argument = the gemini.js path.
  - Shell: `powershell.exe -NoLogo -NoExit -Command "function global:prompt { '(ai-usb) ' + (Get-Location) + '> ' }"`.
- `Write-Wrappers`: create `$S\bin\claude.cmd`, `claude-glm.cmd`, `codex.cmd`, `gemini.cmd` for the
  shell option. They must not contain secrets: `claude-glm.cmd` reads the key at run time with
  `set /p ANTHROPIC_AUTH_TOKEN=<"%AIUSB_SESSION%\home\secrets\zai.key"`; `gemini.cmd` likewise
  for GEMINI_API_KEY when the file exists. Each wrapper sets the agent-specific vars and passes `%*`.
- `Show-KeysMenu`, `Show-MainMenu` (§5.11; omit N and W, rescue only).
- Main flow: elevate → session paths → `Test-Lock` → `Restore-StaleSession` → create or unlock →
  `Write-Lock` → `Initialize-Home` → `Write-Wrappers` → menu loop, all inside
  `try { ... } finally { if (Test-Path "$V\vault.id") { Save-Vault; Clear-Session; Remove-Lock } }`.
  (The finally block must not throw: wrap each step in its own try/catch.)

## Details that matter
- Hidden input: `$sec = Read-Host -AsSecureString -Prompt '...'`, convert with
  `[Runtime.InteropServices.Marshal]::SecureStringToBSTR` / `PtrToStringBSTR` / `ZeroFreeBSTR`, write with
  `[System.IO.File]::WriteAllText($file, $plain, (New-Object System.Text.UTF8Encoding($false)))`,
  then `$plain = $null`. Confirm by showing only the length.
- Autonomous mode flags exactly as §5.10 (Windows is never "root", so Claude uses `--dangerously-skip-permissions`).
- Set the window title: `$Host.UI.RawUI.WindowTitle = 'AI USB'`.
- Before unlocking print: `Keyboard layout tip: type the passphrase exactly as when you created it.`
- First-run passphrase advice: "Use letters, digits and spaces only, so it types the same on every keyboard layout."
- Guard wipes: only remove `$S` when it equals `Join-Path $USB 'aiusb\session'`.
- Pause with `Read-Host 'Press Enter to close'` before exiting on fatal errors so the window does not vanish.
- Roughly 500-800 lines, short comments at section boundaries.
