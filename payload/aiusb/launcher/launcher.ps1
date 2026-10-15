# AI-USB Windows launcher (mode "windows").
# Started by "Start AI Agent.cmd":
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<USB>\aiusb\launcher\launcher.ps1"
# Optional -Lang <code> preselects the UI language (the elevated relaunch and tests use it).
# Implements docs/ARCHITECTURE.md section 5 for Windows. Windows PowerShell 5.1, ASCII only.

param([string]$Lang = '')

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------ paths
$script:USB = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:CONF = Join-Path $script:USB 'aiusb\aiusb.conf'
$script:V = Join-Path $script:USB 'aiusb\vault'
$script:LOGDIR = Join-Path $script:USB 'aiusb\logs'
$script:LOGFILE = Join-Path $script:LOGDIR 'launcher.log'
$script:CTXDIR = Join-Path $script:USB 'aiusb\context'
$script:WORKSPACE = Join-Path $script:USB 'aiusb\workspace'
$script:BINWIN = Join-Path $script:USB 'aiusb\bin\win-x64'
$script:AGYEXE = Join-Path $script:BINWIN 'agy.exe'
$script:AGE = Join-Path $script:BINWIN 'age.exe'
$script:AGEKEYGEN = Join-Path $script:BINWIN 'age-keygen.exe'
$script:TAREXE = Join-Path $env:SystemRoot 'System32\tar.exe'

# language files: aiusb\lang\en.txt (master) and one file per language; the
# selected language overlays English, so a key missing there keeps English text
$script:LangDir = Join-Path $script:USB 'aiusb\lang'
$script:UiLang = 'en'
$script:Txt = @{}

# environment variables that must never leak from the host into an agent
$script:UNSET_ENV = @(
    'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL',
    'CLAUDE_CODE_OAUTH_TOKEN', 'OPENAI_API_KEY', 'OPENAI_BASE_URL',
    'GEMINI_API_KEY', 'GOOGLE_API_KEY', 'GOOGLE_APPLICATION_CREDENTIALS',
    'CODEX_HOME', 'CLAUDE_CONFIG_DIR', 'GEMINI_CLI_HOME'
)

# Antigravity CLI (5.10): it keeps its Google login in the PC's keyring (Windows Credential
# Manager) unless it believes it runs over SSH; then it uses a file in its home, which is the
# agent home here (H\agy). It must not update itself either.
$script:AGY_SSH_MARK = '127.0.0.1 0 127.0.0.1 0'

# Caches, logs and files the agents download again at every start never go into the vault:
# it stays small, so unlock and save are quick. Same list as launcher.sh.
$script:VAULT_EXCLUDES = @(
    'claude/cache',
    'claude/debug',
    'claude/shell-snapshots',
    'claude/statsig',
    'claude/todos',
    'claude/file-history',
    'claude/paste-cache',
    'claude/image-cache',
    'claude/backups',
    'claude/telemetry',
    'claude/logs',
    'claude/plugins',
    'claude/skills/synced',
    'claude/sessions',
    'claude/session-env',
    'claude/ide',
    'claude/downloads',
    'claude-glm/cache',
    'claude-glm/debug',
    'claude-glm/shell-snapshots',
    'claude-glm/statsig',
    'claude-glm/todos',
    'claude-glm/file-history',
    'claude-glm/paste-cache',
    'claude-glm/image-cache',
    'claude-glm/backups',
    'claude-glm/telemetry',
    'claude-glm/logs',
    'claude-glm/plugins',
    'claude-glm/skills/synced',
    'claude-glm/sessions',
    'claude-glm/session-env',
    'claude-glm/ide',
    'claude-glm/downloads',
    'codex/tmp',
    'codex/.tmp',
    'codex/log',
    'codex/cache',
    'codex/plugins',
    'codex/packages',
    'codex/shell_snapshots',
    'codex/skills/.system',
    'codex/sqlite/logs_*',
    'codex/logs_*',
    'codex/state_*',
    'codex/goals_*',
    'codex/queue_*',
    'codex/memories_*',
    'codex/thread_history_*',
    'agy/.gemini/antigravity-cli/log',
    'agy/.gemini/antigravity-cli/crashes',
    'agy/.gemini/antigravity-cli/bin',
    'agy/.gemini/antigravity-cli/builtin',
    'agy/.gemini/antigravity-cli/updater',
    'agy/.gemini/antigravity-cli/cli.log',
    'agy/.gemini/antigravity-cli/last_check.timestamp',
    'agy/.cache'
)

# Conversation history (ARCHITECTURE 5.5.1): one archive per group,
# vault\history\<group>.tgz.age, opened only when an agent of that group starts, so unlocking
# stays fast however many conversations are saved. Same groups and paths as launcher.sh.
$script:HIST_GROUPS = @('claude', 'codex', 'agy')
$script:HIST_PATHS = @{
    'claude' = @('claude/projects', 'claude-glm/projects')
    'codex' = @('codex/sessions', 'codex/archived_sessions', 'codex/session_index.jsonl', 'codex/sqlite')
    'agy' = @('agy/.gemini/antigravity-cli/conversations', 'agy/.gemini/antigravity-cli/brain',
        'agy/.gemini/antigravity-cli/conversation_summaries.db', 'agy/.gemini/antigravity-cli/conversation_summaries.db-wal',
        'agy/.gemini/antigravity-cli/conversation_summaries.db-shm')
}
# Claude Code files its conversations under this one folder name on every PC and OS
# (CLAUDE_CODE_PROJECT_DIR_NAME), instead of one folder per workspace path.
$script:CLAUDE_PROJECT_DIR_NAME = 'aiusb-workspace'

# conf key -> environment variable for GLM model overrides
$script:GLM_MODEL_MAP = @(
    @('GLM_OPUS_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL'),
    @('GLM_SONNET_MODEL', 'ANTHROPIC_DEFAULT_SONNET_MODEL'),
    @('GLM_HAIKU_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL')
)

# mutable state
$script:S = ''
$script:H = ''
$script:T = ''
$script:Admin = $false
$script:Autonomous = $false
$script:SessionReady = $false
$script:OwnLock = $false
$script:OwnSession = $false   # true once the stale-session check ran: from then on S is ours to wipe
$script:UnlockError = ''      # message shown when Unlock-Vault fails
$script:Identity = ''         # the vault's private key, in this process's memory only (5.5)
$script:HistDirty = @{}       # history groups whose agent ran since their last save

try { $Host.UI.RawUI.WindowTitle = 'AISTiUSB' } catch { }

# ------------------------------------------------------------------ output helpers
function Write-Info {
    param([string]$Text)
    Write-Host $Text -ForegroundColor Gray
}

function Write-Ok {
    param([string]$Text)
    Write-Host $Text -ForegroundColor Green
}

function Write-Warn {
    param([string]$Text)
    Write-Host $Text -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Text)
    Write-Host $Text -ForegroundColor Red
}

function Show-Banner {
    # The stick's logo (aiusb\launcher\banner.txt); plain title if it is missing.
    Write-Host ''
    $file = Join-Path $PSScriptRoot 'banner.txt'
    $lines = @()
    try { $lines = [System.IO.File]::ReadAllLines($file) } catch { $lines = @() }
    if ($lines.Count -eq 0) { $lines = @('AISTiUSB - portable AI repair kit') }
    foreach ($l in $lines) { Write-Host $l -ForegroundColor Cyan }
}

function Write-Log {
    # Append one non-secret event line to launcher.log. Failures are ignored.
    param([string]$Text)
    try {
        if (-not (Test-Path -LiteralPath $script:LOGDIR)) {
            New-Item -ItemType Directory -Path $script:LOGDIR -Force | Out-Null
        }
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $line = '{0} windows {1} {2}' -f $stamp, $env:COMPUTERNAME, $Text
        Add-Content -LiteralPath $script:LOGFILE -Value $line -Encoding ASCII
    } catch { }
}

function Stop-Fatal {
    param([string]$Message)
    Write-Err $Message
    Write-Log ('fatal ' + $Message)
    Read-Host (T 'PS_PRESS_ENTER_CLOSE') | Out-Null
    exit 1
}

# ------------------------------------------------------------------ language files
function Read-LangFile {
    # Parse one language file into a hashtable (KEY -> text). UTF-8 without BOM;
    # the first '=' splits, '#' lines and empty lines are ignored. Missing file: empty.
    param([string]$Path)
    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $map }
    $lines = @()
    try { $lines = [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8) } catch { return $map }
    foreach ($line in $lines) {
        $t = $line.Trim()
        if ($t.Length -eq 0) { continue }
        if ($t.StartsWith('#')) { continue }
        $i = $line.IndexOf('=')
        if ($i -lt 1) { continue }
        $key = $line.Substring(0, $i).Trim()
        if ($key -notmatch '^[A-Z0-9_]+$') { continue }
        $map[$key] = $line.Substring($i + 1).TrimEnd("`r")
    }
    return $map
}

function Import-Lang {
    # Load English first, then overlay the selected language: a key missing in the
    # selected file keeps its English text.
    param([string]$Code)
    $map = Read-LangFile (Join-Path $script:LangDir 'en.txt')
    if ($Code -ne 'en') {
        $over = Read-LangFile (Join-Path $script:LangDir ($Code + '.txt'))
        foreach ($k in $over.Keys) { $map[$k] = $over[$k] }
    }
    $script:Txt = $map
    $script:UiLang = $Code
}

function T {
    # Text of a key in the current language; {0}, {1}, ... are replaced with the
    # remaining arguments (.Replace, never -f: texts may contain braces) and the
    # two characters \n become a line break. A key missing everywhere shows the
    # key itself, so a broken language file never crashes the launcher.
    param(
        [string]$Key,
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Values
    )
    if ($null -eq $Values) { $Values = @() }
    if (-not $script:Txt.ContainsKey($Key)) { return $Key }
    $s = [string]$script:Txt[$Key]
    for ($i = 0; $i -lt $Values.Count; $i++) {
        $s = $s.Replace(('{' + $i + '}'), [string]$Values[$i])
    }
    $s = $s.Replace('\n', "`n")
    return $s
}

function Test-LangCode {
    # Valid codes are the language files present in aiusb\lang that define
    # COMMON_LANG_NAME (at least en).
    param([string]$Code)
    if ($Code -eq '') { return $false }
    if ($Code -notmatch '^[a-z][a-z0-9-]*$') { return $false }
    $m = Read-LangFile (Join-Path $script:LangDir ($Code + '.txt'))
    return ($m.ContainsKey('COMMON_LANG_NAME') -and ($m['COMMON_LANG_NAME'] -ne ''))
}

