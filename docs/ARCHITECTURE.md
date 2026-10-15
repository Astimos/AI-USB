# AI-USB: Architecture & Contract (authoritative)

This document is the single source of truth shared by every component. If a task
spec and this file disagree, this file wins. Do not invent paths, labels,
variable names or file formats that are not defined here.

## 1. What the product is

One USB stick (231 GB Kingston DataTraveler 3.0) with two features:

1. **Rescue boot.** Boot the stick on a PC whose Windows is broken. A Debian 13
   ("trixie") live system starts, mounts the stick's data partition, helps the
   user get online and unlock/mount the Windows disks, then opens a terminal
   menu where the user picks an AI coding agent (Claude Code, Claude Code on GLM,
   OpenAI Codex, Google Antigravity CLI). The agents are already signed in (after one
   passphrase), run as root, and can diagnose and repair the Windows install.
   Boots with **Secure Boot ON** (Debian's Microsoft-signed shim + signed GRUB +
   signed kernel), and on legacy BIOS as a best effort.
2. **Plug-in launcher.** On a working Windows or Linux PC, the user opens the
   stick and runs `Start AI Agent.cmd` (Windows) or `start-ai-agent.sh` (Linux).
   A terminal opens with the same menu and the same signed-in agents, running
   with Administrator/root rights and able to work across the entire PC
   (every drive). There is NO auto-run on plug-in (Windows blocks it); the user
   double-clicks the launcher.

### Hard security requirements (from the user)

- **Logins live only on the stick.** All agent credentials are stored on the
  stick inside an encrypted vault (age, passphrase-protected).
