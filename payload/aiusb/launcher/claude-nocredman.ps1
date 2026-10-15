# AI-USB: keep Claude Code's Windows login in <config dir>\.credentials.json (inside the vault).
# Claude Code picks the Windows Credential Manager when the server flag tengu_windows_credman,
# cached in .claude.json, is true; that would leave the login on the host PC. This resets the
# cached flag to false before every start. Usage: claude-nocredman.ps1 <CLAUDE_CONFIG_DIR>
# Windows PowerShell 5.1, ASCII only. Never fails the caller.
param([string]$ConfigDir)

if ([string]::IsNullOrEmpty($ConfigDir)) { exit 0 }
foreach ($name in @('.claude.json', '.config.json')) {
    $file = Join-Path $ConfigDir $name
    try {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        $text = [System.IO.File]::ReadAllText($file)
        $new = $text -replace '("tengu_windows_credman"\s*:\s*)true', '${1}false'
        if ($new -ne $text) {
            [System.IO.File]::WriteAllText($file, $new, (New-Object System.Text.UTF8Encoding($false)))
        }
    } catch { }
}
exit 0