function Read-CurrentLang {
    # lang\current holds the last chosen code; 'en' when missing or invalid.
    $p = Join-Path $script:LangDir 'current'
    $code = ''
    if (Test-Path -LiteralPath $p) {
        try {
            $lines = [System.IO.File]::ReadAllLines($p, [System.Text.Encoding]::UTF8)
            if ($lines.Count -gt 0) { $code = ([string]$lines[0]).Trim() }
        } catch { $code = '' }
    }
    if (Test-LangCode $code) { return $code }
    return 'en'
}

function Save-CurrentLang {
    # Remember the choice in lang\current; write errors are ignored.
    param([string]$Code)
    try {
        if (-not (Test-Path -LiteralPath $script:LangDir)) {
            New-Item -ItemType Directory -Path $script:LangDir -Force | Out-Null
        }
        [System.IO.File]::WriteAllText((Join-Path $script:LangDir 'current'), ($Code + "`r`n"), [System.Text.Encoding]::ASCII)
    } catch { }
}

function Select-Language {
    # Ask for the UI language, load its texts and remember the choice. The prompt
    # itself is fixed ASCII so it renders on every console; the name in brackets
    # comes from COMMON_LANG_NAME of the current language. Accepts 1/2/en/sk/empty;
    # anything else keeps the current language.
    $current = Read-CurrentLang
    Import-Lang $current
    $prompt = 'Language / Jazyk:  1) English   2) Slovencina   [Enter = ' + (T 'COMMON_LANG_NAME') + ']: '
    $c = (Read-Host $prompt).Trim()
    $pick = $current
    switch ($c.ToLower()) {
        '1' { $pick = 'en' }
        '2' { $pick = 'sk' }
        'en' { $pick = 'en' }
        'sk' { $pick = 'sk' }
        default { $pick = $current }
    }
    if (-not (Test-LangCode $pick)) { $pick = $current }
    if ($pick -ne $current) { Import-Lang $pick }
    Save-CurrentLang $pick
}

# ------------------------------------------------------------------ console guards (AiUsbConsole.cs)
# [AiUsbCtrlGuard]: while an agent runs, Ctrl+C belongs to the agent (otherwise the console
# would also stop this script and wipe the session under a still-running agent).
# [AiUsbCloseGuard]: closing the window with X (or log off / shut down) saves the vault,
# wipes the session and removes the lock inside the console's close handler, because
# PowerShell's finally blocks do not run then.
# Loaded after the elevation step (the non-elevated first window never needs them).
$script:CtrlGuard = $false
$script:CtrlGuardError = ''
$script:CtrlGuardSource = ''

