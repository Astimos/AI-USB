# tests/test-launcher-ps1.ps1 - run the Windows launcher's functions on Linux (pwsh 7).
# Usage from the repo root: build/tools/pwsh/pwsh -NoProfile -File tests/test-launcher-ps1.ps1
# Loads every function of payload/aiusb/launcher/launcher.ps1 (never its main flow) and runs
# them against a throwaway fake USB stick in a temp dir. Prints one PASS/FAIL line per check,
# then a summary. Exit code 0 = all checks passed, 1 otherwise. ASCII only.

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------- result bookkeeping
$script:Passed = 0
$script:Failed = 0

function Add-Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) {
        $script:Passed++
        Write-Host ('PASS ' + $Name)
    } else {
        $script:Failed++
        Write-Host ('FAIL ' + $Name + ' - ' + $Detail)
    }
}

# Decrypt the current home.tar.age with the test identity and return its tar listing.
function Get-VaultListing {
    $dec = Join-Path $script:TmpRoot 'inspect.tar'
    if (Test-Path -LiteralPath $dec) { Remove-Item -LiteralPath $dec -Force }
    & $script:AGE -d -i (Join-Path $script:V 'identity.age') -o $dec (Join-Path $script:V 'home.tar.age') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ('age decrypt failed, rc=' + $LASTEXITCODE) }
    $entries = @(& $script:TAREXE -tf $dec)
    if ($LASTEXITCODE -ne 0) { throw ('bsdtar list failed, rc=' + $LASTEXITCODE) }
    Remove-Item -LiteralPath $dec -Force
    return $entries
}

# ---------------------------------------------------------------- locate inputs
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$launcherPath = Join-Path $repoRoot 'payload/aiusb/launcher/launcher.ps1'
$nocredmanPath = Join-Path $repoRoot 'payload/aiusb/launcher/claude-nocredman.ps1'
$ageExe = Join-Path $repoRoot 'build/payload/aiusb/bin/linux-x64/age'
$ageKeygenExe = Join-Path $repoRoot 'build/payload/aiusb/bin/linux-x64/age-keygen'
$tarExe = (Join-Path $repoRoot 'tests/wintar-shim.sh')   # behaves like Windows' tar.exe (no -s)
foreach ($p in @($launcherPath, $nocredmanPath, $ageExe, $ageKeygenExe, $tarExe)) {
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Host ('FAIL 00 prerequisites - required file missing: ' + $p)
        exit 1
    }
}

# ---------------------------------------------------------------- load the launcher's functions (no main flow)
$tokens = $null
$parseErrors = $null
$launcherAst = [System.Management.Automation.Language.Parser]::ParseFile($launcherPath, [ref]$tokens, [ref]$parseErrors)
if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
    Write-Host ('FAIL 00 prerequisites - launcher.ps1 does not parse: ' + $parseErrors[0].Message)
    exit 1
}
# define every function of launcher.ps1 in this script's scope; NO other top-level statement runs
foreach ($fn in $launcherAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}
# evaluate ONLY the list/map assignments the functions need
$wantedLists = @('$script:UNSET_ENV', '$script:GLM_MODEL_MAP', '$script:VAULT_EXCLUDES', '$script:HIST_GROUPS',
    '$script:HIST_PATHS', '$script:CLAUDE_PROJECT_DIR_NAME', '$script:AGY_SSH_MARK')
foreach ($stmt in $launcherAst.EndBlock.Statements) {
    if ($stmt -is [System.Management.Automation.Language.AssignmentStatementAst]) {
        $n = $stmt.Left.Extent.Text
        if ($wantedLists -contains $n) {
            . ([scriptblock]::Create($stmt.Extent.Text))
        }
    }
}
# language texts (the functions call T): English from the repo's language files
$script:LangDir = Join-Path $repoRoot 'payload/aiusb/lang'
$script:UiLang = 'en'
Import-Lang 'en'
if ($null -eq (Get-Command -Name 'Get-Conf' -ErrorAction SilentlyContinue)) {
    Write-Host 'FAIL 00 prerequisites - launcher functions were not loaded'
    exit 1
}

# ---------------------------------------------------------------- fake stick + environment
$script:TmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('aiusb-ps1test-' + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $script:TmpRoot | Out-Null

# Remove-Tree and Wait-AgentProcess build Windows tool paths with Join-Path $env:SystemRoot ...;
# an empty SystemRoot makes that Join-Path throw on Linux, so point it at a real directory.
# The constructed paths then simply do not exist, which the launcher's try/catch blocks handle;
# Directory.Delete() and $proc.Kill() do the real work here.
$savedSystemRoot = [string]$env:SystemRoot
$env:SystemRoot = '/tmp'

$pwshExe = (Get-Process -Id $PID).Path
if (-not $pwshExe) { $pwshExe = 'pwsh' }

try {
    $stick = Join-Path $script:TmpRoot 'stick'
    $aiusbDir = Join-Path $stick 'aiusb'
    New-Item -ItemType Directory -Path (Join-Path $aiusbDir 'vault'), (Join-Path $aiusbDir 'context'),
        (Join-Path $aiusbDir 'workspace'), (Join-Path $aiusbDir 'logs') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot 'payload/aiusb/aiusb.conf') -Destination (Join-Path $aiusbDir 'aiusb.conf')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'payload/aiusb/context') -Destination $aiusbDir -Recurse
    # extra conf lines for the parser checks (value keeps text after the first '='; '#' is a comment)
    Add-Content -LiteralPath (Join-Path $aiusbDir 'aiusb.conf') -Value "X_TEST=a=b`r`n# TRAP_KEY=must-not-be-read"

    # the $script: variables the launcher's functions use (names exactly as in launcher.ps1)
    $script:USB = $stick
    $script:CONF = Join-Path $aiusbDir 'aiusb.conf'
    $script:V = Join-Path $aiusbDir 'vault'
    $script:LOGDIR = Join-Path $aiusbDir 'logs'
    $script:LOGFILE = Join-Path $script:LOGDIR 'launcher.log'
    $script:CTXDIR = Join-Path $aiusbDir 'context'
    $script:WORKSPACE = Join-Path $aiusbDir 'workspace'
    $script:BINWIN = Join-Path $repoRoot 'build/payload/aiusb/bin/win-x64'   # path strings only, never executed
    $script:AGYEXE = Join-Path $script:BINWIN 'agy.exe'
    $script:AGE = $ageExe
    $script:AGEKEYGEN = $ageKeygenExe
    $script:TAREXE = $tarExe
    $script:S = ''
    $script:H = ''
    $script:T = ''
    $script:Admin = $false
    $script:Autonomous = $false
    $script:SessionReady = $false
    $script:OwnLock = $false
    $script:OwnSession = $false
    $script:CtrlGuard = $false

    # test vault: UNENCRYPTED identity at vault/identity.age (age -i never prompts), its public
    # key in recipient.txt, and a random 32-hex vault id. New-Vault is never used (it prompts).
    $idTmp = Join-Path $script:TmpRoot 'id.txt'
    & $script:AGEKEYGEN -o $idTmp
    if ($LASTEXITCODE -ne 0) { throw 'age-keygen failed' }
    & $script:AGEKEYGEN -y -o (Join-Path $script:V 'recipient.txt') $idTmp
    if ($LASTEXITCODE -ne 0) { throw 'age-keygen -y failed' }
    Copy-Item -LiteralPath $idTmp -Destination (Join-Path $script:V 'identity.age')
    Remove-Item -LiteralPath $idTmp -Force
    $idBytes = New-Object byte[] 16
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($idBytes)
    $script:VaultId = (($idBytes | ForEach-Object { $_.ToString('x2') }) -join '')
    [System.IO.File]::WriteAllText((Join-Path $script:V 'vault.id'), $script:VaultId)
    # Unlock-Vault uses the private key from memory when it is there (no passphrase prompt)
    $script:Identity = [System.IO.File]::ReadAllText((Join-Path $script:V 'identity.age'))
    $script:HistDirty = @{}

    Initialize-Session   # sets $script:S/$script:H/$script:T inside the fake stick

    # child script for the unplug-watcher check (loads the same functions itself)
    $childScriptPath = Join-Path $script:TmpRoot 'watcher-child.ps1'
    $childCode = @'