- **Nothing secret may remain on the host PC after the stick is unplugged.**
  - On Linux (host or rescue) the vault is decrypted into RAM (tmpfs) only.
  - On Windows the vault is decrypted into a session folder **on the stick
    itself** (`<USB>\aiusb\session\`), never onto the host disk.
  - Every agent is forced to use file-based credential storage inside the
    session folder: never Windows Credential Manager, macOS Keychain, or a
    Linux keyring/secret-service.
  - Temp files of agents go to the session folder, not the host temp dir.
  - When the stick disappears while a session is open, the launcher kills the
    agents and (Linux) wipes the RAM session.
  - Never write secrets to logs, to the screen, to command lines (`ps` visible
    arguments), or to shell history.

## 2. Disk layout of the stick (MBR)

| MBR entry | Disk position | Size | Type | Filesystem | Label | Purpose |
|---|---|---|---|---|---|---|
| 1 | after the boot partition, to the end | rest (~222 GiB) | `07` | exFAT | `AIUSB` | launchers, agent binaries, encrypted vault, workspace |
| 2 | first, starts at 1 MiB | 8 GiB | `ef` (EFI System) | FAT32 | `AIRESCUE` | shim + GRUB + live kernel/initrd/squashfs |

MBR (not GPT) with the data partition as entry 1: Windows before 10 1703 (and some locked-down
PCs) only use the first partition of a USB stick or cannot read GPT on removable media and then
offer to "format the disk"; Ventoy and Rufus use the same scheme. UEFI firmware finds the boot
partition by its type `ef`; legacy-BIOS GRUB embeds its core image in the 1 MiB gap before it
(no BIOS-boot partition is needed). Windows assigns no drive letter to the type-`ef` partition,
so on Windows only `AIUSB` appears. Sticks written before 2026-10-06 used GPT (BIOSBOOT,
AIRESCUE, AIUSB); `scripts/convert-to-mbr.sh` converts them in place without moving data.

### 2.1 Boot partition (`AIRESCUE`, FAT32) contents

```
/EFI/BOOT/BOOTX64.EFI      Debian shimx64.efi.signed (Microsoft-signed)
/EFI/BOOT/grubx64.efi      Debian signed GRUB (gcdx64.efi.signed or grubx64.efi.signed, decided at build)
/EFI/BOOT/mmx64.efi        Debian MokManager (signed)
/EFI/BOOT/grub.cfg         stub: search --label AIRESCUE; configfile /boot/grub/grub.cfg
/EFI/debian/grub.cfg       same stub (signed grubx64 uses prefix /EFI/debian)
/.disk/info                one line "AI-USB Rescue" (gcdx64 searches for this file)
/boot/grub/grub.cfg        the real menu (shared by UEFI and BIOS GRUB)
/boot/grub/i386-pc/        BIOS GRUB modules (written by grub-install --target=i386-pc)
/live/vmlinuz              Debian kernel (signed, from linux-image-amd64)
/live/initrd.img           initramfs with live-boot
/live/filesystem.squashfs  the rescue root filesystem
/live/VERSION              build id
```
**NOT** present on purpose: `fbx64.efi` (shim fallback would write NVRAM boot entries on the host).

Kernel command line (default entry):
`boot=live live-media-path=/live live-media-timeout=15 nopersistence quiet splash`
Extra entries: safe graphics adds `nomodeset aiusb.nogui=1`; RAM mode adds `toram`.

### 2.2 Windows 11 installer (optional, `scripts/add-win-installer.sh`)

Microsoft's unchanged Windows Setup, taken from an official ISO, split across both partitions
(the "two-partition" layout Rufus and Microsoft's own guidance use when `install.wim` > 4 GiB):

```
AIRESCUE /EFI/WinSetup/bootx64.efi   the ISO's efi/boot/bootx64.efi (Windows Boot Manager, Microsoft-signed)
AIRESCUE /EFI/WinSetup/INSTALLER.TXT ISO name, size, SHA-256, date; "Status: copying (incomplete)" while copying
AIRESCUE /EFI/Microsoft/Boot/        the ISO's efi/microsoft/boot/ (BCD, fonts, resources) WITHOUT
                                     cdboot*.efi, efisys*.bin and bootmgfw.efi
AIRESCUE /boot/boot.sdi              ramdisk SDI for boot.wim
AIRESCUE /sources/boot.wim           Windows PE + Setup
AIUSB    /sources/                   the ISO's whole sources/ tree (install.wim > 4 GiB: exFAT only)
```

Boot chain: shim -> Debian GRUB -> menu entry "Install Windows 11 (Microsoft setup)" ->
`chainloader /EFI/WinSetup/bootx64.efi` (firmware LoadImage checks Microsoft's signature, so
Secure Boot stays on) -> the boot manager reads the fixed path `\EFI\Microsoft\Boot\BCD` on its own
partition -> ramdisk `[boot]\sources\boot.wim` with `\boot\boot.sdi` -> Setup searches every drive
for `\sources\install.wim|esd|swm` and finds it on AIUSB. UEFI only (no legacy-BIOS entry).

Rules: the boot manager is never placed at `/EFI/BOOT/BOOTX64.EFI` (that is shim) nor at
`/EFI/Microsoft/Boot/bootmgfw.efi` (the "Start Windows instead" entry searches every disk for that
file and must find only the PC's own Windows). GRUB shows the entry only while
`/EFI/WinSetup/bootx64.efi` exists, so the script removes that file first and writes it last,
after every other file was read back from the stick and compared with the ISO. The script never
touches anything else, and deletes an AIUSB `/sources` only when it is a Windows installer or
`INSTALLER.TXT` exists. `Start AI Agent.cmd` hides `sources` (only when it holds `install.*`),
`/.hidden` hides it from Linux file managers. Tests: `tests/test-add-win-installer.sh`.

## 3. Data partition (`AIUSB`, exFAT) layout

`$USB` denotes the root of the data partition (Windows: e.g. `E:\`; Linux host:
e.g. `/run/media/<user>/AIUSB`; rescue system: `/mnt/aiusb`).

```
$USB/Start AI Agent.cmd                 Windows double-click launcher (tiny; calls launcher.ps1)
$USB/start-ai-agent.sh                  Linux launcher entry (tiny; calls launcher.sh)
$USB/README.txt                         user guide
$USB/aiusb/VERSION                      build id, one line
$USB/aiusb/aiusb.conf                   non-secret settings, KEY=VALUE (see §6)
$USB/aiusb/launcher/launcher.sh         Linux + rescue launcher (bash)
$USB/aiusb/launcher/launcher.ps1        Windows launcher (Windows PowerShell 5.1 compatible)
$USB/aiusb/launcher/claude-nocredman.ps1  keeps Claude's Windows login in .credentials.json (see 5.9)
$USB/aiusb/launcher/banner.txt          AISTiUSB ASCII logo shown by both launchers and the rescue session
$USB/aiusb/launcher/AiUsbConsole.cs     Windows console guards (Ctrl+C, window close), see 5.7
$USB/aiusb/launcher/cache/              created by launcher.ps1: AiUsbConsole.cs compiled once per version (DLL)
$USB/aiusb/context/host-windows.md      agent instructions, Windows host mode
$USB/aiusb/context/host-linux.md        agent instructions, Linux host mode
$USB/aiusb/context/rescue.md            agent instructions, rescue boot mode
$USB/aiusb/rescue/rescue-session.sh     started by the rescue system at boot
$USB/aiusb/rescue/win-mount.sh          detect / unlock (BitLocker) / mount Windows volumes
$USB/aiusb/bin/linux-x64/claude         Claude Code native binary (linux-x64, glibc)
$USB/aiusb/bin/linux-x64/codex          OpenAI Codex CLI (x86_64-unknown-linux-musl)
$USB/aiusb/bin/linux-x64/age            age v1.3.x
$USB/aiusb/bin/linux-x64/age-keygen
$USB/aiusb/bin/linux-x64/agy            Antigravity CLI (Google, single Go binary, linux_amd64)
$USB/aiusb/bin/win-x64/claude.exe       Claude Code native binary (win32-x64)
$USB/aiusb/bin/win-x64/codex.exe        OpenAI Codex CLI (x86_64-pc-windows-msvc)
$USB/aiusb/bin/win-x64/age.exe
$USB/aiusb/bin/win-x64/age-keygen.exe
$USB/aiusb/bin/win-x64/agy.exe          Antigravity CLI (windows_amd64)
$USB/aiusb/vault/identity.age           age X25519 identity, encrypted with the user's passphrase (age -p, scrypt)
$USB/aiusb/vault/recipient.txt          the matching public key (age1...), one line, not secret
$USB/aiusb/vault/vault.id               random 32-hex-char id of this vault, not secret
$USB/aiusb/vault/home.tar.age           logins and settings: the agent home without history (tar, encrypted to recipient.txt)
$USB/aiusb/vault/home.tar.age.bak       previous version (rotated on every save)
$USB/aiusb/vault/history/<group>.tgz.age  conversation history of one agent group (gzip tar, same key), see 5.5.1
$USB/aiusb/vault/history/<group>.tgz.age.bak  previous version
$USB/aiusb/vault/session.lock           exists only while a session is open (see §5.6)
$USB/aiusb/session/                     WINDOWS ONLY: live decrypted session; exists only while running or after a crash
$USB/aiusb/workspace/                   agents' working directory (persistent notes/reports; NOT secret, not encrypted)
$USB/aiusb/logs/launcher.log            non-secret event log (append)
$USB/aiusb/logs/rescue-actions.log      non-secret log of rescue steps (append)
$USB/aiusb/backups/                     rescue-mode backups (registry hives, BCD, etc.), one subfolder per timestamp
$USB/sources/                           OPTIONAL: Windows 11 Setup files incl. install.wim (see 2.2); hidden
```

exFAT has no Unix permissions and no symlinks. Never create symlinks on `$USB`.
On Linux hosts the exFAT mount may not allow executing files; the launcher
handles that (§5.8).

## 4. Rescue root filesystem (baked into `filesystem.squashfs`)

Debian 13 trixie, amd64, built with debootstrap. Hostname `aiusb-rescue`,
root autologin on tty1, locale `C.UTF-8`, timezone UTC. It contains only
stable plumbing; all changeable logic lives on the data partition so it can be
updated without rebuilding the image.

Baked files:
- `/etc/systemd/system/getty@tty1.service.d/autologin.conf`: autologin root on tty1.
- `/root/.bash_profile`: on tty1 only, and only once per boot (guard file
  `/run/aiusb-started`), `exec /usr/local/sbin/aiusb-boot`.
- `/usr/local/sbin/aiusb-boot`: waits up to 20 s for a block device with
  filesystem label `AIUSB` (`blkid -L AIUSB`, after `udevadm settle`), mounts it
  at `/mnt/aiusb` with `mount -t exfat -o rw,uid=0,gid=0,fmask=0022,dmask=0022,iocharset=utf8`,
  then `exec bash /mnt/aiusb/aiusb/rescue/rescue-session.sh`. If the label is not
  found or the script is missing, it prints a clear message and execs `bash -l`.
- `/usr/local/bin/aiusb`: `exec bash /mnt/aiusb/aiusb/rescue/rescue-session.sh "$@"` (restart the menu).
- `/etc/environment` adds nothing secret.
- Packages (Debian names, `--no-install-recommends` unless noted): see the
  rootfs task spec. Key tools: live-boot, linux-image-amd64, network-manager,
  ntfs-3g, cryptsetup, dislocker, chntpw, libhivex-bin, reglookup (if available),
  wimtools, testdisk, gddrescue, smartmontools, nvme-cli, efibootmgr, dosfstools,
  exfatprogs, gdisk, parted, os-prober, cage, foot, firefox-esr, xdg-utils,
  tmux, curl, git, python3, jq, age, bubblewrap, ripgrep.

## 5. The launcher (shared behaviour of launcher.sh and launcher.ps1)

Both launchers implement the SAME behaviour. launcher.sh serves two modes:
`linux` (a normal Linux PC) and `rescue` (the rescue live system, passed as
`--mode rescue`). launcher.ps1 serves mode `windows`.

### 5.1 Locating the stick
- `launcher.sh`: `USB` = the directory two levels above the script
  (`$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)`).
- `launcher.ps1`: `$USB` = `(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path`.
- `V` = `$USB/aiusb/vault`. Sanity check: `$USB/aiusb/aiusb.conf` must exist.

### 5.2 Elevation ("work through the entire PC")
- Windows: if the process is not elevated, relaunch itself with
  `Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`""`
  and exit. If the user cancels UAC (exception), continue NOT elevated and show
  a yellow warning that the agents cannot change system settings.
- Linux mode: if `EUID != 0`, ask `Give the agents full administrator (root) access to this PC? [Y/n]`.
  On yes: `exec sudo env AIUSB_ELEVATED=1 bash "<launcher.sh path>" --mode linux`.
  If sudo fails, continue as the normal user with a warning.
- Rescue mode: already root.

### 5.3 Session directories
| Mode | Session dir `S` | Agent home `H` | Temp `T` |
|---|---|---|---|
| windows | `$USB\aiusb\session` | `$S\home` | `$S\tmp` |
| linux (root) | `/run/aiusb-session` | `$S/home` | `$S/tmp` |
| linux (non-root) | `${XDG_RUNTIME_DIR}/aiusb-session` if XDG_RUNTIME_DIR is set and is tmpfs, else `/dev/shm/aiusb-session-$UID` | `$S/home` | `$S/tmp` |
| rescue | `/run/aiusb-session` | `$S/home` | `$S/tmp` |

Linux: create `S` with `umask 077` / mode 0700 and verify `stat -f -c %T "$(dirname "$S")"`
is `tmpfs` or `ramfs`; if not, abort with an error (never decrypt to disk).
`T` is NOT inside `H` and is never saved into the vault.

### 5.4 Agent home tree `H` (this is what the vault stores)
```
H/.aiusb-vault-id        copy of vault.id (used to recover a stale session)
H/.aiusb-loaded-<group>  session marker: that group's history archive is open (5.5.1); never archived
H/claude/                CLAUDE_CONFIG_DIR for "Claude Code" (claude.ai / Anthropic login)
H/claude-glm/            CLAUDE_CONFIG_DIR for "Claude Code on GLM"
H/anthropic/             ANTHROPIC_CONFIG_DIR (Anthropic profiles, keeps them off the host)
H/codex/                 CODEX_HOME
H/codex/config.toml      must contain the two lines (launcher ensures them every start):
                           cli_auth_credentials_store = "file"
                           mcp_oauth_credentials_store = "file"
H/agy/                   HOME (Windows: USERPROFILE) of the Antigravity CLI; it keeps its config,
                         login file and conversations in H/agy/.gemini/antigravity-cli/
H/secrets/zai.key        z.ai API key for "Claude Code on GLM" (optional; one line)
```

### 5.5 Vault operations (exact)
`age`/`age-keygen` are the stick's binaries for the current platform.

The private key (the decrypted identity) lives only in the launcher process's memory
(bash variable `IDENTITY`, PowerShell `$script:Identity`) from the unlock until quit. It is
handed to age through a pipe (`-i -`, bash `printf '%s\n' "$IDENTITY" | age ...`, PowerShell
`Invoke-AgeInput`: stdin of a `Process`) and never written to the stick or the PC, in
particular not to the Windows session folder on the stick. This lets the history archives
(5.5.1) open later in the session without asking for the passphrase again.

**Create** (when `identity.age` does not exist, first run):
1. Explain in plain words: the passphrase protects every login on the stick;
   it cannot be recovered; losing it means signing in again.
2. Create `S`, `H`, `T`. Generate the identity in memory: `age-keygen` (stdout) →
   identity; recipient = `age-keygen -y` of it (Linux) or the `# public key:` line of the
   key output (Windows) → `$V/recipient.txt.new`; `age -p -o "$V/identity.age.new"` with the
   identity on stdin (age itself asks for the new passphrase twice on the terminal; do not
   read the passphrase yourself). Move the `.new` files into place.
3. `vault.id` = 32 random hex chars. Write it to `$V/vault.id` and `H/.aiusb-vault-id`.
4. Create the empty `H` skeleton (§5.4), then **Save** (below).

**Unlock** (identity.age exists):
- Identity: `age -d "$V/identity.age"` (age prompts for the passphrase on the terminal itself,
  the key comes out on stdout into memory); up to 3 attempts, then exit without changes.
- Linux: `printf '%s\n' "$IDENTITY" | age -d -i - "$V/home.tar.age" | tar -xf - -C "$H"` with
  `set -o pipefail`.
- Windows: `age.exe -d -i - -o "$S\home.tar" "$V\home.tar.age"` (identity on stdin),
  then `tar.exe -xf "$S\home.tar" -C "$H"` (use `$env:SystemRoot\System32\tar.exe`),
  then delete `$S\home.tar`. Never pipe binary data through PowerShell.
- A failure after the passphrase was accepted is an unpacking error (own message, vault unchanged).
- The history archives are NOT opened here (5.5.1).
- If `home.tar.age` is missing but `identity.age` exists: offer to restore
  `home.tar.age.bak`, else start with an empty `H`.

**Save** (re-encrypt; needs NO passphrase because it uses the public key):
- Linux: `tar -cf - -C "$H" . | age -R "$V/recipient.txt" -o "$V/home.tar.age.new"`.
- Windows: `tar.exe -cf "$S\home.tar" -C "$H" .`, then
  `age.exe -R "$V\recipient.txt" -o "$V\home.tar.age.new" "$S\home.tar"`, then delete `$S\home.tar`.
- The archive lists the top-level names of `H` (never `.`): a `./` member makes Windows'
  tar.exe create an undeletable entry literally named `.` on exFAT. Windows' tar.exe is built
  without regex support (no `-s`); for vaults written by older versions (with a `./` member) the
  Windows unlock lists the archive and extracts by naming its top-level entries instead.
- Only options listed by Windows' `tar.exe --help` may be used in launcher.ps1 / AiUsbConsole.cs:
  `-c -t -x -f -C --exclude` and patterns (tests run tar through `tests/wintar-shim.sh`, which
  rejects anything else).
- Both platforms pass `--exclude` for caches, logs and files the agents download again at
  every start (list kept identical in `VAULT_EXCLUDES` of launcher.sh and launcher.ps1:
  `claude*/{cache,debug,shell-snapshots,statsig,todos,file-history,paste-cache,image-cache,
  backups,telemetry,logs,plugins,skills/synced,sessions,session-env,ide,downloads}`
  (plugins: the marketplace git clone, ~17 MB per config dir; skills/synced: the account's
  skills, e.g. the Office ones, ~38 MB, synced again at every start),
  `codex/{tmp,.tmp,log,cache,plugins,packages,shell_snapshots,skills/.system}`,
  `codex/sqlite/logs_*` and the old root-level codex databases `codex/{logs,state,goals,queue,
  memories,thread_history}_*`, `agy/.gemini/antigravity-cli/{log,crashes,bin,builtin,updater,
  cli.log,last_check.timestamp}`, `agy/.cache`). Symbolic links in `H` are never archived
  (Antigravity makes `cli.log` a symlink; exFAT and Windows' tar cannot hold one).
  `home.tar.age` additionally excludes every history path (5.5.1) and `.aiusb-loaded-*`, so
  it stays a few KB.
- Verify `home.tar.age.new` exists and is non-empty; then rotate:
  `home.tar.age` → `home.tar.age.bak`, `home.tar.age.new` → `home.tar.age`; then flush
  (`sync` on Linux; on Windows `[System.IO.FileStream]::Flush($true)` is not
  needed; just make sure file handles are closed).
- Save runs: after every agent exits (logins + that agent's history group), after any
  key/sign-in change (logins only), and on quit (logins + groups still dirty).

**Wipe**: Linux `rm -rf -- "$S"`; Windows `Remove-Tree` (retries, then rename aside).
Delete `H/.aiusb-vault-id` FIRST, so a half-wiped session is never saved over the vault.
Always after a final save. Guard: refuse to wipe if `S` is empty or not the expected path.
Windows: when the final save fails, the session is kept on the stick (message
`PS_SAVE_KEPT`); the next start saves it, on any OS.

**Change passphrase**: with the identity in memory, `age -p -o "$V/identity.age.new"` reading
it from stdin (asks the new passphrase twice), rotate `identity.age.new` → `identity.age`.
Recipient and vault content stay the same.

**Forget everything** (menu: reset vault): after typing `RESET`, delete
`identity.age`, `recipient.txt`, `vault.id`, `home.tar.age*`, `history/`, wipe `S`, then exit.

### 5.5.1 Conversation history (resume on any PC)
The agents' saved conversations are kept in the vault too, but in one archive per group,
`$V/history/<group>.tgz.age` (gzip tar, encrypted to `recipient.txt`), so unlocking stays fast
however many conversations there are:

| group | paths in `H` | used by |
|---|---|---|
| claude | `claude/projects`, `claude-glm/projects` | Claude Code, Claude Code on GLM |
| codex | `codex/sessions`, `codex/archived_sessions`, `codex/session_index.jsonl`, `codex/sqlite` | Codex |
| agy | `agy/.gemini/antigravity-cli/{conversations,brain,conversation_summaries.db*}` | Antigravity |

- **Open** (lazy): when an agent starts (the Shell: all groups), its group is opened once per
  session: `age -d -i -` (identity from memory) → gzip tar extracted into `H` (Windows via
  `$S\hist-<group>.tgz`, deleted afterwards), then the marker `H/.aiusb-loaded-<group>` is
  written. No archive yet → just the marker. Open failed (damaged file) → warning, no marker.
- **Save** a group only when its marker exists, or when the vault has no archive for it yet
  and `H` holds its data (first save; sessions of older launchers). An archive that was not
  opened in this session is never overwritten. All paths gone → the archive is rotated to
  `.bak` only. Groups are marked dirty when their agent starts and saved after it exits;
  quit saves the groups still dirty; stale-session recovery saves every group (`--recover`).
- **Same conversations on every PC**: the workspace path differs per PC (drive letter, mount
  point), and every agent files conversations per folder path. So:
  - Claude Code: `CLAUDE_CODE_PROJECT_DIR_NAME=aiusb-workspace` (honoured when
    `CLAUDE_CONFIG_DIR` is set) makes it use `projects/aiusb-workspace` for every folder on
    every PC; its `/resume` lists them (it only hides a conversation whose recorded folder
    exists on this PC and differs). Before Claude starts, folders of older launchers
    named after the workspace path (`*-aiusb-workspace`) are merged into it (newer file wins).
  - Codex: `CODEX_SQLITE_HOME=$H/codex/sqlite` keeps its databases in one folder; its resume
    picker filters by the current folder, so the menu's resume runs `codex resume --all`.
  - Antigravity: conversations are not filed per folder path, so its `/resume` lists every
    PC's conversations without help.
- Retention: Claude Code (`cleanupPeriodDays`) deletes conversations older than 30 days
  itself; Codex keeps everything.
- The old Gemini CLI home (`H/gemini`) and its archive `history/gemini.tgz.age` (and `.bak`)
  are deleted at start: Antigravity replaced the Gemini CLI.

### 5.6 Every start is a clean session (lock and stale-session recovery)
The stick moves between PCs and operating systems, often by just unplugging it. Every start
therefore gives a clean new session without any question; leftovers of the previous session
are handled automatically.
- Lock file `$V/session.lock`, one line, same format from both launchers:
  `host=<hostname> os=<windows|linux|rescue> pid=<launcher pid> started=<UTC yyyy-MM-ddTHH:mm:ssZ>`
  (readers also accept the older one-pair-per-line format and local times without `Z`).
- On start (before unlocking) the lock is read. It stops the start ONLY when it is live: same
  hostname, os of this launcher, and that pid is a running launcher (Linux: `/proc/<pid>/cmdline`
  contains `launcher.sh`; Windows: a powershell/pwsh process whose start time is within 120 s of
  `started`). Then: `AISTiUSB is already open in another window on this PC ...` and exit 0.
  Any other lock (another PC or OS, an unplug, a crash) only prints
  `The last session (on <host>, <os>) was not closed; cleaning it up.` and the start continues;
  the new lock replaces it after unlocking.
- Stale session: if `H/.aiusb-vault-id` exists at start (Windows: the on-stick session survived a
  crash or unplug; Linux: the RAM session survived a closed terminal) and equals `$V/vault.id`,
  **Save** it into the vault first (it may hold newer tokens; every history group per the rules
  of 5.5.1), then **Wipe**; if the id does not match, just wipe it.
- Cross-OS: the Linux launcher also handles a Windows session left on the stick
  (`$USB/aiusb/session`): same id -> save it into the vault, then delete it; save failed -> keep
  it for the next start; other id -> delete. A session folder that cannot be deleted is renamed to
  `$USB/aiusb/session-old-<UTC yyyymmdd-HHMMSS>` (Windows launcher too) and both launchers try to
  delete `session-old-*` at every start.
- After unlocking, write `$V/session.lock`; delete it after the final save (also from the
  window-close handler on Windows, see 5.7).

### 5.7 Unplug watcher
- Linux: after unlocking, start a background watcher that checks every 2 s
  whether `$V/vault.id` is still readable. After 2 consecutive failures it
  kills the running agent's process group (`kill -TERM -- -$pgid`, then `-KILL`
  after 3 s), wipes `S`, prints `USB removed - session wiped.` to the terminal and
  terminates the launcher. Agents run as foreground jobs with job control on
  (`set -m`), so each has its own process group while keeping the terminal; the
  pgid is stored in `$S/agent.pgid`.
- Windows: agents are started with `System.Diagnostics.Process`
  (`UseShellExecute=$false`, inheriting the console). While waiting, poll every
  1.5 s: if the process exited → continue; if `Test-Path "$V\vault.id"` is false
  twice in a row → `taskkill.exe /PID <pid> /T /F`, print the message, and exit
  (the session folder is on the removed stick, so nothing is left on the PC).
- Both: trap normal exits / Ctrl+C / terminal hangup (Linux: `trap … EXIT INT TERM HUP`;
  Windows: `try { … } finally { … }`) to Save (if the stick is present) and Wipe.
- Windows window close (X, log off): PowerShell's `finally` does not run, so `AiUsbConsole.cs`
  (loaded after the elevation step; compiled once per version with the .NET Framework's
  `csc.exe` into `aiusb\launcher\cache\AiUsbConsole-<sha256 prefix>-ps<major>.dll`, falling
  back to `Add-Type` in memory) handles CTRL_CLOSE/LOGOFF/SHUTDOWN: logs `window-closed begin`,
  kills the agent, then within a 4.5 s budget saves the logins and every history group that
  is dirty and open, and only when all of that worked wipes the session and removes the lock
  (`window-closed save-ok`). Otherwise nothing is wiped (`save-fail`, `history-fail`,
  `save-busy`) and the next start recovers the session from the stick.

### 5.8 Making binaries runnable (Linux)
If `$USB/aiusb/bin/linux-x64/claude` is not executable or the mount is `noexec`
(test: `[ -x file ]` and actually running `"$file" --version` succeeds), copy the
needed binaries to `$S/bin-cache/` (RAM), `chmod 755`, and use those. `$S/bin` holds
small wrapper scripts and is put first on PATH.

### 5.9 Environment for every agent process
Start from the current environment and then:
- **Unset** (avoid host credentials or settings leaking in or being used): every variable
  whose name starts with `ANTHROPIC_`, `CLAUDE_`, `OPENAI_`, `CODEX_`, `GEMINI_`, `GOOGLE_`,
  `AGY_`, `ANTIGRAVITY_` or `JETSKI_`,
  plus `CLAUDECODE` (this covers `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`,
  `CLAUDE_CODE_OAUTH_TOKEN`, `OPENAI_API_KEY`, `OPENAI_BASE_URL`, `GEMINI_API_KEY`, `GOOGLE_API_KEY`,
  `GOOGLE_APPLICATION_CREDENTIALS`, `CODEX_HOME`, `CLAUDE_CONFIG_DIR`, `GEMINI_CLI_HOME`, and also
  provider/model switches such as `CLAUDE_CODE_USE_BEDROCK` or `ANTHROPIC_MODEL`).
- **Set**:
  - `AIUSB_ROOT=$USB`, `AIUSB_MODE=windows|linux|rescue`, `AIUSB_SESSION=$S`
  - `TMPDIR=TMP=TEMP=$T`, `CLAUDE_CODE_TMPDIR=$T`
  - `DISABLE_AUTOUPDATER=1`, `DISABLE_UPDATES=1` (Claude must not install anything on the host)
  - `ANTHROPIC_CONFIG_DIR=$H/anthropic`
  - `CODEX_HOME=$H/codex`
  - `CLAUDE_CODE_PROJECT_DIR_NAME=aiusb-workspace`, `CODEX_SQLITE_HOME=$H/codex/sqlite` (5.5.1)
  - `PATH` = `$S/bin` + stick binary dir + original PATH
  - Rescue mode only: `BROWSER=firefox-esr`, `IS_SANDBOX` is NOT set.
  - Windows only, for Claude Code / Claude Code on GLM / Shell: `CLAUDE_CODE_USE_POWERSHELL_TOOL=1`
    (Claude Code on Windows refuses to start without a shell tool; Git Bash is often absent).
  - `CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL=1` (no plugin-marketplace clone in the vault).
  - Windows, before every Claude start (launcher and `claude*.cmd` wrappers): run
    `aiusb\launcher\claude-nocredman.ps1 <CLAUDE_CONFIG_DIR>`, which sets the cached GrowthBook
    flag `tengu_windows_credman` in `.claude.json` to false. When that flag is true Claude Code
    stores its login in the host's Windows Credential Manager instead of `.credentials.json`.
- Per agent (§5.10) sets `CLAUDE_CONFIG_DIR` and keys.
- Secrets read from `H/secrets/*.key` go only into the child's environment
  (Windows: `ProcessStartInfo.EnvironmentVariables`; Linux: `env VAR=… cmd` is
  forbidden because it is visible in `ps`; instead `export` inside a subshell
  right before `exec`).

### 5.10 Agents: how each is launched
"Roots" = every place the agent may work:
- Windows: every local fixed drive (`[System.IO.DriveInfo]::GetDrives()` of type Fixed; WMI
  can take seconds on a slow PC; e.g. `C:\`, `D:\`) plus `$USB`. The OS line of the context
  comes from the registry (`ProductName`, `DisplayVersion`, `CurrentBuild`; build ≥ 22000 is
  Windows 11), not WMI.
- Linux / rescue: `/`.
Working directory for all agents: `$USB/aiusb/workspace` (create if missing).

Context: before starting an agent, build the context text = contents of
`$USB/aiusb/context/<mode-file>.md` + a generated section `## This machine (generated)`
(hostname, OS, admin yes/no, list of drives/mounts, for rescue the output of
`win-mount.sh --status`, the paths `$USB`, workspace, backups dir). Write it to
the agent's global instruction file:
`H/claude/CLAUDE.md`, `H/claude-glm/CLAUDE.md`, `H/codex/AGENTS.md`, `H/agy/.gemini/GEMINI.md`.
Mode files: windows → `host-windows.md`, linux → `host-linux.md`, rescue → `rescue.md`.

Autonomous mode (menu toggle, default from `AUTONOMOUS_DEFAULT` in aiusb.conf,
shown in red when ON) changes only the approval flags below.

1. **Claude Code**: exe `claude`/`claude.exe`; `CLAUDE_CONFIG_DIR=$H/claude`.
   Args: one `--add-dir <root>` per root. Autonomous: `--dangerously-skip-permissions`,
   except when running as root on Linux/rescue, where Claude refuses that flag:
   use `--permission-mode acceptEdits` instead and say so.
   Signed in = `H/claude/.credentials.json` exists. If not signed in, Claude
   starts its own login flow on first run (that is fine).
2. **Claude Code on GLM**: same exe; `CLAUDE_CONFIG_DIR=$H/claude-glm`,
   `ANTHROPIC_BASE_URL=<GLM_BASE_URL from conf>`, `ANTHROPIC_AUTH_TOKEN=<H/secrets/zai.key>`,
   `API_TIMEOUT_MS=3000000`; plus `ANTHROPIC_DEFAULT_OPUS_MODEL`,
   `ANTHROPIC_DEFAULT_SONNET_MODEL`, `ANTHROPIC_DEFAULT_HAIKU_MODEL` from
   `GLM_OPUS_MODEL`/`GLM_SONNET_MODEL`/`GLM_HAIKU_MODEL` only when non-empty.
   If `zai.key` is missing, ask for it first (hidden input), save it, Save vault.
   Same args as Claude Code.
3. **Codex**: exe `codex`/`codex.exe`; `CODEX_HOME=$H/codex`. Ensure config.toml lines (§5.4).
   If `H/codex/auth.json` does not exist, first run `codex login` (rescue mode:
   `codex login --device-auth`), then Save vault.
   Args: `--no-daemon -C <workspace> -s danger-full-access -a on-request`, plus
   one `--add-dir <root>` per root except `/`. Autonomous: replace `-s … -a …` with
   `--dangerously-bypass-approvals-and-sandbox`.
4. **Antigravity**: exe `agy`/`agy.exe` (Google's Antigravity CLI, which replaced the
   Gemini CLI). Environment: `HOME=$H/agy` (Windows: `USERPROFILE` and `HOME`; Linux also
   `XDG_CONFIG_HOME`/`XDG_DATA_HOME`/`XDG_STATE_HOME` under `$H/agy`, `XDG_CACHE_HOME=$T/agy-cache`),
   `AGY_CLI_DISABLE_AUTO_UPDATE=true` (only `true` works) and
   `SSH_CONNECTION="127.0.0.1 0 127.0.0.1 0"`: Antigravity stores its Google login in the
   PC's keyring (Secret Service / Windows Credential Manager) unless it believes it runs over
   SSH; then it writes a `*oauth-token*` file in its home, which is inside the vault.
   Args: one `--add-dir <root>` per root. Autonomous: `--dangerously-skip-permissions`.
   Signed in = a `*oauth-token*` file exists under `H/agy/.gemini`. Windows safety net:
   while Antigravity or the Shell runs, `AiUsbCredGuard` (AiUsbConsole.cs) remembers the
   Credential Manager entries and afterwards (and in the window-close routine) deletes new
   ones whose target names Antigravity or Jetski (log `agy-credman-removed N`).
5. **Shell**: opens bash (Linux) / powershell.exe -NoLogo (Windows) with the full
   agent environment of option 1 plus wrapper commands `claude`, `claude-glm`,
   `codex`, `agy` in `$S/bin` (Linux: small bash scripts; Windows: `.cmd`
   files) so the user can run agents by hand. Type `exit` to return to the menu.

Resume (menu `R`, then 1-4): the agent starts with its own resume picker. Claude Code and
Claude Code on GLM: `--resume`; Codex: `codex resume --all <the usual args>`; Antigravity
starts normally and the launcher says to type `/resume`.

After each agent/shell exits: Save vault, return to the menu.

### 5.11 Menu (exact items and keys)
```
 ┌─ AI USB ── <mode> ── <hostname> ── admin: yes|NO ─────────────
 │ 1) Claude Code              [signed in | not signed in]
 │ 2) Claude Code on GLM       [key saved | no key]
 │ 3) Codex (OpenAI)           [signed in | not signed in]
 │ 4) Antigravity (Google)     [signed in | not signed in]
 │ 5) Shell with the agents on PATH
 │ R) Resume a conversation          (then 1-4: which assistant)
 │ A) Autonomous mode: OFF|ON
 │ K) Keys & sign-in
 │ N) Network setup (nmtui)          ← rescue mode only
 │ W) Windows disks (mount/unlock)   ← rescue mode only
 │ Q) Save, lock and quit
 └──────────────────────────────────────────────────────────────
```
Keys & sign-in submenu: `1) Set z.ai key` · `2) Sign in to Codex` ·
`3) Sign out of an agent` (deletes that agent's credential file(s) / key) ·
`4) Change passphrase` · `5) Reset vault (forget all logins)` · `B) Back`.
Key input is hidden (bash: `read -rs`; PowerShell: `Read-Host -AsSecureString`
converted to plain text only in memory) and written without a trailing newline.
Use ANSI colors only if the terminal supports them; plain ASCII fallbacks are fine.

### 5.12 Logging
Append one line per event to `$USB/aiusb/logs/launcher.log`:
`<ISO-8601 time> <mode> <hostname> <event>`; events like `start`, `unlock-ok <ms>ms`,
`unlock-fail`, `unpack-fail`, `agent-start claude [resume]`, `agent-exit claude rc=0`, `save-ok`,
`history-load <group> <ms>ms`, `history-save <group> <ms>ms`, `history-*-fail <group>`,
`console-guard ok <cache|compiled|memory> <ms>ms`, `window-closed <begin|result>`,
`usb-removed`, `quit`.
Never log keys, tokens, passphrases or environment dumps.

## 6. `aiusb.conf` (KEY=VALUE, `#` comments, no quotes, no shell expansion)
```
GLM_BASE_URL=https://api.z.ai/api/anthropic
GLM_OPUS_MODEL=
GLM_SONNET_MODEL=
GLM_HAIKU_MODEL=
AUTONOMOUS_DEFAULT=0
KEYBOARD_LAYOUT=gb
```
`KEYBOARD_LAYOUT` is the XKB layout used by the rescue system (default offered at boot).
Parse it as text (split on the first `=`); never `source` it.

## 7. Rescue session flow (rescue-session.sh)
1. `aiusb-boot` has mounted `$USB` at `/mnt/aiusb` and execs `rescue-session.sh`.
2. If not inside the graphical terminal yet, and `aiusb.nogui` is not on the
   kernel command line, and `/dev/dri/card*` exists, and `cage` + `foot` exist:
   run `cage -s -- foot --font=monospace:size=12 bash /mnt/aiusb/aiusb/rescue/rescue-session.sh --inner`
   (set `AIUSB_INNER=1`). If cage exits non-zero in under 10 s, retry once with
   `WLR_RENDERER=pixman`, then fall back to running `--inner` directly on the TTY.
3. `--inner`: banner; network check
   (`curl -s -o /dev/null --max-time 6 https://api.anthropic.com` succeeds = online).
   If offline: menu `1) Wi-Fi / network setup (nmtui)  2) Retry  3) Continue offline`.
4. Windows disks: `bash win-mount.sh --scan`, then ask
   `Mount the Windows disks read-write so the agents can repair them? [Y/n]` →
   `win-mount.sh --mount-all` (or `--mount-all --ro` on "n").
5. `exec bash /mnt/aiusb/aiusb/launcher/launcher.sh --mode rescue`.
6. If the launcher exits, print `Type 'aiusb' to reopen the menu, 'poweroff' to shut down.`
   and run an interactive `bash -l` (the TTY/foot stays usable).

## 8. win-mount.sh contract (rescue mode, runs as root)
- `--scan`: table of block devices (excluding the stick itself, i.e. the disk that
  holds the `AIUSB`/`AIRESCUE` labels, and loop/zram/sr): `DEVICE SIZE FSTYPE LABEL KIND`,
  KIND one of `bitlocker`, `ntfs`, `efi`, `other`.
- `--mount-all [--ro]`: for each `bitlocker` volume ask for the 48-digit
  recovery key (or Enter to skip); unlock with `cryptsetup open --type bitlk`
  (fallback `dislocker`). Mount every NTFS volume (including unlocked ones)
  under `/mnt/win/<name>` with `ntfs-3g` (rw unless `--ro`). If a rw mount fails
  because Windows is hibernated / Fast Startup / unclean, mount read-only and
  report it (never remove the hiberfile automatically). Mount EFI partitions
  under `/mnt/win-esp/<name>`. The NTFS volume containing
  `Windows/System32/config/SYSTEM` gets the symlink `/mnt/windows` (first one wins).
  Recovery keys are never logged or echoed.
- `--status`: human-readable summary of what is mounted where, rw/ro, which one
  is `/mnt/windows`, BitLocker state. Used for the agent context.
- `--umount-all`: unmount everything it mounted and close BitLocker mappings.

## 9. Build pipeline (developer machine: CachyOS/Arch)
- `scripts/fetch-agents.sh` (no root) → `build/payload/` = the full `$USB` tree
  (copies `payload/` from the repo + downloads Claude Code, Codex, age and Antigravity;
  `--only claude,codex,age,antigravity` limits it to some of them).
- `scripts/build-rescue-rootfs.sh` (root) → `build/rescue/` = `live/{vmlinuz,initrd.img,filesystem.squashfs}`
  and `efi/` (signed shim/grub/mm + OVMF test firmware).
- `scripts/make-esp-tree.sh` (no root) → `build/esp/` = the exact AIRESCUE file tree.
- `scripts/make-test-image.sh` (no root) → `build/test.img` for QEMU.
- `scripts/write-usb.sh` (root) → partitions the real stick and writes `build/esp/`;
  formats `AIUSB`; the payload is then copied as the normal user.