function Import-ConsoleGuards {
    # Compiling AiUsbConsole.cs takes seconds on a slow PC, so it is compiled once per
    # version with the .NET Framework's own csc.exe into aiusb\launcher\cache and the DLL
    # is loaded on later starts. Falls back to compiling in memory (Add-Type).
    param([string]$Dir = $PSScriptRoot)
    $src = Join-Path $Dir 'AiUsbConsole.cs'
    $script:CtrlGuard = $false
    $script:CtrlGuardError = ''
    try {
        $bytes = [System.IO.File]::ReadAllBytes($src)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $digest = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
        $hex = (($digest[0..7] | ForEach-Object { $_.ToString('x2') }) -join '')
        $cacheDir = Join-Path $Dir 'cache'
        $name = 'AiUsbConsole-' + $hex + '-ps' + [string]$PSVersionTable.PSVersion.Major + '.dll'
        $dll = Join-Path $cacheDir $name
        if (Test-Path -LiteralPath $dll) {
            try {
                Add-Type -ErrorAction Stop -Path $dll
                $script:CtrlGuard = $true
                $script:CtrlGuardSource = 'cache'
                return
            } catch { }
        }
        $csc = Join-Path ([System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
        if (Test-Path -LiteralPath $csc) {
            try {
                if (-not (Test-Path -LiteralPath $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }
                foreach ($old in @(Get-ChildItem -LiteralPath $cacheDir -Filter 'AiUsbConsole-*' -File -ErrorAction SilentlyContinue)) {
                    try { Remove-Item -LiteralPath $old.FullName -Force -ErrorAction Stop } catch { }
                }
                $tmp = Join-Path $cacheDir ('AiUsbConsole-build-' + [System.IO.Path]::GetRandomFileName() + '.dll')
                & $csc '/nologo' '/target:library' '/optimize+' ('/out:' + $tmp) $src | Out-Null
                if (($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $tmp)) {
                    Move-Item -LiteralPath $tmp -Destination $dll -Force
                    Add-Type -ErrorAction Stop -Path $dll
                    $script:CtrlGuard = $true
                    $script:CtrlGuardSource = 'compiled'
                    return
                }
                if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
            } catch { }
        }
        Add-Type -ErrorAction Stop -Path $src
        $script:CtrlGuard = $true
        $script:CtrlGuardSource = 'memory'
    } catch {
        $script:CtrlGuard = $false
        $script:CtrlGuardError = ([string]$_.Exception.Message) -replace '\s+', ' '
    }
}

function Enable-CtrlGuard { if ($script:CtrlGuard) { try { [AiUsbCtrlGuard]::On() } catch { } } }
function Disable-CtrlGuard { if ($script:CtrlGuard) { try { [AiUsbCtrlGuard]::Off() } catch { } } }

# ------------------------------------------------------------------ config
function Get-Conf {
    # Parse aiusb.conf as plain text: KEY=VALUE, '#' comments. Never source it.
    param([string]$Key, [string]$Default = '')
    if (-not (Test-Path -LiteralPath $script:CONF)) { return $Default }
    $lines = @()
    try { $lines = [System.IO.File]::ReadAllLines($script:CONF) } catch { return $Default }
    foreach ($line in $lines) {
        $t = $line.Trim()
        if ($t.Length -eq 0) { continue }
        if ($t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -lt 1) { continue }
        if ($t.Substring(0, $i).Trim() -eq $Key) {
            return $t.Substring($i + 1).Trim()
        }
    }
    return $Default
}

# ------------------------------------------------------------------ hidden input
function Read-Secret {
    param([string]$Prompt)
    $sec = Read-Host -AsSecureString -Prompt $Prompt
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    $plain = ''
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    $sec.Dispose()
    return $plain
}

# ------------------------------------------------------------------ elevation
function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Elevate {
    if (Test-Admin) {
        $script:Admin = $true
        Write-Info (T 'PS_ELEVATED')
        return
    }
    Write-Info (T 'PS_ELEVATING')
    try {
        $quoted = '"{0}"' -f $PSCommandPath
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $quoted, '-Lang', $script:UiLang) | Out-Null
        Write-Log 'start elevated-relaunch'
        exit 0
    } catch {
        $script:Admin = $false
        Write-Warn (T 'PS_ELEVATE_DECLINED')
        return
    }
}

# ------------------------------------------------------------------ session dirs
function Initialize-Session {
    $script:S = Join-Path $script:USB 'aiusb\session'
    $script:H = Join-Path $script:S 'home'
    $script:T = Join-Path $script:S 'tmp'
    foreach ($d in @($script:S, $script:H, $script:T)) {
        if (-not (Test-Path -LiteralPath $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }
}

# ------------------------------------------------------------------ native calls
function Invoke-Native {
    # Run a native exe with an argument array; check $LASTEXITCODE.
    # No redirection of stdin/stdout/stderr so age can prompt on the console.
    param([string]$Exe, [string[]]$Arguments)
    & $Exe @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw (T 'PS_ERR_NATIVE' ([string]$LASTEXITCODE) $Exe)
    }
}

function Invoke-AgeInput {
    # Run age with $InputText on its standard input: the vault's private key goes through a
    # pipe and is never written to the stick or the PC. age still prompts on the console.
    param([string[]]$Arguments, [string]$InputText)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:AGE
    $psi.Arguments = ($Arguments | ForEach-Object { ConvertTo-WinArg $_ }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    # .NET Framework writes the redirected stdin with the console's input encoding and puts a
    # byte order mark first when that is UTF-8 (code page 65001); age would then reject the
    # key. ASCII has no byte order mark: use it while the process starts, then restore.
    $savedEncoding = $null
    try { $savedEncoding = [Console]::InputEncoding; [Console]::InputEncoding = [System.Text.Encoding]::ASCII } catch { $savedEncoding = $null }
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } finally {
        if ($null -ne $savedEncoding) { try { [Console]::InputEncoding = $savedEncoding } catch { } }
    }
    if ($null -eq $proc) { throw (T 'PS_ERR_PROC_START') }
    try {
        $proc.StandardInput.Write($InputText)
        $proc.StandardInput.Close()
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) { throw (T 'PS_ERR_NATIVE' ([string]$proc.ExitCode) $script:AGE) }
    } finally {
        $proc.Dispose()
    }
}

# ------------------------------------------------------------------ vault operations
function New-Vault {
    Write-Host ''
    Write-Host (T 'COMMON_FIRST_RUN')
    Write-Host ''
    Write-Host (T 'PS_NEWVAULT_TITLE') -ForegroundColor Cyan
    Write-Info (T 'PS_PASS_PROTECTS')
    Write-Info (T 'PS_PASS_NORECOVER')
    Write-Info (T 'PS_PASS_CHARS')
    Write-Info (T 'PS_PASS_TWICE')
    Write-Host ''

    if (-not (Test-Path -LiteralPath $script:V)) {
        New-Item -ItemType Directory -Path $script:V -Force | Out-Null
    }
    $recNew = Join-Path $script:V 'recipient.txt.new'
    $idNew = Join-Path $script:V 'identity.age.new'

    Write-Info (T 'PS_PASS_NOTEMPTY')
    try {
        # the private key stays in memory: age-keygen prints it, age reads it from a pipe
        $keyLines = @(& $script:AGEKEYGEN)
        if ($LASTEXITCODE -ne 0) { throw (T 'PS_ERR_NATIVE' ([string]$LASTEXITCODE) $script:AGEKEYGEN) }
        $recipient = ''
        foreach ($l in $keyLines) {
            if ([string]$l -match '^# public key: (age1[0-9a-z]+)\s*$') { $recipient = $Matches[1] }
        }
        $script:Identity = ($keyLines -join "`n") + "`n"
        if (($recipient -eq '') -or (-not $script:Identity.Contains('AGE-SECRET-KEY-'))) {
            throw 'age-keygen printed no key'
        }
        [System.IO.File]::WriteAllText($recNew, ($recipient + "`n"), [System.Text.Encoding]::ASCII)
        # age itself asks for the new passphrase twice on the terminal
        Invoke-AgeInput @('-p', '-o', $idNew) $script:Identity
    } catch {
        foreach ($f in @($recNew, $idNew)) {
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
        }
        throw
    }

    Move-Item -LiteralPath $recNew -Destination (Join-Path $script:V 'recipient.txt') -Force
    Move-Item -LiteralPath $idNew -Destination (Join-Path $script:V 'identity.age') -Force

    # random 32-hex-char vault id
    $bytes = New-Object 'byte[]' 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $hexParts = @()
    foreach ($b in $bytes) { $hexParts += $b.ToString('x2') }
    [System.IO.File]::WriteAllText((Join-Path $script:V 'vault.id'), ($hexParts -join ''))

    Write-Ok (T 'PS_VAULT_CREATED')
    Write-Log 'vault-created'
}

function Unlock-Identity {
    # Ask for the passphrase (age prompts on the console itself) and keep the vault's
    # private key in this process's memory, so the history archives open later without
    # asking again. It is never written to the stick or the PC.
    $idFile = Join-Path $script:V 'identity.age'
    $attempt = 0
    while ($attempt -lt 3) {
        $attempt++
        $out = @()
        $rc = 1
        try {
            $out = @(& $script:AGE '-d' $idFile)
            $rc = $LASTEXITCODE
        } catch { $rc = 1 }
        $text = ($out -join "`n")
        if (($rc -eq 0) -and $text.Contains('AGE-SECRET-KEY-')) {
            $script:Identity = $text + "`n"
            return $true
        }
        if ($attempt -lt 3) { Write-Warn (T 'PS_PASS_RETRY' ([string]$attempt)) }
    }
    return $false
}

function Unlock-Vault {
    $enc = Join-Path $script:V 'home.tar.age'
    $tarTmp = Join-Path $script:S 'home.tar'

    if (-not (Test-Path -LiteralPath $enc)) {
        $bak = Join-Path $script:V 'home.tar.age.bak'
        if (Test-Path -LiteralPath $bak) {
            $answer = Read-Host (T 'PS_RESTORE_ASK')
            if ($answer -match '^[Yy]') {
                Copy-Item -LiteralPath $bak -Destination $enc -Force
            }
        }
        if (-not (Test-Path -LiteralPath $enc)) {
            Write-Warn (T 'PS_NO_SIGNINS')
            return $true
        }
    }

    Write-Info (T 'PS_KBD_TIP')
    if ($script:Identity -eq '') {
        if (-not (Unlock-Identity)) {
            $script:UnlockError = T 'PS_UNLOCK_FAIL'
            Write-Log 'unlock-fail'
            return $false
        }
    }
    # The passphrase was right; a failure from here on is an unpacking problem.
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Invoke-AgeInput @('-d', '-i', '-', '-o', $tarTmp, $enc) $script:Identity
        Expand-HomeTar $tarTmp
    } catch {
        $script:UnlockError = T 'PS_ERR_UNPACK' $_.Exception.Message
        Write-Log 'unpack-fail'
        return $false
    } finally {
        if (Test-Path -LiteralPath $tarTmp) { Remove-Item -LiteralPath $tarTmp -Force }
    }
    Write-Ok (T 'PS_VAULT_UNLOCKED')
    Write-Log ('unlock-ok ' + [string]$sw.ElapsedMilliseconds + 'ms')
    return $true
}

function Expand-HomeTar {
    # Unpack the decrypted home into H. Vaults saved by older versions contain a './' root
    # member; extracting that on Windows creates an undeletable entry named '.' on exFAT.
    # Windows' tar.exe has no -s (built without regex), so for such archives extract by
    # naming their top-level entries (everything except './' itself).
    param([string]$TarFile)
    $entries = @(& $script:TAREXE '-tf' $TarFile)
    if ($LASTEXITCODE -ne 0) { throw (T 'PS_ERR_TAR_LIST' ([string]$LASTEXITCODE)) }
    $hasRoot = $false
    $tops = @()
    foreach ($e in $entries) {
        $name = [string]$e
        if (($name -eq './') -or ($name -eq '.')) { $hasRoot = $true; continue }
        $prefix = ''
        if ($name.StartsWith('./')) { $prefix = './'; $name = $name.Substring(2) }
        $first = ($name -split '/')[0]
        if ($first -eq '') { continue }
        $pattern = $prefix + $first
        if ($tops -notcontains $pattern) { $tops += $pattern }
    }
    $tarArgs = @('-xf', $TarFile, '-C', $script:H)
    if ($hasRoot) {
        if ($tops.Count -eq 0) { return }
        $tarArgs += $tops
    }
    Invoke-Native $script:TAREXE $tarArgs
}

function Save-Vault {
    # Re-encrypt H to the vault using the public key. Needs no passphrase. Saves the logins
    # and settings, then the given history groups (-Recover: every group, for a session left
    # over by a crash, an unplug or another OS). Throws when any part failed.
    # Shares a lock with the window-close handler: if the window is being closed, that
    # handler does the final save and this call does nothing.
    param([string[]]$Groups = @(), [switch]$Recover)
    $locked = $false
    if ($script:CtrlGuard) {
        try { $locked = [AiUsbCloseGuard]::EnterSave(5000) } catch { $locked = $false }
        if (-not $locked) { return }
    }
    try {
        Save-VaultNow
        $list = @($Groups)
        if ($Recover) { $list = @($script:HIST_GROUPS) }
        $failed = @()
        foreach ($g in $list) {
            if (-not (Test-HistorySave $g)) { continue }
            if (Save-History $g) {
                Set-HistoryDirty $g $false
            } else {
                $failed += (Get-HistoryLabel $g)
            }
        }
        if ($failed.Count -gt 0) { throw (T 'COMMON_HIST_SAVE_FAIL' ($failed -join ', ')) }
    } finally {
        if ($locked) { try { [AiUsbCloseGuard]::ExitSave() } catch { } }
    }
}

# ------------------------------------------------------------------ conversation history (5.5.1)
function Get-HistoryLabel {
    param([string]$Group)
    switch ($Group) {
        'claude' { return 'Claude' }
        'codex' { return 'Codex' }
        'agy' { return 'Antigravity' }
    }
    return $Group
}

function Get-HistoryArchive {
    param([string]$Group)
    return (Join-Path (Join-Path $script:V 'history') ($Group + '.tgz.age'))
}

function Get-HistoryMarker {
    # present while the group's archive is open in this session: only then may it be saved
    param([string]$Group)
    return (Join-Path $script:H ('.aiusb-loaded-' + $Group))
}

function Get-CoreExcludes {
    # the logins archive leaves out the junk, the history groups and the session markers
    $list = @($script:VAULT_EXCLUDES)
    foreach ($g in $script:HIST_GROUPS) { $list += @($script:HIST_PATHS[$g]) }
    $list += '.aiusb-loaded-*'
    return $list
}

function Test-HistorySave {
    # Write group $Group now? Only when its archive was opened this session, or when the
    # vault has none yet and the session holds data (first save, or a session left by an
    # older launcher). An archive that could not be opened is never overwritten.
    param([string]$Group)
    if (Test-Path -LiteralPath (Get-HistoryMarker $Group)) { return $true }
    if (Test-Path -LiteralPath (Get-HistoryArchive $Group)) { return $false }
    foreach ($p in @($script:HIST_PATHS[$Group])) {
        if (Test-Path -LiteralPath (Join-Path $script:H $p)) { return $true }
    }
    return $false
}

function Set-HistoryDirty {
    param([string]$Group, [bool]$Dirty)
    if ($Dirty) { $script:HistDirty[$Group] = $true } else { $script:HistDirty.Remove($Group) }
    if ($script:CtrlGuard) { try { [AiUsbCloseGuard]::SetDirty($Group, $Dirty) } catch { } }
}

function Import-History {
    # Open group $Group's archive into H, once per session; the marker allows saving it.
    param([string]$Group)
    $marker = Get-HistoryMarker $Group
    if (Test-Path -LiteralPath $marker) { return $true }
    $archive = Get-HistoryArchive $Group
    if ((-not (Test-Path -LiteralPath $archive)) -and (Test-Path -LiteralPath ($archive + '.bak'))) {
        $archive = $archive + '.bak'
    }
    if (Test-Path -LiteralPath $archive) {
        $label = Get-HistoryLabel $Group
        if ($script:Identity -eq '') {
            if (-not (Unlock-Identity)) {
                Write-Warn (T 'COMMON_HIST_LOAD_FAIL' $label)
                return $false
            }
        }
        Write-Info (T 'COMMON_HIST_LOADING' $label)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $tgz = Join-Path $script:S ('hist-' + $Group + '.tgz')
        try {
            Invoke-AgeInput @('-d', '-i', '-', '-o', $tgz, $archive) $script:Identity
            Invoke-Native $script:TAREXE @('-xf', $tgz, '-C', $script:H)
        } catch {
            Write-Warn (T 'COMMON_HIST_LOAD_FAIL' $label)
            Write-Log ('history-load-fail ' + $Group)
            return $false
        } finally {
            if (Test-Path -LiteralPath $tgz) { Remove-Item -LiteralPath $tgz -Force }
        }
        Write-Log ('history-load ' + $Group + ' ' + [string]$sw.ElapsedMilliseconds + 'ms')
    }
    [System.IO.File]::WriteAllText($marker, '')
    return $true
}

function Save-History {
    # Save group $Group: gzip tar of its paths, encrypted to the vault's public key.
    # Returns $true when saved (or nothing to save), $false on failure.
    param([string]$Group)
    $final = Get-HistoryArchive $Group
    $newPath = $final + '.new'
    $bakPath = $final + '.bak'
    $members = @()
    foreach ($p in @($script:HIST_PATHS[$Group])) {
        if (Test-Path -LiteralPath (Join-Path $script:H $p)) { $members += $p }
    }
    if ($members.Count -eq 0) {
        # the group's folders were deleted on purpose: so are its archives (a .bak would be
        # opened again next time)
        foreach ($f in @($final, $bakPath)) {
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
        }
        return $true
    }
    $hdir = Join-Path $script:V 'history'
    if (-not (Test-Path -LiteralPath $hdir)) { New-Item -ItemType Directory -Path $hdir -Force | Out-Null }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $tgz = Join-Path $script:S ('hist-' + $Group + '.tgz')
    $tarArgs = @('-czf', $tgz)
    foreach ($e in $script:VAULT_EXCLUDES) { $tarArgs += @('--exclude', $e) }
    $tarArgs += @('-C', $script:H) + $members
    try {
        Invoke-Native $script:TAREXE $tarArgs
        Invoke-Native $script:AGE @('-R', (Join-Path $script:V 'recipient.txt'), '-o', $newPath, $tgz)
        if ((Get-Item -LiteralPath $newPath).Length -le 0) { throw (T 'PS_ERR_VAULT_EMPTY') }
    } catch {
        if (Test-Path -LiteralPath $newPath) { Remove-Item -LiteralPath $newPath -Force }
        Write-Log ('history-save-fail ' + $Group)
        return $false
    } finally {
        if (Test-Path -LiteralPath $tgz) { Remove-Item -LiteralPath $tgz -Force }
    }
    if (Test-Path -LiteralPath $final) { Move-Item -LiteralPath $final -Destination $bakPath -Force }
    Move-Item -LiteralPath $newPath -Destination $final -Force
    Write-Log ('history-save ' + $Group + ' ' + [string]$sw.ElapsedMilliseconds + 'ms')
    return $true
}

function Get-AgentGroups {
    # the history groups an agent uses; the shell can start any agent
    param([string]$Agent)
    switch ($Agent) {
        'claude' { return @('claude') }
        'glm' { return @('claude') }
        'codex' { return @('codex') }
        'agy' { return @('agy') }
        'shell' { return @($script:HIST_GROUPS) }
    }
    return @()
}

function Merge-Tree {
    # Move Source's entries into Target; on a clash the newer file wins.
    param([string]$Source, [string]$Target)
    if (-not (Test-Path -LiteralPath $Target)) { New-Item -ItemType Directory -Path $Target -Force | Out-Null }
    foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force)) {
        $dest = Join-Path $Target $item.Name
        if (-not (Test-Path -LiteralPath $dest)) {
            Move-Item -LiteralPath $item.FullName -Destination $dest
        } elseif ($item.PSIsContainer -and (Test-Path -LiteralPath $dest -PathType Container)) {
            Merge-Tree $item.FullName $dest
        } elseif ((-not $item.PSIsContainer) -and (Test-Path -LiteralPath $dest -PathType Leaf) -and
            ($item.LastWriteTimeUtc -gt (Get-Item -LiteralPath $dest -Force).LastWriteTimeUtc)) {
            Move-Item -LiteralPath $item.FullName -Destination $dest -Force
        } else {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force
        }
    }
    try { [System.IO.Directory]::Delete($Source, $false) } catch { }
}