# AI-USB test child: the launcher's unplug watcher must kill /bin/sleep and exit 2
# when vault.id disappears. Load the launcher functions like the parent test does.
$ErrorActionPreference = 'Stop'
$launcherPath = '@@LAUNCHER@@'
$stickRoot = '@@STICK@@'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($launcherPath, [ref]$tokens, [ref]$parseErrors)
if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) { exit 9 }
foreach ($fn in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}
$script:LangDir = '@@LANGDIR@@'
$script:UiLang = 'en'
Import-Lang 'en'
$script:USB = $stickRoot
$script:CONF = Join-Path $stickRoot 'aiusb/aiusb.conf'
$script:V = Join-Path $stickRoot 'aiusb/vault'
$script:LOGDIR = Join-Path $stickRoot 'aiusb/logs'
$script:LOGFILE = Join-Path $stickRoot 'aiusb/logs/launcher.log'
$script:CTXDIR = Join-Path $stickRoot 'aiusb/context'
$script:WORKSPACE = Join-Path $stickRoot 'aiusb/workspace'
$script:S = Join-Path $stickRoot 'aiusb/session'
$script:H = Join-Path $script:S 'home'
$script:T = Join-Path $script:S 'tmp'
$script:BINWIN = '/nonexistent-binwin'
$script:AGYEXE = '/nonexistent-binwin/agy.exe'
$script:AGE = '/nonexistent-age'
$script:AGEKEYGEN = '/nonexistent-age-keygen'
$script:TAREXE = '/usr/bin/bsdtar'
$script:Admin = $false
$script:Autonomous = $false
$script:SessionReady = $false
$script:OwnLock = $false
$script:OwnSession = $false
$script:CtrlGuard = $false
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = '/bin/sleep'
$psi.Arguments = '30'
$psi.UseShellExecute = $false
exit (Invoke-AgentProcess $psi)
'@
    $childCode = $childCode.Replace('@@LAUNCHER@@', $launcherPath).Replace('@@STICK@@', $stick).Replace('@@LANGDIR@@', $script:LangDir)
    [System.IO.File]::WriteAllText($childScriptPath, $childCode, (New-Object System.Text.UTF8Encoding($false)))

    # ------------------------------------------------------------ check 1: Get-Conf
    $bad1 = @()
    try {
        $expectedGlm = ''
        foreach ($l in [System.IO.File]::ReadAllLines($script:CONF)) {
            $tline = $l.Trim()
            if ($tline.StartsWith('#') -or -not $tline.StartsWith('GLM_BASE_URL=')) { continue }
            $expectedGlm = $tline.Substring('GLM_BASE_URL='.Length)
            break
        }
        if ([string]::IsNullOrEmpty($expectedGlm)) { $bad1 += 'test conf has no GLM_BASE_URL' }
        $glm = Get-Conf 'GLM_BASE_URL' ''
        if ($glm -cne $expectedGlm) { $bad1 += ('GLM_BASE_URL=' + $glm) }
        if ((Get-Conf 'X_TEST' '') -cne 'a=b') { $bad1 += ('X_TEST=' + (Get-Conf 'X_TEST' '')) }
        if ((Get-Conf 'TRAP_KEY' 'fallback7') -cne 'fallback7') { $bad1 += 'default not returned for missing key' }
    } catch { $bad1 += ('threw: ' + $_.Exception.Message) }
    Add-Check '01 Get-Conf' ($bad1.Count -eq 0) ($bad1 -join '; ')

    # ------------------------------------------------------------ check 2: ConvertTo-WinArg
    $bad2 = @()
    try {
        if ((ConvertTo-WinArg 'C:\') -cne 'C:\') { $bad2 += 'plain C:\ case' }
        if ((ConvertTo-WinArg 'C:\My Dir\') -cne '"C:\My Dir\\"') { $bad2 += ('spaces/backslashes case: ' + (ConvertTo-WinArg 'C:\My Dir\')) }
        if ((ConvertTo-WinArg '') -cne '""') { $bad2 += 'empty case' }
        if ((ConvertTo-WinArg 'say "hi"') -cne '"say \"hi\""') { $bad2 += ('embedded quotes case: ' + (ConvertTo-WinArg 'say "hi"')) }
    } catch { $bad2 += ('threw: ' + $_.Exception.Message) }
    Add-Check '02 ConvertTo-WinArg' ($bad2.Count -eq 0) ($bad2 -join '; ')

    # ------------------------------------------------------------ check 3: Set-CommonEnv
    $bad3 = @()
    $hostVars = @('ANTHROPIC_API_KEY', 'ANTHROPIC_MODEL', 'CLAUDE_CODE_USE_BEDROCK', 'CLAUDECODE',
        'OPENAI_API_KEY', 'CODEX_HOME', 'GEMINI_API_KEY', 'GOOGLE_CLOUD_PROJECT', 'AGY_ACCOUNT',
        'ANTIGRAVITY_PROJECT_ID', 'JETSKI_OAUTH_TOKEN')
    try {
        foreach ($n in $hostVars) { Set-Item -Path ('Env:' + $n) -Value 'aiusb-dummy' }
        Set-Item -Path 'Env:AIUSB_KEEP_ME' -Value '1'
        $psi3 = New-Object System.Diagnostics.ProcessStartInfo
        $psi3.UseShellExecute = $false
        Set-CommonEnv $psi3
        $vars3 = $psi3.EnvironmentVariables
        # host values must be gone (CODEX_HOME is legitimately re-set by the launcher, so compare values)
        foreach ($n in $hostVars) {
            if ($vars3.ContainsKey($n) -and [string]$vars3[$n] -ceq 'aiusb-dummy') { $bad3 += ($n + ' still has the host value') }
        }
        if (-not $vars3.ContainsKey('AIUSB_KEEP_ME')) { $bad3 += 'AIUSB_KEEP_ME was dropped' }
        $exact3 = @{
            'AIUSB_ROOT' = $script:USB
            'AIUSB_MODE' = 'windows'
            'AIUSB_SESSION' = $script:S
            'TMPDIR' = $script:T
            'TMP' = $script:T
            'TEMP' = $script:T
            'DISABLE_AUTOUPDATER' = '1'
            'CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL' = '1'
            'CLAUDE_CODE_PROJECT_DIR_NAME' = 'aiusb-workspace'
        }
        foreach ($k in $exact3.Keys) {
            if (-not $vars3.ContainsKey($k)) { $bad3 += ($k + ' not set') }
            elseif ([string]$vars3[$k] -cne $exact3[$k]) { $bad3 += ($k + '=' + [string]$vars3[$k]) }
        }
        foreach ($k in @('ANTHROPIC_CONFIG_DIR', 'CODEX_HOME', 'CODEX_SQLITE_HOME')) {
            if (-not $vars3.ContainsKey($k)) { $bad3 += ($k + ' not set') }
        }
        $path3 = [string]$vars3['Path']
        # the FileSystem provider normalises the launcher's '\bin' to '/bin' on Linux; accept both
        $pA = $script:S + '\bin;'
        $pB = (Join-Path $script:S 'bin') + ';'
        if (-not ($path3.StartsWith($pA) -or $path3.StartsWith($pB))) { $bad3 += ('Path prefix: ' + $path3) }
    } catch {
        $bad3 += ('threw: ' + $_.Exception.Message)
    } finally {
        foreach ($n in ($hostVars + @('AIUSB_KEEP_ME'))) {
            Remove-Item -Path ('Env:' + $n) -ErrorAction SilentlyContinue
        }
    }
    Add-Check '03 Set-CommonEnv' ($bad3.Count -eq 0) ($bad3 -join '; ')

    # ------------------------------------------------------------ check 4: Initialize-Session + Initialize-Home
    $bad4 = @()
    try {
        Initialize-Session
        foreach ($d in @($script:S, $script:H, $script:T)) {
            if (-not (Test-Path -LiteralPath $d)) { $bad4 += 'session dir missing: ' + $d }
        }
        $cfgDir = Join-Path $script:H 'codex'
        New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
        $cfgPath = Join-Path $cfgDir 'config.toml'
        $pre4 = @('cli_auth_credentials_store = "keyring"', '[projects."/x"]', 'trust_level = "trusted"')
        [System.IO.File]::WriteAllText($cfgPath, ($pre4 -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
        Initialize-Home
        foreach ($d in @('claude', 'claude-glm', 'anthropic', 'codex', 'agy', 'secrets')) {
            if (-not (Test-Path -LiteralPath (Join-Path $script:H $d))) { $bad4 += ('missing home dir ' + $d) }
        }
        $sidPath = Join-Path $script:H '.aiusb-vault-id'
        if (-not (Test-Path -LiteralPath $sidPath)) { $bad4 += '.aiusb-vault-id missing' }
        elseif (([System.IO.File]::ReadAllText($sidPath)).Trim() -cne $script:VaultId) { $bad4 += '.aiusb-vault-id mismatch' }
        $cfgLines = [System.IO.File]::ReadAllLines($cfgPath)
        if ($cfgLines.Count -lt 4) { $bad4 += 'config.toml too short' }
        else {
            if ($cfgLines[0] -cne 'cli_auth_credentials_store = "file"') { $bad4 += ('line0: ' + $cfgLines[0]) }
            if ($cfgLines[1] -cne 'mcp_oauth_credentials_store = "file"') { $bad4 += ('line1: ' + $cfgLines[1]) }
            if ($cfgLines -contains 'cli_auth_credentials_store = "keyring"') { $bad4 += 'keyring line kept' }
            if ($cfgLines[2] -cne '[projects."/x"]') { $bad4 += ('line2: ' + $cfgLines[2]) }
            if ($cfgLines[3] -cne 'trust_level = "trusted"') { $bad4 += ('line3: ' + $cfgLines[3]) }
        }
        $cfgBytes = [System.IO.File]::ReadAllBytes($cfgPath)
        if ($cfgBytes.Length -ge 3 -and $cfgBytes[0] -eq 0xEF -and $cfgBytes[1] -eq 0xBB -and $cfgBytes[2] -eq 0xBF) { $bad4 += 'config.toml has a BOM' }
    } catch { $bad4 += ('threw: ' + $_.Exception.Message) }
    Add-Check '04 Initialize-Session+Home' ($bad4.Count -eq 0) ($bad4 -join '; ')

    # ------------------------------------------------------------ check 5: Write-Wrappers
    $bad5 = @()
    try {
        $secDir = Join-Path $script:H 'secrets'
        [System.IO.File]::WriteAllText((Join-Path $secDir 'zai.key'), 'ZAI-SECRET-123')
        [System.IO.File]::WriteAllText((Join-Path $secDir 'gemini.key'), 'GEM-SECRET-456')
        Write-Wrappers
        $binDir = Join-Path $script:S 'bin'
        foreach ($w in @('claude.cmd', 'claude-glm.cmd', 'codex.cmd', 'agy.cmd')) {
            $wp = Join-Path $binDir $w
            if (-not (Test-Path -LiteralPath $wp)) { $bad5 += ($w + ' missing'); continue }
            $wtxt = [System.IO.File]::ReadAllText($wp)
            if ($wtxt.Contains('ZAI-SECRET-123') -or $wtxt.Contains('GEM-SECRET-456')) { $bad5 += ($w + ' embeds a secret') }
            $lf = [regex]::Matches($wtxt, "`n").Count
            $crlf = [regex]::Matches($wtxt, "`r`n").Count
            if ($lf -ne $crlf) { $bad5 += ($w + ' is not CRLF') }
        }
        foreach ($w in @('claude.cmd', 'claude-glm.cmd')) {
            $wtxt = [System.IO.File]::ReadAllText((Join-Path $binDir $w))
            if (-not $wtxt.Contains('claude-nocredman.ps1')) { $bad5 += ($w + ' lacks nocredman call') }
            if (-not $wtxt.Contains('CLAUDE_CODE_USE_POWERSHELL_TOOL=1')) { $bad5 += ($w + ' lacks PowerShell tool flag') }
            if (-not $wtxt.Contains('set "CLAUDE_CODE_PROJECT_DIR_NAME=aiusb-workspace"')) { $bad5 += ($w + ' lacks the project folder name') }
        }
        if (-not ([System.IO.File]::ReadAllText((Join-Path $binDir 'codex.cmd'))).Contains('CODEX_SQLITE_HOME=')) { $bad5 += 'codex.cmd lacks CODEX_SQLITE_HOME' }
        $agyCmd = [System.IO.File]::ReadAllText((Join-Path $binDir 'agy.cmd'))
        foreach ($want in @('set "USERPROFILE=%AIUSB_SESSION%\home\agy"', 'set "SSH_CONNECTION=', 'set "AGY_CLI_DISABLE_AUTO_UPDATE=true"', 'agy.exe"', '--add-dir=')) {
            if (-not $agyCmd.Contains($want)) { $bad5 += ('agy.cmd lacks ' + $want) }
        }
    } catch { $bad5 += ('threw: ' + $_.Exception.Message) }
    Add-Check '05 Write-Wrappers' ($bad5.Count -eq 0) ($bad5 -join '; ')

    # ------------------------------------------------------------ check 6: Get-Context / Write-Context
    $bad6 = @()
    try {
        $ctx = Get-Context 'claude'
        if (-not $ctx.Contains('## This machine (generated)')) { $bad6 += 'generated section missing' }
        $hwPath = Join-Path $script:CTXDIR 'host-windows.md'
        if (-not (Test-Path -LiteralPath $hwPath)) { $bad6 += 'host-windows.md missing' }
        else {
            $hwFirst = ([System.IO.File]::ReadAllLines($hwPath))[0]
            if (-not $ctx.Contains($hwFirst)) { $bad6 += 'host-windows.md content missing' }
        }
        Write-Context 'codex'
        if (-not (Test-Path -LiteralPath (Join-Path $script:H 'codex/AGENTS.md'))) { $bad6 += 'AGENTS.md not written' }
    } catch { $bad6 += ('threw: ' + $_.Exception.Message) }
    Add-Check '06 Get/Write-Context' ($bad6.Count -eq 0) ($bad6 -join '; ')

    # ------------------------------------------------------------ check 7: vault round trip
    $bad7 = @()
    try {
        $h7 = $script:H
        foreach ($d in @('claude/cache', 'claude/projects/p', 'codex/sessions', 'agy/.gemini/antigravity-cli/conversations')) {
            New-Item -ItemType Directory -Path (Join-Path $h7 $d) -Force | Out-Null
        }
        [System.IO.File]::WriteAllText((Join-Path $h7 'claude/.credentials.json'), '{"t":1}')
        [System.IO.File]::WriteAllBytes((Join-Path $h7 'claude/cache/big.bin'), (New-Object byte[] 1048576))
        [System.IO.File]::WriteAllText((Join-Path $h7 'claude/projects/p/s.jsonl'), '{}')
        [System.IO.File]::WriteAllText((Join-Path $h7 'codex/sessions/s.jsonl'), '{}')
        [System.IO.File]::WriteAllText((Join-Path $h7 'codex/auth.json'), '{"ok":1}')
        [System.IO.File]::WriteAllText((Join-Path $h7 'agy/.gemini/antigravity-cli/conversations/x.pb'), 'x')
        Save-Vault
        Save-Vault
        if (-not (Test-Path -LiteralPath (Join-Path $script:V 'home.tar.age'))) { $bad7 += 'home.tar.age missing' }
        if (-not (Test-Path -LiteralPath (Join-Path $script:V 'home.tar.age.bak'))) { $bad7 += 'home.tar.age.bak missing' }
        if (Test-Path -LiteralPath (Join-Path $script:V 'home.tar.age.new')) { $bad7 += 'home.tar.age.new left behind' }
        if (Test-Path -LiteralPath (Join-Path $script:S 'home.tar')) { $bad7 += 'session home.tar left behind' }
        $list7 = @(Get-VaultListing)
        if (@($list7 | Where-Object { $_ -eq 'claude/.credentials.json' }).Count -lt 1) { $bad7 += 'credentials not in vault' }
        if (@($list7 | Where-Object { $_ -eq 'codex/auth.json' }).Count -lt 1) { $bad7 += 'auth.json not in vault' }
        # no './' or '.' member: tar.exe would create an undeletable '.' entry on exFAT
        if (@($list7 | Where-Object { $_ -eq './' -or $_ -eq '.' -or $_.StartsWith('./') }).Count -gt 0) { $bad7 += 'archive has ./ members' }
        foreach ($ex in @('claude/cache', 'claude/projects', 'codex/sessions', 'agy/.gemini/antigravity-cli/conversations')) {
            if (@($list7 | Where-Object { $_.StartsWith($ex) }).Count -gt 0) { $bad7 += ('excluded path in vault: ' + $ex) }
        }
        Get-ChildItem -LiteralPath $h7 -Force | Remove-Item -Recurse -Force
        $unlocked = Unlock-Vault
        if ($unlocked -ne $true) { $bad7 += 'Unlock-Vault did not return true' }
        $credPath = Join-Path $h7 'claude/.credentials.json'
        if (-not (Test-Path -LiteralPath $credPath)) { $bad7 += 'credentials not restored' }
        elseif ([System.IO.File]::ReadAllText($credPath) -cne '{"t":1}') { $bad7 += ('credentials content: ' + [System.IO.File]::ReadAllText($credPath)) }
        if (Test-Path -LiteralPath (Join-Path $h7 'claude/cache')) { $bad7 += 'claude/cache was restored' }
        if (Test-Path -LiteralPath (Join-Path $script:S 'home.tar')) { $bad7 += 'home.tar left after unlock' }
        # a vault written by an older version (GNU tar with a './' root member) still unlocks
        $oldTar = Join-Path $script:TmpRoot 'old-style.tar'
        & /usr/bin/tar -cf $oldTar -C $h7 .
        & $script:AGE -R (Join-Path $script:V 'recipient.txt') -o (Join-Path $script:V 'home.tar.age') $oldTar
        Get-ChildItem -LiteralPath $h7 -Force | Remove-Item -Recurse -Force
        if ((Unlock-Vault) -ne $true) { $bad7 += 'old-style vault did not unlock' }
        elseif (-not (Test-Path -LiteralPath $credPath)) { $bad7 += 'old-style vault: credentials not restored' }
        Save-Vault   # back to the new format for the next checks
    } catch { $bad7 += ('threw: ' + $_.Exception.Message) }
    Add-Check '07 vault round trip' ($bad7.Count -eq 0) ($bad7 -join '; ')

    # ------------------------------------------------------------ check 8: Restore-StaleSession
    $bad8 = @()
    try {
        # (a) leftover session that belongs to this vault: re-saved, then wiped and re-created
        [System.IO.File]::WriteAllText((Join-Path $script:H 'claude/marker.txt'), 'm8')
        Restore-StaleSession
        if (-not (Test-Path -LiteralPath $script:S)) { $bad8 += 'S missing after restore (a)' }
        if (Test-Path -LiteralPath (Join-Path $script:H 'claude/marker.txt')) { $bad8 += 'marker.txt survived (a)' }
        $list8 = @(Get-VaultListing)
        if (@($list8 | Where-Object { $_ -eq 'claude/marker.txt' }).Count -lt 1) { $bad8 += 'marker.txt not saved into vault (a)' }
        # (b) leftovers without a vault id: wiped without saving
        New-Item -ItemType Directory -Path (Join-Path $script:H 'codex') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $script:H 'codex/junk.txt'), 'junk')
        Restore-StaleSession
        if (Test-Path -LiteralPath (Join-Path $script:H 'codex/junk.txt')) { $bad8 += 'junk survived (b)' }
        if (-not (Test-Path -LiteralPath $script:S)) { $bad8 += 'S missing after restore (b)' }
    } catch { $bad8 += ('threw: ' + $_.Exception.Message) }
    Add-Check '08 Restore-StaleSession' ($bad8.Count -eq 0) ($bad8 -join '; ')

    # ------------------------------------------------------------ check 9: Clear-Session guard
    $bad9 = @()
    try {
        $guardDir = Join-Path $script:TmpRoot 'guard-dir'
        New-Item -ItemType Directory -Path $guardDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $guardDir 'keep.txt') -Value 'x'
        $script:S = $guardDir
        Clear-Session   # must refuse: S is not <USB>\aiusb\session
        if (-not (Test-Path -LiteralPath (Join-Path $guardDir 'keep.txt'))) { $bad9 += 'guard dir was deleted' }
        $realS = Join-Path $script:USB 'aiusb\session'
        $script:S = $realS
        Clear-Session   # the real session dir is wiped
        if (Test-Path -LiteralPath $realS) { $bad9 += 'real session dir was not deleted' }
    } catch { $bad9 += ('threw: ' + $_.Exception.Message) }
    Add-Check '09 Clear-Session guard' ($bad9.Count -eq 0) ($bad9 -join '; ')

    # ------------------------------------------------------------ check 10: claude-nocredman.ps1 (called directly)
    $bad10 = @()
    try {
        $enc10 = New-Object System.Text.UTF8Encoding($false)
        $nc = Join-Path $script:TmpRoot 'nocred'
        New-Item -ItemType Directory -Path $nc -Force | Out-Null
        $j = Join-Path $nc '.claude.json'
        [System.IO.File]::WriteAllText($j, '{"a":1,"cachedGrowthBookFeatures":{"tengu_windows_credman":true,"x":2}}', $enc10)
        $c = Join-Path $nc '.config.json'
        [System.IO.File]::WriteAllText($c, '{"m":{"tengu_windows_credman" : true},"z":0}', $enc10)
        & $nocredmanPath $nc
        $outJ = [System.IO.File]::ReadAllText($j)
        if ($outJ -cne '{"a":1,"cachedGrowthBookFeatures":{"tengu_windows_credman":false,"x":2}}') { $bad10 += ('.claude.json: ' + $outJ) }
        $outC = [System.IO.File]::ReadAllText($c)
        if ($outC -cne '{"m":{"tengu_windows_credman" : false},"z":0}') { $bad10 += ('.config.json: ' + $outC) }
        $jb = [System.IO.File]::ReadAllBytes($j)
        if ($jb.Length -ge 3 -and $jb[0] -eq 0xEF -and $jb[1] -eq 0xBB -and $jb[2] -eq 0xBF) { $bad10 += 'BOM written' }
        $nc2 = Join-Path $script:TmpRoot 'nocred-clean'
        New-Item -ItemType Directory -Path $nc2 -Force | Out-Null
        $j2 = Join-Path $nc2 '.claude.json'
        [System.IO.File]::WriteAllText($j2, '{"plain":true}', $enc10)
        & $nocredmanPath $nc2
        if ([System.IO.File]::ReadAllText($j2) -cne '{"plain":true}') { $bad10 += 'file without the key was modified' }
        $missing = Join-Path $script:TmpRoot 'no-such-dir'
        try { & $nocredmanPath $missing } catch { $bad10 += ('missing dir threw: ' + $_.Exception.Message) }
    } catch { $bad10 += ('threw: ' + $_.Exception.Message) }
    Add-Check '10 claude-nocredman.ps1' ($bad10.Count -eq 0) ($bad10 -join '; ')

    # ------------------------------------------------------------ check 11: Invoke-AgentProcess exit code
    $rc11 = -1
    $err11 = ''
    try {
        $psi11 = New-Object System.Diagnostics.ProcessStartInfo
        $psi11.FileName = '/bin/sh'
        $psi11.Arguments = '-c "exit 3"'
        $psi11.UseShellExecute = $false
        $rc11 = Invoke-AgentProcess $psi11
    } catch { $err11 = $_.Exception.Message }
    Add-Check '11 Invoke-AgentProcess rc' (($err11 -eq '') -and ($rc11 -eq 3)) (('rc=' + $rc11 + ' ' + $err11).Trim())

    # ------------------------------------------------------------ check 12: unplug watcher (child process)
    $bad12 = @()
    $childProc = $null
    $vidPath12 = Join-Path $script:V 'vault.id'
    $movedPath12 = Join-Path $script:V 'vault.id.moved'
    try {
        $pre12 = @(Get-Process -Name sleep -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
        $out12 = Join-Path $script:TmpRoot 'child-out.txt'
        $errFile12 = Join-Path $script:TmpRoot 'child-err.txt'
        $childProc = Start-Process -FilePath $pwshExe -ArgumentList ('-NoProfile -NonInteractive -File "{0}"' -f $childScriptPath) -RedirectStandardOutput $out12 -RedirectStandardError $errFile12 -PassThru
        Start-Sleep -Seconds 2   # let the child reach the watcher loop with /bin/sleep running
        if (Test-Path -LiteralPath $vidPath12) {
            Rename-Item -LiteralPath $vidPath12 -NewName 'vault.id.moved'   # simulate unplugging the stick
        } else {
            $bad12 += 'vault.id missing before rename'
        }
        $exited12 = $childProc.WaitForExit(15000)
        if (-not $exited12) { $bad12 += 'child did not exit within 15 s' }
        elseif ($childProc.ExitCode -ne 2) { $bad12 += ('child exit code ' + $childProc.ExitCode) }
        Start-Sleep -Milliseconds 700
        $post12 = @(Get-Process -Name sleep -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
        $left12 = @($post12 | Where-Object { $pre12 -notcontains $_ })
        if ($left12.Count -gt 0) { $bad12 += ('sleep still running: ' + ($left12 -join ',')) }
    } catch {
        $bad12 += ('threw: ' + $_.Exception.Message)
    } finally {
        if (Test-Path -LiteralPath $movedPath12) { Rename-Item -LiteralPath $movedPath12 -NewName 'vault.id' }
        if ($null -ne $childProc -and -not $childProc.HasExited) { try { $childProc.Kill() } catch { } }
    }
    Add-Check '12 unplug watcher' ($bad12.Count -eq 0) ($bad12 -join '; ')

    # ------------------------------------------------------------ check 13: Write-Log
    $bad13 = @()
    try {
        Write-Log 'log-marker-event-13'
        $lastLine = ''
        if (Test-Path -LiteralPath $script:LOGFILE) {
            $all13 = [System.IO.File]::ReadAllLines($script:LOGFILE)
            if ($all13.Count -gt 0) { $lastLine = $all13[$all13.Count - 1] }
        }
        if (-not $lastLine.Contains(' windows ')) { $bad13 += ('no windows field: [' + $lastLine + ']') }
        if (-not $lastLine.Contains('log-marker-event-13')) { $bad13 += 'event text missing' }
    } catch { $bad13 += ('threw: ' + $_.Exception.Message) }
    Add-Check '13 Write-Log' ($bad13.Count -eq 0) ($bad13 -join '; ')

    # ------------------------------------------------------------ checks 14-16: AiUsbConsole.cs (window close)
    $csPath = Join-Path $repoRoot 'payload/aiusb/launcher/AiUsbConsole.cs'
    $bad16 = @()
    try {
        # C# 5 is what Windows PowerShell 5.1's Add-Type compiler accepts
        Add-Type -Path $csPath -CompilerOptions '-langversion:5' -ErrorAction Stop
    } catch { $bad16 += ('compile: ' + $_.Exception.Message) }
    $ps1Text = [System.IO.File]::ReadAllText($launcherPath)
    if (-not $ps1Text.Contains("Join-Path `$Dir 'AiUsbConsole.cs'")) { $bad16 += 'launcher.ps1 does not load AiUsbConsole.cs' }
    if (-not $ps1Text.Contains("`nImport-ConsoleGuards")) { $bad16 += 'main flow does not call Import-ConsoleGuards' }
    Add-Check '16 AiUsbConsole.cs compiles as C# 5' ($bad16.Count -eq 0) ($bad16 -join '; ')

    $bad14 = @()
    try {
        Initialize-Session
        Initialize-Home
        Save-Vault
        Write-Lock
        [System.IO.File]::WriteAllText((Join-Path $script:H 'claude/.credentials.json'), '{"closed":1}')
        New-Item -ItemType Directory -Path (Join-Path $script:H 'claude/cache') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $script:H 'claude/cache/junk'), 'x')
        $agent14 = Start-Process -FilePath '/bin/sleep' -ArgumentList '60' -PassThru
        [AiUsbCloseGuard]::Arm($script:TAREXE, $script:AGE, $script:USB, $script:S, $script:H, $script:V,
            [string[]]$script:VAULT_EXCLUDES, $script:LOGFILE, 'TESTPC')
        [AiUsbCloseGuard]::SetAgentPid($agent14.Id)
        $res14 = [AiUsbCloseGuard]::RunCloseForTest()
        Start-Sleep -Milliseconds 300
        if ($res14 -ne 'save-ok') { $bad14 += ('result ' + $res14) }
        if (-not $agent14.HasExited) { $bad14 += 'agent still running'; try { $agent14.Kill() } catch { } }
        if (Test-Path -LiteralPath $script:S) { $bad14 += 'session not wiped' }
        if (Test-Path -LiteralPath (Join-Path $script:V 'session.lock')) { $bad14 += 'lock not removed' }
        $list14 = @(Get-VaultListing)
        if (@($list14 | Where-Object { $_ -eq 'claude/.credentials.json' }).Count -lt 1) { $bad14 += 'login not saved' }
        if (@($list14 | Where-Object { $_.StartsWith('claude/cache') }).Count -gt 0) { $bad14 += 'cache saved' }
        $last14 = @([System.IO.File]::ReadAllLines($script:LOGFILE))[-1]
        if (-not $last14.Contains('window-closed save-ok')) { $bad14 += ('log: ' + $last14) }
        [AiUsbCloseGuard]::SetAgentPid(0)
        [AiUsbCloseGuard]::Disarm()
    } catch { $bad14 += ('threw: ' + $_.Exception.Message) }
    Add-Check '14 window close saves, wipes, unlocks' ($bad14.Count -eq 0) ($bad14 -join '; ')

    $bad15 = @()
    try {
        # Save-Vault uses the shared lock when the console types are loaded
        $script:CtrlGuard = $true
        Initialize-Session
        Initialize-Home
        $before15 = (Get-Item -LiteralPath (Join-Path $script:V 'home.tar.age')).LastWriteTimeUtc
        Start-Sleep -Milliseconds 1100
        Save-Vault
        $after15 = (Get-Item -LiteralPath (Join-Path $script:V 'home.tar.age')).LastWriteTimeUtc
        if ($after15 -le $before15) { $bad15 += 'normal Save-Vault did not save' }
        if (-not [AiUsbCloseGuard]::EnterSave(100)) { $bad15 += 'lock not released after Save-Vault' } else { [AiUsbCloseGuard]::ExitSave() }
        $script:CtrlGuard = $false
    } catch {
        $bad15 += ('threw: ' + $_.Exception.Message); $script:CtrlGuard = $false
    }
    Add-Check '15 Save-Vault shares the close lock' ($bad15.Count -eq 0) ($bad15 -join '; ')

    $bad17 = @()
    try {
        # a save still holding the lock when the window closes: no second save, nothing wiped
        Initialize-Session
        Initialize-Home
        Write-Lock
        [AiUsbCloseGuard]::Arm($script:TAREXE, $script:AGE, $script:USB, $script:S, $script:H, $script:V,
            [string[]]$script:VAULT_EXCLUDES, $script:LOGFILE, 'TESTPC')
        # a thread job has its own runspace but shares the C# static lock (same process)
        $holder = Start-ThreadJob -ScriptBlock {
            [void][AiUsbCloseGuard]::EnterSave(1000); Start-Sleep -Milliseconds 4500; [AiUsbCloseGuard]::ExitSave() }
        Start-Sleep -Milliseconds 500
        $res17 = [AiUsbCloseGuard]::RunCloseForTest()
        $holder | Wait-Job | Remove-Job
        if ($res17 -ne 'save-busy') { $bad17 += ('result ' + $res17) }
        if (-not (Test-Path -LiteralPath $script:S)) { $bad17 += 'session wiped although not saved' }
        if (-not (Test-Path -LiteralPath (Join-Path $script:V 'session.lock'))) { $bad17 += 'lock removed although not saved' }
        [AiUsbCloseGuard]::Disarm()
        Remove-Lock
    } catch { $bad17 += ('threw: ' + $_.Exception.Message) }
    Add-Check '17 window close while a save runs: save-busy' ($bad17.Count -eq 0) ($bad17 -join '; ')

    # ------------------------------------------------------------ checks 18-21: session switching
    # The lock functions compare the lock's host against $env:COMPUTERNAME, which is
    # empty on Linux: pin it to a test name for these checks, restore it afterwards.
    $savedComputerName = [string]$env:COMPUTERNAME
    $env:COMPUTERNAME = 'TESTPC'
    try {
        # ------------------------------------------------------------ check 18: Read-LockInfo
        $bad18 = @()
        $lockPath18 = Join-Path $script:V 'session.lock'
        try {
            if (Test-Path -LiteralPath $lockPath18) { Remove-Item -LiteralPath $lockPath18 -Force }
            if ($null -ne (Read-LockInfo)) { $bad18 += 'no lock file did not return null' }
            # (a) the new one-line format with a CRLF ending
            [System.IO.File]::WriteAllText($lockPath18, "host=TESTPC os=windows pid=4242 started=2026-01-01T00:00:00Z`r`n", [System.Text.Encoding]::ASCII)
            $a18 = Read-LockInfo
            if ($null -eq $a18) { $bad18 += '(a) returned null' }
            else {
                if ([string]$a18['host'] -cne 'TESTPC') { $bad18 += ('(a) host=' + [string]$a18['host']) }
                if ([string]$a18['os'] -cne 'windows') { $bad18 += ('(a) os=' + [string]$a18['os']) }
                if ([string]$a18['pid'] -cne '4242') { $bad18 += ('(a) pid=' + [string]$a18['pid']) }
                if ([string]$a18['started'] -cne '2026-01-01T00:00:00Z') { $bad18 += ('(a) started=' + [string]$a18['started']) }
            }
            # (b) the old multi-line Linux format
            [System.IO.File]::WriteAllText($lockPath18, "host=OTHER-PC`nos=Linux`npid=1`nstarted=2026-01-01T00:00:00Z`n", [System.Text.Encoding]::ASCII)
            $b18 = Read-LockInfo
            if ($null -eq $b18) { $bad18 += '(b) returned null' }
            else {
                if ([string]$b18['host'] -cne 'OTHER-PC') { $bad18 += ('(b) host=' + [string]$b18['host']) }
                if ([string]$b18['os'] -cne 'Linux') { $bad18 += ('(b) os=' + [string]$b18['os']) }
                if ([string]$b18['pid'] -cne '1') { $bad18 += ('(b) pid=' + [string]$b18['pid']) }
                if ([string]$b18['started'] -cne '2026-01-01T00:00:00Z') { $bad18 += ('(b) started=' + [string]$b18['started']) }
            }
            # (c) the old Windows format: local time, no Z
            [System.IO.File]::WriteAllText($lockPath18, "host=TESTPC os=Windows pid=1234 started=2026-01-01T12:00:00`r`n", [System.Text.Encoding]::ASCII)
            $c18 = Read-LockInfo
            if ($null -eq $c18) { $bad18 += '(c) returned null' }
            else {
                if ([string]$c18['host'] -cne 'TESTPC') { $bad18 += ('(c) host=' + [string]$c18['host']) }
                if ([string]$c18['os'] -cne 'Windows') { $bad18 += ('(c) os=' + [string]$c18['os']) }
                if ([string]$c18['pid'] -cne '1234') { $bad18 += ('(c) pid=' + [string]$c18['pid']) }
                if ([string]$c18['started'] -cne '2026-01-01T12:00:00') { $bad18 += ('(c) started=' + [string]$c18['started']) }
            }
            Remove-Item -LiteralPath $lockPath18 -Force
        } catch { $bad18 += ('threw: ' + $_.Exception.Message) }
        Add-Check '18 Read-LockInfo' ($bad18.Count -eq 0) ($bad18 -join '; ')

        # ------------------------------------------------------------ check 19: Test-LockLive
        $bad19 = @()
        $child19 = $null
        try {
            $own19 = @{}
            $own19['host'] = 'TESTPC'
            $own19['os'] = 'windows'
            $own19['pid'] = [string]$PID
            $own19['started'] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            if (Test-LockLive $own19) { $bad19 += 'lock with the own pid counted as live' }
            # a running pwsh child (process name "pwsh" on Linux) with matching start time is live
            $child19 = Start-Process -FilePath $pwshExe -ArgumentList '-NoProfile -Command Start-Sleep 30' -PassThru
            Start-Sleep -Milliseconds 500
            $live19 = @{}
            $live19['host'] = 'TESTPC'
            $live19['os'] = 'windows'
            $live19['pid'] = [string]$child19.Id
            $live19['started'] = $child19.StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            if (-not (Test-LockLive $live19)) { $bad19 += 'running child not live' }
            $off19 = @{}
            $off19['host'] = 'TESTPC'
            $off19['os'] = 'windows'
            $off19['pid'] = [string]$child19.Id
            $off19['started'] = $child19.StartTime.ToUniversalTime().AddHours(-1).ToString('yyyy-MM-ddTHH:mm:ssZ')
            if (Test-LockLive $off19) { $bad19 += 'start time 1 hour off counted as live' }
            $other19 = @{}
            $other19['host'] = 'OTHER'
            $other19['os'] = 'windows'
            $other19['pid'] = [string]$child19.Id
            $other19['started'] = $live19['started']
            if (Test-LockLive $other19) { $bad19 += 'other host counted as live' }
            $os19 = @{}
            $os19['host'] = 'TESTPC'
            $os19['os'] = 'linux'
            $os19['pid'] = [string]$child19.Id
            $os19['started'] = $live19['started']
            if (Test-LockLive $os19) { $bad19 += 'os linux counted as live' }
        } catch {
            $bad19 += ('threw: ' + $_.Exception.Message)
        } finally {
            if ($null -ne $child19 -and -not $child19.HasExited) { try { $child19.Kill() } catch { } }
        }
        Add-Check '19 Test-LockLive' ($bad19.Count -eq 0) ($bad19 -join '; ')

        # ------------------------------------------------------------ check 20: Write-Lock + Resolve-Lock
        $bad20 = @()
        $lockPath20 = Join-Path $script:V 'session.lock'
        try {
            Write-Lock
            $text20 = [System.IO.File]::ReadAllText($lockPath20)
            if ($text20 -cnotmatch '^host=TESTPC os=windows pid=\d+ started=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\r?\n$') {
                $bad20 += ('lock line: [' + $text20 + ']')
            }
            # a foreign lock is cleaned up, never asked about: Resolve-Lock returns normally
            [System.IO.File]::WriteAllText($lockPath20, "host=OTHER os=windows pid=4242 started=2026-01-01T00:00:00Z`r`n", [System.Text.Encoding]::ASCII)
            Resolve-Lock
            Remove-Lock
        } catch { $bad20 += ('threw: ' + $_.Exception.Message) }
        Add-Check '20 Write-Lock + Resolve-Lock' ($bad20.Count -eq 0) ($bad20 -join '; ')

        # ------------------------------------------------------------ check 21: Clear-Session fallback + Remove-OldSessions
        $bad21 = @()
        try {
            Remove-OldSessions   # start from a clean slate
            Initialize-Session
            $locked21 = Join-Path $script:H 'locked'
            New-Item -ItemType Directory -Path $locked21 -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $locked21 'keep.txt'), 'x')
            & /bin/chmod 0555 $locked21   # the file inside can no longer be removed
            if ($LASTEXITCODE -ne 0) { $bad21 += ('chmod 0555 rc=' + $LASTEXITCODE) }
            Clear-Session
            if (Test-Path -LiteralPath $script:S) { $bad21 += 'session folder still present after Clear-Session' }
            $old21 = @(Get-ChildItem -Path (Join-Path $script:USB 'aiusb\session-old-*') -Directory -ErrorAction SilentlyContinue)
            if ($old21.Count -ne 1) { $bad21 += ('session-old-* folders: ' + $old21.Count) }
            else {
                & /bin/chmod 0755 (Join-Path $old21[0].FullName 'home/locked')
                if ($LASTEXITCODE -ne 0) { $bad21 += ('chmod 0755 rc=' + $LASTEXITCODE) }
            }
            Remove-OldSessions
            $left21 = @(Get-ChildItem -Path (Join-Path $script:USB 'aiusb\session-old-*') -Directory -ErrorAction SilentlyContinue)
            if ($left21.Count -ne 0) { $bad21 += ('session-old-* folders left: ' + $left21.Count) }
        } catch { $bad21 += ('threw: ' + $_.Exception.Message) }
        Add-Check '21 Clear-Session fallback + Remove-OldSessions' ($bad21.Count -eq 0) ($bad21 -join '; ')
    } finally {
        if ([string]::IsNullOrEmpty($savedComputerName)) {
            Remove-Item -Path 'Env:\COMPUTERNAME' -ErrorAction SilentlyContinue
        } else {
            $env:COMPUTERNAME = $savedComputerName
        }
    }

    # ------------------------------------------------------------ checks 22-27: conversation history
    function Get-HistoryListing {
        param([string]$Group)
        $dec = Join-Path $script:TmpRoot ('inspect-' + $Group + '.tgz')
        if (Test-Path -LiteralPath $dec) { Remove-Item -LiteralPath $dec -Force }
        & $script:AGE -d -i (Join-Path $script:V 'identity.age') -o $dec (Get-HistoryArchive $Group) | Out-Null
        if ($LASTEXITCODE -ne 0) { throw ('age decrypt failed, rc=' + $LASTEXITCODE) }
        $entries = @(& $script:TAREXE -tf $dec)
        if ($LASTEXITCODE -ne 0) { throw ('bsdtar list failed, rc=' + $LASTEXITCODE) }
        Remove-Item -LiteralPath $dec -Force
        return $entries
    }
    $script:CtrlGuard = $false

    # ------------------------------------------------------------ check 22: saved apart, opened with the agent
    $bad22 = @()
    try {
        Initialize-Session
        Initialize-Home
        $hist22 = Join-Path $script:V 'history'
        if (Test-Path -LiteralPath $hist22) { Remove-Item -LiteralPath $hist22 -Recurse -Force }
        if (-not (Import-History 'claude')) { $bad22 += 'Import-History without an archive returned false' }
        if (-not (Test-Path -LiteralPath (Get-HistoryMarker 'claude'))) { $bad22 += 'marker missing after the first open' }
        $conv22 = Join-Path $script:H 'claude/projects/aiusb-workspace'
        New-Item -ItemType Directory -Path $conv22 -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $conv22 'c22.jsonl'), '{"conv":22}')
        $junk22 = Join-Path $script:H 'claude/skills/synced/office'
        New-Item -ItemType Directory -Path $junk22 -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $junk22 'big.xsd'), 'junk')
        [System.IO.File]::WriteAllText((Join-Path $script:H 'claude/.credentials.json'), '{"t":22}')
        Set-HistoryDirty 'claude' $true
        Save-Vault -Groups @('claude')
        if ($script:HistDirty.ContainsKey('claude')) { $bad22 += 'dirty flag not cleared after the save' }
        if (-not (Test-Path -LiteralPath (Get-HistoryArchive 'claude'))) { $bad22 += 'claude.tgz.age missing' }
        foreach ($g in @('codex', 'agy')) {
            if (Test-Path -LiteralPath (Get-HistoryArchive $g)) { $bad22 += ($g + ' archive written although never opened') }
        }
        $core22 = @(Get-VaultListing)
        if (@($core22 | Where-Object { $_.StartsWith('claude/projects') -or $_.StartsWith('claude/skills/synced') -or $_.StartsWith('.aiusb-loaded') }).Count -gt 0) {
            $bad22 += 'history, junk or a marker in the logins archive'
        }
        if (@($core22 | Where-Object { $_ -eq 'claude/.credentials.json' }).Count -lt 1) { $bad22 += 'credentials not in the logins archive' }
        $hl22 = @(Get-HistoryListing 'claude')
        if (@($hl22 | Where-Object { $_ -eq 'claude/projects/aiusb-workspace/c22.jsonl' }).Count -lt 1) { $bad22 += ('conversation not in the history archive: ' + ($hl22 -join ',')) }
        if (@($hl22 | Where-Object { $_.StartsWith('claude/skills') -or $_.StartsWith('claude/.credentials') }).Count -gt 0) { $bad22 += 'history archive holds more than the conversations' }
        # next session: unlock opens only the logins; the conversations come with the agent
        Clear-Session
        Initialize-Session
        if ((Unlock-Vault) -ne $true) { $bad22 += 'unlock failed' }
        if (Test-Path -LiteralPath (Join-Path $script:H 'claude/projects')) { $bad22 += 'conversations unpacked at unlock' }
        if (-not (Import-History 'claude')) { $bad22 += 'Import-History returned false' }
        $c22 = Join-Path $conv22 'c22.jsonl'
        if (-not (Test-Path -LiteralPath $c22)) { $bad22 += 'conversation not restored' }
        elseif ([System.IO.File]::ReadAllText($c22) -cne '{"conv":22}') { $bad22 += 'conversation content changed' }
        if (Test-Path -LiteralPath (Join-Path $script:H 'claude/skills/synced')) { $bad22 += 'junk restored' }
        if (Test-Path -LiteralPath (Join-Path $script:S 'hist-claude.tgz')) { $bad22 += 'hist-claude.tgz left in the session' }
        $log22 = [System.IO.File]::ReadAllText($script:LOGFILE)
        if ($log22 -notmatch 'history-load claude \d+ms') { $bad22 += 'no history-load line in the log' }
    } catch { $bad22 += ('threw: ' + $_.Exception.Message) }
    Add-Check '22 history: saved apart from the logins, opened with the agent' ($bad22.Count -eq 0) ($bad22 -join '; ')

    # ------------------------------------------------------------ check 23: an archive not opened is never overwritten
    $bad23 = @()
    try {
        Clear-Session
        Initialize-Session
        Initialize-Home
        $arch23 = Get-HistoryArchive 'claude'
        $before23 = (Get-FileHash -LiteralPath $arch23 -Algorithm SHA256).Hash
        $p23 = Join-Path $script:H 'claude/projects/aiusb-workspace'
        New-Item -ItemType Directory -Path $p23 -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $p23 'partial.jsonl'), 'x')
        if (Test-HistorySave 'claude') { $bad23 += 'an archive that was not opened counts as savable' }
        Save-Vault -Recover
        if ((Get-FileHash -LiteralPath $arch23 -Algorithm SHA256).Hash -ne $before23) { $bad23 += 'archive changed by Save-Vault -Recover' }
        if (Test-HistorySave 'codex') { $bad23 += 'codex without data counts as savable' }
        # no archive yet + data (a session of an older launcher): the first save is allowed
        $s23 = Join-Path $script:H 'codex/sessions/2026/10/13'
        New-Item -ItemType Directory -Path $s23 -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $s23 'rollout-23.jsonl'), '{}')
        if (-not (Test-HistorySave 'codex')) { $bad23 += 'first codex save refused' }
        Save-Vault -Recover
        if (-not (Test-Path -LiteralPath (Get-HistoryArchive 'codex'))) { $bad23 += 'codex archive not written by -Recover' }
        elseif (@(Get-HistoryListing 'codex' | Where-Object { $_ -eq 'codex/sessions/2026/10/13/rollout-23.jsonl' }).Count -lt 1) { $bad23 += 'rollout missing from the codex archive' }
    } catch { $bad23 += ('threw: ' + $_.Exception.Message) }
    Add-Check '23 history: an archive that was not opened is never overwritten' ($bad23.Count -eq 0) ($bad23 -join '; ')

    # ------------------------------------------------------------ check 24: a damaged archive is kept
    $bad24 = @()
    try {
        Clear-Session
        Initialize-Session
        Initialize-Home
        $arch24 = Get-HistoryArchive 'agy'
        [System.IO.File]::WriteAllText($arch24, 'not an age file')
        $h24 = (Get-FileHash -LiteralPath $arch24 -Algorithm SHA256).Hash
        if (Import-History 'agy') { $bad24 += 'damaged archive reported as opened' }
        if (Test-Path -LiteralPath (Get-HistoryMarker 'agy')) { $bad24 += 'marker set although the open failed' }
        $g24 = Join-Path $script:H 'agy/.gemini/antigravity-cli/conversations'
        New-Item -ItemType Directory -Path $g24 -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $g24 'c24.pb'), '{}')
        try { Save-Vault -Groups @('agy') } catch { }
        if ((Get-FileHash -LiteralPath $arch24 -Algorithm SHA256).Hash -ne $h24) { $bad24 += 'damaged archive overwritten' }
        Remove-Item -LiteralPath $arch24 -Force
    } catch { $bad24 += ('threw: ' + $_.Exception.Message) }
    Add-Check '24 history: an archive that cannot be opened stays untouched' ($bad24.Count -eq 0) ($bad24 -join '; ')

    # ------------------------------------------------------------ check 25: Merge-ClaudeProjects
    $bad25 = @()
    try {
        Clear-Session
        Initialize-Session
        Initialize-Home
        $proj25 = Join-Path $script:H 'claude/projects'
        $old25 = Join-Path $proj25 'E--aiusb-workspace'
        $new25 = Join-Path $proj25 'aiusb-workspace'
        $other25 = Join-Path $proj25 'C--Users-me-code'
        $glm25 = Join-Path $script:H 'claude-glm/projects/-run-media-me-AIUSB-aiusb-workspace'
        foreach ($d in @((Join-Path $old25 'sub'), $new25, $other25, $glm25)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        [System.IO.File]::WriteAllText((Join-Path $old25 'a.jsonl'), 'A')
        [System.IO.File]::WriteAllText((Join-Path $old25 'sub/t.txt'), 'T')
        [System.IO.File]::WriteAllText((Join-Path $old25 'clash.jsonl'), 'OLD-PATH-NEWER')
        [System.IO.File]::WriteAllText((Join-Path $old25 'keep.jsonl'), 'OLD-PATH-OLDER')
        [System.IO.File]::WriteAllText((Join-Path $new25 'b.jsonl'), 'B')
        [System.IO.File]::WriteAllText((Join-Path $new25 'clash.jsonl'), 'NEW-PATH-OLDER')
        [System.IO.File]::WriteAllText((Join-Path $new25 'keep.jsonl'), 'NEW-PATH-NEWER')
        [System.IO.File]::WriteAllText((Join-Path $other25 'c.jsonl'), 'C')
        [System.IO.File]::WriteAllText((Join-Path $glm25 'g.jsonl'), 'G')
        $hourAgo = (Get-Date).ToUniversalTime().AddHours(-1)
        [System.IO.File]::SetLastWriteTimeUtc((Join-Path $new25 'clash.jsonl'), $hourAgo)
        [System.IO.File]::SetLastWriteTimeUtc((Join-Path $old25 'keep.jsonl'), $hourAgo)
        Merge-ClaudeProjects
        foreach ($f in @('a.jsonl', 'b.jsonl', 'sub/t.txt')) {
            if (-not (Test-Path -LiteralPath (Join-Path $new25 $f))) { $bad25 += ($f + ' not in aiusb-workspace') }
        }
        if ([System.IO.File]::ReadAllText((Join-Path $new25 'clash.jsonl')) -cne 'OLD-PATH-NEWER') { $bad25 += 'newer clash file lost' }
        if ([System.IO.File]::ReadAllText((Join-Path $new25 'keep.jsonl')) -cne 'NEW-PATH-NEWER') { $bad25 += 'older file replaced a newer one' }
        if (Test-Path -LiteralPath $old25) { $bad25 += 'old path folder still there' }
        if (-not (Test-Path -LiteralPath (Join-Path $other25 'c.jsonl'))) { $bad25 += 'other project touched' }
        if (-not (Test-Path -LiteralPath (Join-Path $script:H 'claude-glm/projects/aiusb-workspace/g.jsonl'))) { $bad25 += 'claude-glm not merged' }
    } catch { $bad25 += ('threw: ' + $_.Exception.Message) }
    Add-Check '25 Merge-ClaudeProjects' ($bad25.Count -eq 0) ($bad25 -join '; ')

    # ------------------------------------------------------------ check 26: window close saves the conversations
    $bad26 = @()
    try {
        $members26 = @()
        foreach ($g in $script:HIST_GROUPS) { $members26 += (@($script:HIST_PATHS[$g]) -join '|') }
        Clear-Session
        Initialize-Session
        Initialize-Home
        Save-Vault
        Write-Lock
        if (-not (Import-History 'claude')) { $bad26 += 'claude archive did not open' }
        $p26 = Join-Path $script:H 'claude/projects/aiusb-workspace'
        New-Item -ItemType Directory -Path $p26 -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $p26 'c26.jsonl'), '{"conv":26}')
        [AiUsbCloseGuard]::Arm($script:TAREXE, $script:AGE, $script:USB, $script:S, $script:H, $script:V,
            [string[]](Get-CoreExcludes), $script:LOGFILE, 'TESTPC')
        [AiUsbCloseGuard]::SetHistory((Join-Path $script:V 'history'), [string[]]$script:HIST_GROUPS,
            [string[]]$members26, [string[]]$script:VAULT_EXCLUDES)
        [AiUsbCloseGuard]::SetDirty('claude', $true)
        $res26 = [AiUsbCloseGuard]::RunCloseForTest()
        if ($res26 -ne 'save-ok') { $bad26 += ('result ' + $res26) }
        if (Test-Path -LiteralPath $script:S) { $bad26 += 'session not wiped' }
        if (Test-Path -LiteralPath (Join-Path $script:V 'session.lock')) { $bad26 += 'lock not removed' }
        $hl26 = @(Get-HistoryListing 'claude')
        foreach ($c in @('c26.jsonl', 'c22.jsonl')) {
            if (@($hl26 | Where-Object { $_ -eq ('claude/projects/aiusb-workspace/' + $c) }).Count -lt 1) { $bad26 += ($c + ' not in the history archive') }
        }
        $log26 = @([System.IO.File]::ReadAllLines($script:LOGFILE))
        if (-not $log26[-2].Contains('window-closed begin')) { $bad26 += ('no begin line: ' + $log26[-2]) }
        # (b) a conversation archive that cannot be written: nothing is wiped, the lock stays
        Initialize-Session
        Initialize-Home
        Write-Lock
        if (-not (Import-History 'codex')) { $bad26 += 'codex archive did not open' }
        $blocker26 = (Get-HistoryArchive 'codex') + '.new'
        New-Item -ItemType Directory -Path $blocker26 -Force | Out-Null
        [AiUsbCloseGuard]::SetDirty('claude', $false)
        [AiUsbCloseGuard]::SetDirty('codex', $true)
        $resB26 = [AiUsbCloseGuard]::RunCloseForTest()
        if ($resB26 -ne 'history-fail') { $bad26 += ('(b) result ' + $resB26) }
        if (-not (Test-Path -LiteralPath (Join-Path $script:H '.aiusb-vault-id'))) { $bad26 += '(b) session wiped although a group was not saved' }
        if (-not (Test-Path -LiteralPath (Join-Path $script:V 'session.lock'))) { $bad26 += '(b) lock removed although a group was not saved' }
        Remove-Item -LiteralPath $blocker26 -Recurse -Force
        [AiUsbCloseGuard]::SetDirty('codex', $false)
        [AiUsbCloseGuard]::Disarm()
        Remove-Lock
    } catch { $bad26 += ('threw: ' + $_.Exception.Message) }
    Add-Check '26 window close saves the conversations too' ($bad26.Count -eq 0) ($bad26 -join '; ')

    # ------------------------------------------------------------ check 27: Import-ConsoleGuards keeps a compiled copy
    $bad27 = @()
    try {
        $gdir27 = Join-Path $script:TmpRoot 'guards'
        New-Item -ItemType Directory -Path $gdir27 -Force | Out-Null
        $cs27 = Join-Path $gdir27 'AiUsbConsole.cs'
        Copy-Item -LiteralPath $csPath -Destination $cs27
        $digest27 = [System.Security.Cryptography.SHA256]::HashData([System.IO.File]::ReadAllBytes($cs27))
        $hex27 = (($digest27[0..7] | ForEach-Object { $_.ToString('x2') }) -join '')
        $dll27 = Join-Path $gdir27 ('cache/AiUsbConsole-' + $hex27 + '-ps' + [string]$PSVersionTable.PSVersion.Major + '.dll')
        $childCode27 = @'
$ErrorActionPreference = 'Stop'
$ast = [System.Management.Automation.Language.Parser]::ParseFile('@@LAUNCHER@@', [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}
Import-ConsoleGuards -Dir '@@DIR@@'
$t = 'AiUsbCloseGuard' -as [type]
Write-Output ([string]$script:CtrlGuard + ' ' + $script:CtrlGuardSource + ' ' + [string]($null -ne $t))
'@
        $child27 = Join-Path $script:TmpRoot 'guards-child.ps1'
        [System.IO.File]::WriteAllText($child27, $childCode27.Replace('@@LAUNCHER@@', $launcherPath).Replace('@@DIR@@', $gdir27))
        $out1 = (& $pwshExe -NoProfile -NonInteractive -File $child27 | Out-String).Trim()
        if ($out1 -ne 'True memory True') { $bad27 += ('no cache: ' + $out1) }
        # a cached DLL of this exact source is loaded instead of compiling
        New-Item -ItemType Directory -Path (Split-Path -Parent $dll27) -Force | Out-Null
        & $pwshExe -NoProfile -NonInteractive -Command ("Add-Type -Path '" + $cs27 + "' -OutputAssembly '" + $dll27 + "' -OutputType Library") | Out-Null
        if (-not (Test-Path -LiteralPath $dll27)) { $bad27 += 'test could not build the cached DLL' }
        $out2 = (& $pwshExe -NoProfile -NonInteractive -File $child27 | Out-String).Trim()
        if ($out2 -ne 'True cache True') { $bad27 += ('cache: ' + $out2) }
        # a damaged cached DLL falls back to compiling
        [System.IO.File]::WriteAllText($dll27, 'not a dll')
        $out3 = (& $pwshExe -NoProfile -NonInteractive -File $child27 | Out-String).Trim()
        if ($out3 -ne 'True memory True') { $bad27 += ('damaged cache: ' + $out3) }
    } catch { $bad27 += ('threw: ' + $_.Exception.Message) }
    Add-Check '27 Import-ConsoleGuards uses the compiled copy' ($bad27.Count -eq 0) ($bad27 -join '; ')

    # ------------------------------------------------------------ check 28: Antigravity CLI
    $bad28 = @()
    try {
        Clear-Session
        Initialize-Session
        # what the old Gemini CLI left: its home in the session and its history archive
        New-Item -ItemType Directory -Path (Join-Path $script:H 'gemini/.gemini') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $script:H 'gemini/.gemini/oauth_creds.json'), '{}')
        $hist28 = Join-Path $script:V 'history'
        New-Item -ItemType Directory -Path $hist28 -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $hist28 'gemini.tgz.age'), 'legacy')
        Initialize-Home
        if (Test-Path -LiteralPath (Join-Path $script:H 'gemini')) { $bad28 += 'old Gemini home kept' }
        if (Test-Path -LiteralPath (Join-Path $hist28 'gemini.tgz.age')) { $bad28 += 'old Gemini history archive kept' }
        if (-not (Test-Path -LiteralPath (Join-Path $script:H 'agy'))) { $bad28 += 'agy home missing' }
        # environment: home in the session, file login (SSH marker), no self-update
        $psi28 = New-Object System.Diagnostics.ProcessStartInfo
        $psi28.UseShellExecute = $false
        Set-CommonEnv $psi28
        Set-AgyEnv $psi28.EnvironmentVariables
        $v28 = $psi28.EnvironmentVariables
        $agyHome28 = Join-Path $script:H 'agy'
        if ([string]$v28['USERPROFILE'] -cne $agyHome28) { $bad28 += ('USERPROFILE=' + [string]$v28['USERPROFILE']) }
        if ([string]$v28['HOME'] -cne $agyHome28) { $bad28 += ('HOME=' + [string]$v28['HOME']) }
        if ([string]$v28['SSH_CONNECTION'] -cne $script:AGY_SSH_MARK) { $bad28 += 'SSH marker not set' }
        if ([string]$v28['AGY_CLI_DISABLE_AUTO_UPDATE'] -cne 'true') { $bad28 += 'auto-update not disabled' }
        # signed in = its login file in its home
        if (Test-AgySignedIn) { $bad28 += 'signed in without a login file' }
        $tokDir28 = Join-Path $script:H 'agy/.gemini/antigravity-cli'
        New-Item -ItemType Directory -Path $tokDir28 -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $tokDir28 'antigravity-cli-oauth-token'), 'x')
        if (-not (Test-AgySignedIn)) { $bad28 += 'login file not recognised' }
        if ((Get-AgentStatus 'agy') -cne (T 'COMMON_STATUS_SIGNED_IN')) { $bad28 += ('status ' + (Get-AgentStatus 'agy')) }
        # the login file is in the logins archive, never in the conversations one
        Save-Vault
        if (@(Get-VaultListing | Where-Object { $_ -eq 'agy/.gemini/antigravity-cli/antigravity-cli-oauth-token' }).Count -lt 1) { $bad28 += 'login file not in the logins archive' }
        # the Credential Manager safety net is callable (empty off Windows)
        [AiUsbCredGuard]::SetBaseline()
        if ([AiUsbCredGuard]::CleanNew() -ne 0) { $bad28 += 'CleanNew removed something off Windows' }
        [AiUsbCredGuard]::ClearBaseline()
        if (@([AiUsbCredGuard]::List()).Count -ne 0) { $bad28 += 'List not empty off Windows' }
    } catch { $bad28 += ('threw: ' + $_.Exception.Message) }
    Add-Check '28 Antigravity: env, login file, legacy Gemini cleanup' ($bad28.Count -eq 0) ($bad28 -join '; ')
} catch {
    $script:Failed++
    Write-Host ('FAIL unexpected - ' + $_.Exception.Message)
} finally {
    # restore the vault id if the watcher check was interrupted, then drop the whole temp tree
    try {
        if ($script:V) {
            $vidMovedF = Join-Path $script:V 'vault.id.moved'
            if ((Test-Path -LiteralPath $vidMovedF) -and -not (Test-Path -LiteralPath (Join-Path $script:V 'vault.id'))) {
                Rename-Item -LiteralPath $vidMovedF -NewName 'vault.id'
            }
        }
    } catch { }
    if ($script:TmpRoot -and (Test-Path -LiteralPath $script:TmpRoot)) {
        try { Remove-Item -LiteralPath $script:TmpRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
    if ([string]::IsNullOrEmpty($savedSystemRoot)) {
        Remove-Item -Path 'Env:\SystemRoot' -ErrorAction SilentlyContinue
    } else {
        $env:SystemRoot = $savedSystemRoot
    }
}

Write-Host ('{0} passed, {1} failed' -f $script:Passed, $script:Failed)
if ($script:Failed -eq 0 -and $script:Passed -gt 0) { exit 0 }
exit 1