function Merge-ClaudeProjects {
    # Conversations from before CLAUDE_CODE_PROJECT_DIR_NAME sit in folders named after the
    # workspace path of that PC (E--aiusb-workspace, -run-media-...-aiusb-workspace): move
    # them into the one folder Claude Code now uses everywhere.
    foreach ($cfg in @('claude', 'claude-glm')) {
        $proj = Join-Path (Join-Path $script:H $cfg) 'projects'
        if (-not (Test-Path -LiteralPath $proj)) { continue }
        foreach ($d in @(Get-ChildItem -LiteralPath $proj -Directory -Force | Where-Object { $_.Name -like '*-aiusb-workspace' })) {
            try { Merge-Tree $d.FullName (Join-Path $proj $script:CLAUDE_PROJECT_DIR_NAME) } catch { }
        }
    }
}

function Set-AgyEnv {
    # Antigravity's home is the agent home H\agy (config, login file, conversations); the
    # SSH marker keeps its login out of the Credential Manager; no self-update.
    param([System.Collections.Specialized.StringDictionary]$Vars)
    $agyHome = Join-Path $script:H 'agy'
    $Vars['USERPROFILE'] = $agyHome
    $Vars['HOME'] = $agyHome
    $Vars['SSH_CONNECTION'] = $script:AGY_SSH_MARK
    $Vars['AGY_CLI_DISABLE_AUTO_UPDATE'] = 'true'
}

function Test-AgySignedIn {
    $dir = Join-Path (Join-Path $script:H 'agy') '.gemini'
    if (-not (Test-Path -LiteralPath $dir)) { return $false }
    $hit = @(Get-ChildItem -LiteralPath $dir -Recurse -Force -File -Filter '*oauth-token*' -ErrorAction SilentlyContinue)
    return ($hit.Count -gt 0)
}

function Start-AgyCredWatch {
    # Safety net for the Credential Manager, see AiUsbCredGuard in AiUsbConsole.cs.
    if ($script:CtrlGuard) { try { [AiUsbCredGuard]::SetBaseline() } catch { } }
}

function Stop-AgyCredWatch {
    if (-not $script:CtrlGuard) { return }
    try {
        $n = [AiUsbCredGuard]::CleanNew()
        if ($n -gt 0) { Write-Log ('agy-credman-removed ' + [string]$n) }
        [AiUsbCredGuard]::ClearBaseline()
    } catch { }
}

function Save-VaultNow {
    $recipient = Join-Path $script:V 'recipient.txt'
    if (-not (Test-Path -LiteralPath $recipient)) {
        throw (T 'PS_ERR_VAULT_INCOMPLETE')
    }
    $tarTmp = Join-Path $script:S 'home.tar'
    $newPath = Join-Path $script:V 'home.tar.age.new'
    $curPath = Join-Path $script:V 'home.tar.age'
    $bakPath = Join-Path $script:V 'home.tar.age.bak'

    # Archive the top-level names, not '.': a './' member makes tar.exe create an
    # undeletable entry literally named '.' on the exFAT stick.
    $names = @(Get-ChildItem -LiteralPath $script:H -Force | ForEach-Object { $_.Name })
    if ($names.Count -eq 0) { throw (T 'PS_ERR_NOTHING_SAVE') }
    $tarArgs = @('-cf', $tarTmp)
    foreach ($e in (Get-CoreExcludes)) { $tarArgs += @('--exclude', $e) }
    $tarArgs += @('-C', $script:H) + $names
    try {
        Invoke-Native $script:TAREXE $tarArgs
        Invoke-Native $script:AGE @('-R', $recipient, '-o', $newPath, $tarTmp)
    } catch {
        if (Test-Path -LiteralPath $newPath) { Remove-Item -LiteralPath $newPath -Force }
        throw
    } finally {
        if (Test-Path -LiteralPath $tarTmp) { Remove-Item -LiteralPath $tarTmp -Force }
    }

    $item = Get-Item -LiteralPath $newPath
    if ($item.Length -le 0) { throw (T 'PS_ERR_VAULT_EMPTY') }

    if (Test-Path -LiteralPath $curPath) {
        Move-Item -LiteralPath $curPath -Destination $bakPath -Force
    }
    Move-Item -LiteralPath $newPath -Destination $curPath -Force
    Write-Log 'save-ok'
}

function Remove-Tree {
    # Delete a folder tree on the stick. Remove-Item -Recurse is unreliable on removable
    # exFAT drives (handles from Defender/indexer, "directory not empty"), so retry with
    # .NET and cmd's rd after clearing read-only/hidden attributes.
    param([string]$Path)
    $cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
    for ($i = 0; $i -lt 5; $i++) {
        if (-not (Test-Path -LiteralPath $Path)) { return $true }
        try { [System.IO.Directory]::Delete($Path, $true) } catch { }
        if (-not (Test-Path -LiteralPath $Path)) { return $true }
        try {
            & $cmd /d /c ('attrib -r -h -s "{0}\*" /s /d >nul 2>nul & rd /s /q "{0}" >nul 2>nul' -f $Path) | Out-Null
        } catch { }
        if (-not (Test-Path -LiteralPath $Path)) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return (-not (Test-Path -LiteralPath $Path))
}

function Set-VaultPassphrase {
    # The private key is in memory since the unlock: only the new passphrase is asked.
    Write-Info (T 'PS_PASS_CHANGE_INFO')
    if ($script:Identity -eq '') {
        if (-not (Unlock-Identity)) { throw (T 'PS_UNLOCK_FAIL') }
    }
    $newPath = Join-Path $script:V 'identity.age.new'
    try {
        Invoke-AgeInput @('-p', '-o', $newPath) $script:Identity
    } catch {
        if (Test-Path -LiteralPath $newPath) { Remove-Item -LiteralPath $newPath -Force }
        throw
    }
    Move-Item -LiteralPath $newPath -Destination (Join-Path $script:V 'identity.age') -Force
    Write-Ok (T 'PS_PASS_CHANGED')
    Write-Log 'passphrase-changed'
}

function Reset-Vault {
    Write-Warn (T 'PS_RESET_WARN')
    $answer = Read-Host (T 'PS_RESET_ASK')
    if ($answer -cne 'RESET') {
        Write-Info (T 'PS_RESET_CANCELLED')
        return
    }
    foreach ($name in @('identity.age', 'recipient.txt', 'vault.id')) {
        $p = Join-Path $script:V $name
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    }
    Get-ChildItem -LiteralPath $script:V -Filter 'home.tar.age*' -File -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force
    }
    $hdir = Join-Path $script:V 'history'
    if (Test-Path -LiteralPath $hdir) { $null = Remove-Tree $hdir }
    $script:Identity = ''
    $script:HistDirty = @{}
    $script:SessionReady = $false
    $script:OwnLock = $false
    try { Clear-Session } catch { }
    try { Remove-Lock } catch { }
    Write-Log 'vault-reset'
    Write-Info (T 'PS_RESET_DONE')
    Read-Host (T 'PS_PRESS_ENTER_CLOSE') | Out-Null
    exit 0
}

# ------------------------------------------------------------------ lock and stale sessions
# Session switching: every start gets a clean new session, on any OS, without
# questions. Leftovers of the previous session are saved into the vault first
# (they may be newer), then wiped. The only stop is a launcher of this stick
# really running right now in another window on this same PC.
#
# Common lock format (session.lock, one line, written by both launchers):
#   host=<hostname> os=<windows|linux|rescue> pid=<launcher pid> started=<UTC yyyy-MM-ddTHH:mm:ssZ>
# Older formats are still read (the same KEY=VALUE pairs one per line, os=Linux,
# started= in local time without Z): the whole text is split on whitespace and
# key=value tokens are taken, the first '=' splits.

function Read-LockInfo {
    # Hashtable with host/os/pid/started (strings, empty when missing),
    # or $null when there is no lock file.
    $path = Join-Path $script:V 'session.lock'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $text = ''
    try { $text = [System.IO.File]::ReadAllText($path) } catch { $text = '' }
    $info = @{}
    $info['host'] = ''
    $info['os'] = ''
    $info['pid'] = ''
    $info['started'] = ''
    foreach ($token in ($text -split '\s+')) {
        $i = $token.IndexOf('=')
        if ($i -lt 1) { continue }
        $key = $token.Substring(0, $i)
        $value = $token.Substring($i + 1)
        switch ($key) {
            'host' { $info['host'] = $value }
            'os' { $info['os'] = $value }
            'pid' { $info['pid'] = $value }
            'started' { $info['started'] = $value }
        }
    }
    return $info
}

function Test-LockLive {
    # Live = this PC + this launcher family (windows) + a running powershell/
    # pwsh process that is not us and started near the lock's start time.
    param($Info)
    if ($null -eq $Info) { return $false }
    $lockHost = ([string]$Info['host']).Trim()
    $lockOs = ([string]$Info['os']).Trim()
    $lockPidText = ([string]$Info['pid']).Trim()
    $lockStarted = ([string]$Info['started']).Trim()
    if ($lockHost -eq '') { return $false }
    if ($lockHost.ToLower() -ne ([string]$env:COMPUTERNAME).ToLower()) { return $false }
    if ($lockOs.ToLower() -ne 'windows') { return $false }
    $lockPid = 0
    if (-not [int]::TryParse($lockPidText, [ref]$lockPid)) { return $false }
    if ($lockPid -eq $PID) { return $false }
    $proc = $null
    try { $proc = Get-Process -Id $lockPid -ErrorAction Stop } catch { $proc = $null }
    if ($null -eq $proc) { return $false }
    if (($proc.ProcessName -ne 'powershell') -and ($proc.ProcessName -ne 'pwsh')) { return $false }
    # Pid-reuse guard. Old locks store a local time without Z, new locks a UTC
    # time with Z; TryParse normalizes both kinds, so compare both sides in UTC.
    $started = New-Object DateTime
    if (($lockStarted -ne '') -and [datetime]::TryParse($lockStarted, [ref]$started)) {
        try {
            $procStartUtc = $proc.StartTime.ToUniversalTime()
            $startedUtc = $started.ToUniversalTime()
            if ([math]::Abs(($procStartUtc - $startedUtc).TotalSeconds) -gt 120) { return $false }
        } catch { }
    }
    return $true
}

function Resolve-Lock {
    # No lock: nothing to do. Live lock: this PC already has the stick open.
    # Anything else is a leftover from another PC, OS or crash: clean it up.
    $info = Read-LockInfo
    if ($null -eq $info) { return }
    if (Test-LockLive $info) {
        Write-Warn (T 'PS_LOCK_LIVE')
        Read-Host (T 'PS_PRESS_ENTER_CLOSE') | Out-Null
        exit 0
    }
    Write-Info (T 'PS_LOCK_STALE' ([string]$info['host']) ([string]$info['os']))
}

function Write-Lock {
    $text = 'host={0} os=windows pid={1} started={2}' -f $env:COMPUTERNAME, $PID, (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    [System.IO.File]::WriteAllText((Join-Path $script:V 'session.lock'), ($text + "`r`n"), [System.Text.Encoding]::ASCII)
    $script:OwnLock = $true
}

function Move-SessionAside {
    # Rename the session folder aside, so the next steps get a fresh, empty one.
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $target = Join-Path $script:USB ('aiusb\session-old-' + $stamp)
    try {
        [System.IO.Directory]::Move($script:S, $target)
        return $true
    } catch {
        return $false
    }
}

function Clear-Session {
    # Wipe the decrypted session. Refuse unexpected or empty paths.
    $expected = Join-Path $script:USB 'aiusb\session'
    if ([string]::IsNullOrEmpty($script:S) -or ($script:S -ne $expected)) {
        Write-Err (T 'PS_REFUSE_WIPE')
        return
    }
    # the vault id first: a half-wiped session must never be saved over the vault
    $sidFile = Join-Path (Join-Path $script:S 'home') '.aiusb-vault-id'
    try { if (Test-Path -LiteralPath $sidFile) { Remove-Item -LiteralPath $sidFile -Force } } catch { }
    if (Remove-Tree $script:S) { return }
    if (Move-SessionAside) { return }
    Write-Warn (T 'PS_SESSION_BUSY')
}

function Remove-OldSessions {
    # Best-effort removal of leftover session-old-* folders; silent, never throws.
    try {
        $pattern = Join-Path $script:USB 'aiusb\session-old-*'
        $dirs = @(Get-ChildItem -Path $pattern -Directory -ErrorAction SilentlyContinue)
        foreach ($d in $dirs) {
            try { $null = Remove-Tree $d.FullName } catch { }
        }
    } catch { }
}

function Remove-Lock {
    $p = Join-Path $script:V 'session.lock'
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
}

function Restore-StaleSession {
    # A session that survived a crash holds the newest tokens. Recover it.
    $sidFile = Join-Path $script:H '.aiusb-vault-id'
    $vidFile = Join-Path $script:V 'vault.id'
    if (-not (Test-Path -LiteralPath $sidFile)) {
        # Leftovers without a vault id (e.g. an interrupted first run) hold no newer logins.
        Clear-Session
        Initialize-Session
        return
    }

    $sid = ''
    try { $sid = ([System.IO.File]::ReadAllText($sidFile)).Trim() } catch { $sid = '' }
    $vid = ''
    if (Test-Path -LiteralPath $vidFile) {
        try { $vid = ([System.IO.File]::ReadAllText($vidFile)).Trim() } catch { $vid = '' }
    }

    if (($vid -ne '') -and ($sid -eq $vid)) {
        Write-Warn (T 'PS_STALE_FOUND')
        Write-Info (T 'PS_STALE_SAVING')
        try { Save-Vault -Recover } catch { Write-Err (T 'PS_STALE_SAVE_FAIL') }
    } else {
        Write-Warn (T 'PS_STALE_MISMATCH')
    }
    Clear-Session
    Initialize-Session
}

# ------------------------------------------------------------------ agent home skeleton
function Initialize-Home {
    foreach ($d in @('claude', 'claude-glm', 'anthropic', 'codex', 'agy', 'secrets')) {
        $p = Join-Path $script:H $d
        if (-not (Test-Path -LiteralPath $p)) {
            New-Item -ItemType Directory -Path $p -Force | Out-Null
        }
    }
    # The Gemini CLI was replaced by Antigravity: drop what it left in the vault.
    $legacy = Join-Path $script:H 'gemini'
    if (Test-Path -LiteralPath $legacy) { $null = Remove-Tree $legacy }
    foreach ($f in @('gemini.tgz.age', 'gemini.tgz.age.bak')) {
        $hp = Join-Path (Join-Path $script:V 'history') $f
        if (Test-Path -LiteralPath $hp) { try { Remove-Item -LiteralPath $hp -Force } catch { } }
    }
    # keep a copy of the vault id inside the home for stale-session recovery
    $vidFile = Join-Path $script:V 'vault.id'
    $sidFile = Join-Path $script:H '.aiusb-vault-id'
    if (Test-Path -LiteralPath $vidFile) {
        [System.IO.File]::WriteAllText($sidFile, ([System.IO.File]::ReadAllText($vidFile)).Trim())
    }
    # codex config.toml: force file-based credential storage
    $cfg = Join-Path $script:H 'codex\config.toml'
    $lines = @()
    if (Test-Path -LiteralPath $cfg) {
        $lines = [System.IO.File]::ReadAllLines($cfg)
    }
    # TOML: top-level keys must come before any [table], so they always go first.
    $newLines = @('cli_auth_credentials_store = "file"', 'mcp_oauth_credentials_store = "file"')
    foreach ($l in $lines) {
        if ($l -match '^\s*(cli_auth_credentials_store|mcp_oauth_credentials_store)\s*=') { continue }
        $newLines += $l
    }
    $text = ($newLines -join "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($cfg, $text, (New-Object System.Text.UTF8Encoding($false)))
}

# ------------------------------------------------------------------ roots and context
function Get-FixedDrives {
    # Local fixed drives as 'C:\', from .NET (WMI can take seconds to answer on a slow PC).
    $list = @()
    try {
        foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
            if ($d.DriveType -eq [System.IO.DriveType]::Fixed) { $list += $d.Name }
        }
    } catch { }
    return $list
}

function Get-OsText {
    # From the registry (WMI can take seconds on a slow PC). Windows 11 still reports
    # "Windows 10" as ProductName; its build numbers start at 22000.
    try {
        $key = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $name = [string][Microsoft.Win32.Registry]::GetValue($key, 'ProductName', '')
        $build = [string][Microsoft.Win32.Registry]::GetValue($key, 'CurrentBuild', '')
        $display = [string][Microsoft.Win32.Registry]::GetValue($key, 'DisplayVersion', '')
        if ($name -eq '') { return 'Windows (version unknown)' }
        $b = 0
        if ([int]::TryParse($build, [ref]$b) -and ($b -ge 22000)) { $name = $name -replace 'Windows 10', 'Windows 11' }
        $text = $name
        if ($display -ne '') { $text = $text + ' ' + $display }
        if ($build -ne '') { $text = $text + ' (build ' + $build + ')' }
        return $text
    } catch {
        return 'Windows (version unknown)'
    }
}

function Get-Roots {
    # Every local fixed drive plus the stick itself.
    $roots = @(Get-FixedDrives)
    $usbRoot = $script:USB.TrimEnd('\') + '\'
    $found = $false
    foreach ($r in $roots) {
        if ($r.TrimEnd('\').ToLower() -eq $usbRoot.TrimEnd('\').ToLower()) { $found = $true }
    }
    if (-not $found) { $roots += $usbRoot }
    return $roots
}

function Get-Context {
    param([string]$Agent = '')
    $sb = New-Object System.Text.StringBuilder
    $baseFile = Join-Path $script:CTXDIR 'host-windows.md'
    if (Test-Path -LiteralPath $baseFile) {
        [void]$sb.AppendLine([System.IO.File]::ReadAllText($baseFile))
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## This machine (generated)')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine(('- Host: {0} (Windows, plug-in launcher mode)' -f $env:COMPUTERNAME))
    [void]$sb.AppendLine(('- OS: ' + (Get-OsText)))
    $adm = 'no'
    if ($script:Admin) { $adm = 'yes' }
    [void]$sb.AppendLine(('- Administrator rights: {0}' -f $adm))
    # this section stays English (agents read it); it names the user's language
    $langName = $script:UiLang
    if ($langName -eq 'en') { $langName = 'English' }
    if ($langName -eq 'sk') { $langName = 'Slovak' }
    [void]$sb.AppendLine(('- User language: ' + $langName + ' (' + $script:UiLang + '). Talk to the user in ' + $langName + '.'))
    if ($Agent -ne '') {
        [void]$sb.AppendLine(('- Agent: {0}' -f $Agent))
    }
    [void]$sb.AppendLine('- Drives:')
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        if (-not $d.IsReady) {
            [void]$sb.AppendLine(('  - {0} ({1}, not ready)' -f $d.Name, $d.DriveType))
            continue
        }
        $label = ''
        $fs = ''
        $sz = 0
        $fr = 0
        try {
            $label = [string]$d.VolumeLabel
            $fs = [string]$d.DriveFormat
            $sz = [math]::Round($d.TotalSize / 1GB, 1)
            $fr = [math]::Round($d.AvailableFreeSpace / 1GB, 1)
        } catch { }
        [void]$sb.AppendLine(('  - {0} {1}, label "{2}", {3}: {4} GB total, {5} GB free' -f $d.Name, $d.DriveType, $label, $fs, $sz, $fr))
    }
    [void]$sb.AppendLine('- Paths:')
    [void]$sb.AppendLine(('  - USB stick root: {0}' -f $script:USB))
    [void]$sb.AppendLine(('  - Agent workspace (persistent, not secret): {0}' -f $script:WORKSPACE))
    [void]$sb.AppendLine(('  - Rescue backups folder: {0}' -f (Join-Path $script:USB 'aiusb\backups')))
    if ($Agent -eq 'agy') {
        [void]$sb.AppendLine(('  - Your USERPROFILE and HOME ({0}) are your own folder inside the session on the stick,' -f (Join-Path $script:H 'agy')))
        [void]$sb.AppendLine(('    wiped after the session. The profile folder of the PC user is {0}.' -f $env:USERPROFILE))
    }
    [void]$sb.AppendLine('')
    return $sb.ToString()
}

function Write-Context {
    param([string]$Agent)
    $rel = ''
    switch ($Agent) {
        'claude' { $rel = 'claude\CLAUDE.md' }
        'glm' { $rel = 'claude-glm\CLAUDE.md' }
        'codex' { $rel = 'codex\AGENTS.md' }
        'agy' { $rel = 'agy\.gemini\GEMINI.md' }
        default { $rel = '' }
    }
    if ($rel -eq '') { return }
    $path = Join-Path $script:H $rel
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($path, (Get-Context $Agent), (New-Object System.Text.UTF8Encoding($false)))
}

# ------------------------------------------------------------------ agent status
function Get-AgentStatus {
    param([string]$Agent)
    switch ($Agent) {
        'claude' {
            if (Test-Path -LiteralPath (Join-Path $script:H 'claude\.credentials.json')) { return (T 'COMMON_STATUS_SIGNED_IN') }
            return (T 'COMMON_STATUS_NOT_SIGNED_IN')
        }
        'glm' {
            if (Test-Path -LiteralPath (Join-Path $script:H 'secrets\zai.key')) { return (T 'COMMON_STATUS_KEY_SAVED') }
            return (T 'COMMON_STATUS_NO_KEY')
        }
        'codex' {
            if (Test-Path -LiteralPath (Join-Path $script:H 'codex\auth.json')) { return (T 'COMMON_STATUS_SIGNED_IN') }
            return (T 'COMMON_STATUS_NOT_SIGNED_IN')
        }
        'agy' {
            if (Test-AgySignedIn) { return (T 'COMMON_STATUS_SIGNED_IN') }
            return (T 'COMMON_STATUS_NOT_SIGNED_IN')
        }
    }
    return ''
}

# ------------------------------------------------------------------ argument quoting
function ConvertTo-WinArg {
    # Quote one argument for the MSVCRT / CommandLineToArgvW rules.
    param([string]$Value)
    if ($null -eq $Value) { $Value = '' }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\t "]') { return $Value }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $i = 0
    while ($i -lt $Value.Length) {
        $bs = 0
        while ($i -lt $Value.Length -and ([string]$Value[$i]) -eq '\') { $bs++; $i++ }
        if ($i -lt $Value.Length) {
            $ch = [string]$Value[$i]
            if ($ch -eq '"') {
                [void]$sb.Append('\' * (2 * $bs + 1))
                [void]$sb.Append('"')
            } else {
                [void]$sb.Append('\' * $bs)
                [void]$sb.Append($ch)
            }
            $i++
        } else {
            [void]$sb.Append('\' * (2 * $bs))
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

# ------------------------------------------------------------------ agent environment
function Set-CommonEnv {
    param([System.Diagnostics.ProcessStartInfo]$Psi)
    $vars = $Psi.EnvironmentVariables
    foreach ($n in $script:UNSET_ENV) {
        if ($vars.ContainsKey($n)) { $vars.Remove($n) }
    }
    # Drop every host variable that could steer or sign in an agent.
    $drop = @()
    foreach ($k in @($vars.Keys)) {
        if ($k -match '^(ANTHROPIC_|CLAUDE_|CLAUDECODE$|OPENAI_|CODEX_|GEMINI_|GOOGLE_|AGY_|ANTIGRAVITY_|JETSKI_)') { $drop += $k }
    }
    foreach ($k in $drop) { $vars.Remove($k) }
    $vars['AIUSB_ROOT'] = $script:USB
    $vars['AIUSB_MODE'] = 'windows'
    $vars['AIUSB_SESSION'] = $script:S
    $vars['TMPDIR'] = $script:T
    $vars['TMP'] = $script:T
    $vars['TEMP'] = $script:T
    $vars['CLAUDE_CODE_TMPDIR'] = $script:T
    $vars['DISABLE_AUTOUPDATER'] = '1'
    $vars['DISABLE_UPDATES'] = '1'
    $vars['ANTHROPIC_CONFIG_DIR'] = Join-Path $script:H 'anthropic'
    $vars['CODEX_HOME'] = Join-Path $script:H 'codex'
    $vars['CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL'] = '1'
    # one conversation folder for Claude Code on every PC; Codex databases in one folder
    $vars['CLAUDE_CODE_PROJECT_DIR_NAME'] = $script:CLAUDE_PROJECT_DIR_NAME
    $vars['CODEX_SQLITE_HOME'] = Join-Path (Join-Path $script:H 'codex') 'sqlite'
    $vars['Path'] = (Join-Path $script:S 'bin') + ';' + $script:BINWIN + ';' + $env:PATH
}

# ------------------------------------------------------------------ process running + unplug watcher
function Invoke-AgentProcess {
    param([System.Diagnostics.ProcessStartInfo]$Psi)
    Enable-CtrlGuard
    try {
        return (Wait-AgentProcess $Psi)
    } finally {
        Disable-CtrlGuard
    }
}

function Wait-AgentProcess {
    param([System.Diagnostics.ProcessStartInfo]$Psi)
    $proc = [System.Diagnostics.Process]::Start($Psi)
    if ($null -eq $proc) { throw (T 'PS_ERR_PROC_START') }
    if ($script:CtrlGuard) { try { [AiUsbCloseGuard]::SetAgentPid($proc.Id) } catch { } }
    try {
        return (Wait-AgentExit $proc)
    } finally {
        if ($script:CtrlGuard) { try { [AiUsbCloseGuard]::SetAgentPid(0) } catch { } }
    }
}

function Wait-AgentExit {
    param([System.Diagnostics.Process]$proc)
    $misses = 0
    $vaultIdFile = Join-Path $script:V 'vault.id'
    while (-not $proc.WaitForExit(1500)) {
        if (Test-Path -LiteralPath $vaultIdFile) {
            $misses = 0
        } else {
            $misses++
        }
        if ($misses -ge 2) {
            try {
                $tk = Join-Path $env:SystemRoot 'System32\taskkill.exe'
                & $tk '/PID' ([string]$proc.Id) '/T' '/F' | Out-Null
            } catch { }
            try { $proc.Kill() } catch { }
            Write-Host ''
            Write-Host (T 'PS_USB_REMOVED') -ForegroundColor Yellow
            Write-Log 'usb-removed'
            Disable-CtrlGuard
            try { Read-Host (T 'PS_PRESS_ENTER_CLOSE') | Out-Null } catch { }
            exit 2
        }
    }
    $proc.WaitForExit()
    return $proc.ExitCode
}

# ------------------------------------------------------------------ keys helpers
function Set-SecretKey {
    param([string]$FileName, [string]$Label)
    $secDir = Join-Path $script:H 'secrets'
    if (-not (Test-Path -LiteralPath $secDir)) {
        New-Item -ItemType Directory -Path $secDir -Force | Out-Null
    }
    $target = Join-Path $secDir $FileName
    $plain = Read-Secret (T 'PS_ENTER_KEY' $Label)
    if ($plain.Length -eq 0) {
        $plain = $null
        Write-Warn (T 'PS_KEY_EMPTY')
        return
    }
    [System.IO.File]::WriteAllText($target, $plain, (New-Object System.Text.UTF8Encoding($false)))
    Write-Info (T 'PS_KEY_SAVED' ([string]$plain.Length))
    $plain = $null
    try { Save-Vault } catch { Write-Err (T 'PS_ERR_SAVE_KEY') }
}

function Invoke-CodexLogin {
    # A browser is available on Windows, so plain 'codex login'.
    if (-not (Test-Path -LiteralPath $script:WORKSPACE)) {
        New-Item -ItemType Directory -Path $script:WORKSPACE -Force | Out-Null
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $script:BINWIN 'codex.exe'
    $psi.Arguments = 'login'
    $psi.UseShellExecute = $false
    $psi.WorkingDirectory = $script:WORKSPACE
    Set-CommonEnv $psi
    $psi.EnvironmentVariables['CODEX_HOME'] = Join-Path $script:H 'codex'
    Write-Info (T 'PS_CODEX_SIGNIN')
    Write-Log 'agent-start codex-login'
    $rc = Invoke-AgentProcess $psi
    Write-Log ('agent-exit codex-login rc=' + $rc)
    try { Save-Vault } catch { Write-Err (T 'PS_ERR_SAVE_CODEX') }
}

function Invoke-SignOut {
    Write-Host ''
    Write-Host (T 'PS_SIGNOUT_1')
    Write-Host (T 'PS_SIGNOUT_2')
    Write-Host (T 'PS_SIGNOUT_3')
    Write-Host (T 'PS_SIGNOUT_4')
    $c = (Read-Host (T 'PS_SIGNOUT_WHICH')).Trim()
    $files = @()
    switch ($c) {
        '1' { $files += Join-Path $script:H 'claude\.credentials.json' }
        '2' { $files += Join-Path $script:H 'secrets\zai.key' }
        '3' { $files += Join-Path $script:H 'codex\auth.json' }
        '4' {
            $agyDir = Join-Path (Join-Path $script:H 'agy') '.gemini'
            if (Test-Path -LiteralPath $agyDir) {
                foreach ($f in @(Get-ChildItem -LiteralPath $agyDir -Recurse -Force -File -Filter '*oauth-token*' -ErrorAction SilentlyContinue)) {
                    $files += $f.FullName
                }
            }
        }
        default { Write-Info (T 'PS_CANCELLED'); return }
    }
    $removed = $false
    foreach ($f in $files) {
        if (Test-Path -LiteralPath $f) {
            Remove-Item -LiteralPath $f -Force
            $removed = $true
        }
    }
    if ($removed) {
        Write-Info (T 'PS_SIGNED_OUT')
        try { Save-Vault } catch { Write-Err (T 'PS_ERR_SAVE_VAULT') }
    } else {
        Write-Info (T 'PS_NO_SIGNIN_FOUND')
    }
}

# ------------------------------------------------------------------ wrapper commands for the shell option
function Write-Wrappers {
    $bin = Join-Path $script:S 'bin'
    if (-not (Test-Path -LiteralPath $bin)) {
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    $claudeExe = Join-Path $script:BINWIN 'claude.exe'
    $codexExe = Join-Path $script:BINWIN 'codex.exe'
    $tail = @(
        'exit /b %ERRORLEVEL%',
        ':nosession',
        'echo This command only works inside the AI USB shell, menu option 5.',
        'exit /b 1'
    )
    $head = @(
        '@echo off',
        'if "%AIUSB_SESSION%"=="" goto nosession'
    )
    $nocred = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%AIUSB_ROOT%\aiusb\launcher\claude-nocredman.ps1" "%CLAUDE_CONFIG_DIR%"'


    # claude.cmd
    $lines = @()
    $lines += $head
    $lines += 'set "CLAUDE_CONFIG_DIR=%AIUSB_SESSION%\home\claude"'
    $lines += 'set "CLAUDE_CODE_USE_POWERSHELL_TOOL=1"'
    $lines += ('set "CLAUDE_CODE_PROJECT_DIR_NAME={0}"' -f $script:CLAUDE_PROJECT_DIR_NAME)
    $lines += $nocred
    $lines += ('"{0}" %*' -f $claudeExe)
    $lines += $tail
    [System.IO.File]::WriteAllText((Join-Path $bin 'claude.cmd'), ($lines -join "`r`n") + "`r`n", $enc)

    # claude-glm.cmd (reads the key at run time; no secrets inside the file)
    $lines = @()
    $lines += $head
    $lines += 'set "CLAUDE_CONFIG_DIR=%AIUSB_SESSION%\home\claude-glm"'
    $lines += 'set "CLAUDE_CODE_USE_POWERSHELL_TOOL=1"'
    $lines += ('set "CLAUDE_CODE_PROJECT_DIR_NAME={0}"' -f $script:CLAUDE_PROJECT_DIR_NAME)
    $lines += $nocred
    $lines += ('set "ANTHROPIC_BASE_URL={0}"' -f (Get-Conf 'GLM_BASE_URL' 'https://api.z.ai/api/anthropic'))
    $lines += 'set /p ANTHROPIC_AUTH_TOKEN=<"%AIUSB_SESSION%\home\secrets\zai.key" 2>nul'
    $lines += 'set "API_TIMEOUT_MS=3000000"'
    foreach ($pair in $script:GLM_MODEL_MAP) {
        $model = Get-Conf $pair[0] ''
        if ($model -ne '') {
            $lines += ('set "{0}={1}"' -f $pair[1], $model)
        }
    }
    $lines += ('"{0}" %*' -f $claudeExe)
    $lines += $tail
    [System.IO.File]::WriteAllText((Join-Path $bin 'claude-glm.cmd'), ($lines -join "`r`n") + "`r`n", $enc)

    # codex.cmd
    $lines = @()
    $lines += $head
    $lines += 'set "CODEX_HOME=%AIUSB_SESSION%\home\codex"'
    $lines += 'set "CODEX_SQLITE_HOME=%AIUSB_SESSION%\home\codex\sqlite"'
    $lines += ('"{0}" %*' -f $codexExe)
    $lines += $tail
    [System.IO.File]::WriteAllText((Join-Path $bin 'codex.cmd'), ($lines -join "`r`n") + "`r`n", $enc)

    # agy.cmd (Antigravity CLI; its home, login file and conversations stay in the session)
    $lines = @()
    $lines += $head
    $lines += 'set "USERPROFILE=%AIUSB_SESSION%\home\agy"'
    $lines += 'set "HOME=%AIUSB_SESSION%\home\agy"'
    $lines += ('set "SSH_CONNECTION={0}"' -f $script:AGY_SSH_MARK)
    $lines += 'set "AGY_CLI_DISABLE_AUTO_UPDATE=true"'
    $agyArgs = ''
    foreach ($r in @(Get-Roots)) { $agyArgs += ' ' + (ConvertTo-WinArg ('--add-dir=' + $r)) }
    $lines += ('"{0}"{1} %*' -f $script:AGYEXE, $agyArgs)
    $lines += $tail
    [System.IO.File]::WriteAllText((Join-Path $bin 'agy.cmd'), ($lines -join "`r`n") + "`r`n", $enc)
}

# ------------------------------------------------------------------ starting agents
function Start-Agent {
    # -Resume opens the agent's list of saved conversations.
    param([string]$Agent, [switch]$Resume)

    if (-not (Test-Path -LiteralPath $script:WORKSPACE)) {
        New-Item -ItemType Directory -Path $script:WORKSPACE -Force | Out-Null
    }

    $roots = Get-Roots
    $exe = ''
    $argList = @()

    if ($Agent -eq 'claude') {
        $exe = Join-Path $script:BINWIN 'claude.exe'
        foreach ($r in $roots) { $argList += @('--add-dir', $r) }
        if ($script:Autonomous) { $argList += '--dangerously-skip-permissions' }
        if ($Resume) { $argList += '--resume' }
    } elseif ($Agent -eq 'glm') {
        $zai = Join-Path $script:H 'secrets\zai.key'
        if (-not (Test-Path -LiteralPath $zai)) {
            Write-Info (T 'PS_GLM_NEEDS_KEY')
            Set-SecretKey 'zai.key' (T 'PS_KEY_ZAI')
            if (-not (Test-Path -LiteralPath $zai)) {
                Write-Warn (T 'PS_GLM_NO_KEY')
                return
            }
        }
        $exe = Join-Path $script:BINWIN 'claude.exe'
        foreach ($r in $roots) { $argList += @('--add-dir', $r) }
        if ($script:Autonomous) { $argList += '--dangerously-skip-permissions' }
        if ($Resume) { $argList += '--resume' }
    } elseif ($Agent -eq 'codex') {
        Initialize-Home
        $auth = Join-Path $script:H 'codex\auth.json'
        if (-not (Test-Path -LiteralPath $auth)) {
            Write-Info (T 'PS_CODEX_NOT_SIGNED')
            Invoke-CodexLogin
            if (-not (Test-Path -LiteralPath $auth)) {
                Write-Warn (T 'PS_CODEX_STILL_NOT')
                return
            }
        }
        $exe = Join-Path $script:BINWIN 'codex.exe'
        $argList += @('--no-daemon', '-C', $script:WORKSPACE)
        if ($script:Autonomous) {
            $argList += '--dangerously-bypass-approvals-and-sandbox'
        } else {
            $argList += @('-s', 'danger-full-access', '-a', 'on-request')
        }
        foreach ($r in $roots) { $argList += @('--add-dir', $r) }
        # --all: also the conversations started on other PCs (another workspace path)
        if ($Resume) { $argList = @('resume', '--all') + $argList }
    } elseif ($Agent -eq 'agy') {
        $exe = $script:AGYEXE
        foreach ($r in $roots) { $argList += @('--add-dir', $r) }
        if ($script:Autonomous) { $argList += '--dangerously-skip-permissions' }
        if ($Resume) { Write-Info (T 'COMMON_RESUME_AGY') }
    } elseif ($Agent -eq 'shell') {
        $exe = Join-Path $PSHOME 'powershell.exe'
        $argList += @('-NoLogo', '-NoExit', '-Command', 'function global:prompt { ''(ai-usb) '' + (Get-Location) + ''> '' }')
    } else {
        return
    }

    if ($Agent -ne 'shell') {
        if (-not (Test-Path -LiteralPath $exe)) {
            Write-Err (T 'PS_ERR_BINARY' $exe)
            return
        }
    }

    # this agent's saved conversations, opened on first use in this session
    $groups = @(Get-AgentGroups $Agent)
    foreach ($g in $groups) {
        if (Import-History $g) { Set-HistoryDirty $g $true }
    }
    if (($Agent -eq 'claude') -or ($Agent -eq 'glm') -or ($Agent -eq 'shell')) { Merge-ClaudeProjects }

    try {
        if ($Agent -ne 'shell') { Write-Context $Agent }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = ($argList | ForEach-Object { ConvertTo-WinArg $_ }) -join ' '
        $psi.UseShellExecute = $false
        $psi.WorkingDirectory = $script:WORKSPACE
        Set-CommonEnv $psi

        # Keep Claude's login in .credentials.json inside the vault, never in the
        # host's Credential Manager (see claude-nocredman.ps1).
        foreach ($d in @('claude', 'claude-glm')) {
            try { & (Join-Path $PSScriptRoot 'claude-nocredman.ps1') (Join-Path $script:H $d) } catch { }
        }
        # Claude Code on Windows needs a shell tool; Git Bash is often missing on a
        # PC being repaired, so always enable its PowerShell tool.
        if (($Agent -eq 'claude') -or ($Agent -eq 'glm') -or ($Agent -eq 'shell')) {
            $psi.EnvironmentVariables['CLAUDE_CODE_USE_POWERSHELL_TOOL'] = '1'
        }
        if (($Agent -eq 'claude') -or ($Agent -eq 'shell')) {
            $psi.EnvironmentVariables['CLAUDE_CONFIG_DIR'] = Join-Path $script:H 'claude'
        } elseif ($Agent -eq 'glm') {
            $psi.EnvironmentVariables['CLAUDE_CONFIG_DIR'] = Join-Path $script:H 'claude-glm'
            $psi.EnvironmentVariables['ANTHROPIC_BASE_URL'] = Get-Conf 'GLM_BASE_URL' 'https://api.z.ai/api/anthropic'
            $zaiFile = Join-Path $script:H 'secrets\zai.key'
            $psi.EnvironmentVariables['ANTHROPIC_AUTH_TOKEN'] = ([System.IO.File]::ReadAllText($zaiFile)).Trim()
            $psi.EnvironmentVariables['API_TIMEOUT_MS'] = '3000000'
            foreach ($pair in $script:GLM_MODEL_MAP) {
                $model = Get-Conf $pair[0] ''
                if ($model -ne '') {
                    $psi.EnvironmentVariables[$pair[1]] = $model
                }
            }
        } elseif ($Agent -eq 'agy') {
            Set-AgyEnv $psi.EnvironmentVariables
        }

        if ($script:Autonomous -and ($Agent -ne 'shell')) {
            Write-Warn (T 'PS_AUTONOMOUS_ON_WARN')
        }

        $what = $Agent
        if ($Resume) { $what = $Agent + ' resume' }
        $credWatch = (($Agent -eq 'agy') -or ($Agent -eq 'shell'))
        if ($credWatch) { Start-AgyCredWatch }
        Write-Log ('agent-start ' + $what)
        try {
            $rc = Invoke-AgentProcess $psi
        } finally {
            if ($credWatch) { Stop-AgyCredWatch }
        }
        Write-Log ('agent-exit ' + $Agent + ' rc=' + $rc)
        try { Save-Vault -Groups $groups } catch { Write-Err (T 'PS_ERR_SAVE_AGENT') }
    } catch {
        Write-Err (T 'PS_ERR_AGENT_START' $_.Exception.Message)
    }
}

# ------------------------------------------------------------------ menus
function Show-KeysMenu {
    while ($true) {
        Write-Host ''
        Write-Host ((' +-- ' + (T 'COMMON_KEYS_TITLE')) + ' ----------------------------------------') -ForegroundColor Cyan
        Write-Host (' |  ' + (T 'COMMON_KEYS_1') + '                [' + (Get-AgentStatus 'glm') + ']')
        Write-Host (' |  ' + (T 'COMMON_KEYS_2') + '            [' + (Get-AgentStatus 'codex') + ']')
        Write-Host (' |  ' + (T 'COMMON_KEYS_3'))
        Write-Host (' |  ' + (T 'COMMON_KEYS_4'))
        Write-Host (' |  ' + (T 'COMMON_KEYS_5'))
        Write-Host (' |  ' + (T 'COMMON_KEYS_B'))
        Write-Host ' +----------------------------------------------------------'
        # this launcher keeps its own wording for the note: COMMON_KEYS_NOTE in the
        # shared files differs slightly, and today's English text must stay identical
        Write-Host (' |  ' + (T 'PS_KEYS_NOTE_1'))
        Write-Host (' |  ' + (T 'PS_KEYS_NOTE_2'))
        $c = (Read-Host (T 'PS_CHOOSE')).Trim()
        switch ($c.ToLower()) {
            '1' { Set-SecretKey 'zai.key' (T 'PS_KEY_ZAI') }
            '2' { try { Invoke-CodexLogin } catch { Write-Err (T 'PS_ERR_CODEX_LOGIN') } }
            '3' { Invoke-SignOut }
            '4' {
                try { Set-VaultPassphrase } catch { Write-Err (T 'PS_ERR_PASS_CHANGE') }
            }
            '5' { Reset-Vault }
            'b' { return }
            default { }
        }
    }
}

function Show-ResumeMenu {
    Write-Host ''
    Write-Host (' ' + (T 'COMMON_RESUME_TITLE')) -ForegroundColor Cyan
    Write-Host (' ' + (T 'COMMON_RESUME_ITEMS'))
    $c = (Read-Host (T 'PS_CHOOSE')).Trim()
    switch ($c) {
        '1' { Start-Agent 'claude' -Resume }
        '2' { Start-Agent 'glm' -Resume }
        '3' { Start-Agent 'codex' -Resume }
        '4' { Start-Agent 'agy' -Resume }
        default { }
    }
}

function Show-MainMenu {
    while ($true) {
        $adm = T 'COMMON_NO'
        if ($script:Admin) { $adm = T 'COMMON_YES' }
        Show-Banner
        Write-Host (' +-- AISTiUSB -- windows -- ' + $env:COMPUTERNAME + ' -- ' + (T 'COMMON_ADMIN') + ': ' + $adm + ' -------') -ForegroundColor Cyan
        Write-Host (' |  ' + (T 'COMMON_MENU_1') + '              [' + (Get-AgentStatus 'claude') + ']')
        Write-Host (' |  ' + (T 'COMMON_MENU_2') + '       [' + (Get-AgentStatus 'glm') + ']')
        Write-Host (' |  ' + (T 'COMMON_MENU_3') + '           [' + (Get-AgentStatus 'codex') + ']')
        Write-Host (' |  ' + (T 'COMMON_MENU_4') + '          [' + (Get-AgentStatus 'agy') + ']')
        Write-Host (' |  ' + (T 'COMMON_MENU_5'))
        Write-Host (' |  ' + (T 'COMMON_MENU_R'))
        if ($script:Autonomous) {
            Write-Host (' |  ' + (T 'COMMON_MENU_A_ON')) -ForegroundColor Red
        } else {
            Write-Host (' |  ' + (T 'COMMON_MENU_A_OFF'))
        }
        Write-Host (' |  ' + (T 'COMMON_MENU_K'))
        Write-Host (' |  ' + (T 'COMMON_MENU_L'))
        Write-Host (' |  ' + (T 'COMMON_MENU_H'))
        Write-Host (' |  ' + (T 'COMMON_MENU_Q'))
        Write-Host ' +---------------------------------------------------------'
        $c = (Read-Host (T 'PS_CHOOSE')).Trim()
        switch ($c.ToLower()) {
            '1' { Start-Agent 'claude' }
            '2' { Start-Agent 'glm' }
            '3' { Start-Agent 'codex' }
            '4' { Start-Agent 'agy' }
            '5' { Start-Agent 'shell' }
            'r' { Show-ResumeMenu }
            'a' {
                $script:Autonomous = -not $script:Autonomous
                if ($script:Autonomous) { Write-Warn (T 'PS_AUTONOMOUS_NOW_ON') }
            }
            'k' { Show-KeysMenu }
            'l' { Select-Language }
            'h' {
                Write-Host (T 'COMMON_HELP_TEXT')
                Read-Host (T 'COMMON_PRESS_ENTER') | Out-Null
            }
            'q' { return }
            default { }
        }
    }
}

# ------------------------------------------------------------------ main flow
Show-Banner

# Language first, right after the banner and before anything else, so the elevated
# relaunch can pass the choice with -Lang. A valid -Lang skips the question.
if (Test-LangCode $Lang) {
    Import-Lang $Lang
    Save-CurrentLang $Lang
} else {
    Select-Language
}

Write-Host (T 'PS_MODE_LINE') -ForegroundColor Cyan
Write-Info (T 'PS_USB_LINE' $script:USB)

if (-not (Test-Path -LiteralPath $script:CONF)) {
    Stop-Fatal (T 'PS_ERR_NO_CONF')
}
if (-not (Test-Path -LiteralPath $script:AGE)) {
    Stop-Fatal (T 'PS_ERR_NO_AGE')
}
if (-not (Test-Path -LiteralPath $script:AGEKEYGEN)) {
    Stop-Fatal (T 'PS_ERR_NO_AGEKEYGEN')
}
if (-not (Test-Path -LiteralPath $script:TAREXE)) {
    Stop-Fatal (T 'PS_ERR_NO_TAR')
}

$script:Autonomous = ((Get-Conf 'AUTONOMOUS_DEFAULT' '0') -eq '1')

Invoke-Elevate
Write-Log 'start'
$guardClock = [System.Diagnostics.Stopwatch]::StartNew()
Import-ConsoleGuards
if ($script:CtrlGuard) {
    Write-Log ('console-guard ok ' + $script:CtrlGuardSource + ' ' + [string]$guardClock.ElapsedMilliseconds + 'ms')
} else {
    # no secrets in compiler messages; shortened to keep the log readable
    $msg = $script:CtrlGuardError
    if ($msg.Length -gt 160) { $msg = $msg.Substring(0, 160) }
    Write-Log ('console-guard unavailable: ' + $msg)
}
Initialize-Session

try {
    Resolve-Lock

    Restore-StaleSession
    Remove-OldSessions
    $script:OwnSession = $true

    $isNew = -not (Test-Path -LiteralPath (Join-Path $script:V 'identity.age'))
    if ($isNew) {
        try {
            New-Vault
        } catch {
            Stop-Fatal (T 'PS_ERR_VAULT_CREATE' $_.Exception.Message)
        }
    } else {
        $script:UnlockError = ''
        $unlocked = Unlock-Vault
        if (-not $unlocked) {
            Write-Err $script:UnlockError
            Read-Host (T 'PS_PRESS_ENTER_CLOSE') | Out-Null
            exit 1
        }
    }
    $script:SessionReady = $true

    Write-Lock
    Initialize-Home
    if ($isNew) {
        try { Save-Vault } catch { Write-Err (T 'PS_ERR_INITIAL_VAULT' $_.Exception.Message) }
    }
    # From here on, closing the window with X ends the session properly.
    if ($script:CtrlGuard) {
        try {
            [AiUsbCloseGuard]::Arm($script:TAREXE, $script:AGE, $script:USB, $script:S, $script:H, $script:V,
                [string[]](Get-CoreExcludes), $script:LOGFILE, $env:COMPUTERNAME)
            $members = @()
            foreach ($g in $script:HIST_GROUPS) { $members += (@($script:HIST_PATHS[$g]) -join '|') }
            [AiUsbCloseGuard]::SetHistory((Join-Path $script:V 'history'), [string[]]$script:HIST_GROUPS,
                [string[]]$members, [string[]]$script:VAULT_EXCLUDES)
            Write-Log 'close-guard armed'
        } catch {
            Write-Log 'close-guard arm-failed'
        }
    }
    Write-Wrappers

    Write-Host ''
    Write-Info (T 'PS_ALL_ON_STICK')
    if (-not $script:Admin) {
        Write-Warn (T 'PS_NO_ADMIN_WARN')
    }

    Show-MainMenu
    Write-Log 'quit'
    Write-Info (T 'PS_SAVING')
} finally {
    $closing = $false
    if ($script:CtrlGuard) {
        try { $closing = [AiUsbCloseGuard]::IsClosing() } catch { $closing = $false }
        if (-not $closing) { try { [AiUsbCloseGuard]::Disarm() } catch { } }
    }
    if ($closing) {
        # the window-close handler is saving and wiping; nothing more to do here
        $script:SessionReady = $false
        $script:OwnSession = $false
        $script:OwnLock = $false
    }
    $saveFailed = $false
    try {
        if ($script:SessionReady -and (Test-Path -LiteralPath (Join-Path $script:V 'vault.id'))) {
            Save-Vault -Groups @($script:HistDirty.Keys)
        }
    } catch { $saveFailed = $true }
    $script:Identity = ''
    if ($saveFailed) {
        # keep the session (it is on the stick): the next start saves it, on any computer
        Write-Warn (T 'PS_SAVE_KEPT')
        Write-Log 'quit-save-fail'
    } else {
        try {
            if ($script:OwnSession) { Clear-Session }
        } catch { }
        try {
            if ($script:OwnLock) { Remove-Lock }
        } catch { }
    }
}

Write-Host ''
if (-not $saveFailed) { Write-Ok (T 'PS_LOCKED') }
Read-Host (T 'PS_PRESS_ENTER_CLOSE') | Out-Null
exit 0
