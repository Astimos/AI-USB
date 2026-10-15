# Task: write ONE agent-instruction file (which one is stated in your prompt)

These files become the global instruction file of each AI agent (CLAUDE.md /
AGENTS.md / GEMINI.md) at session start (ARCHITECTURE §5.10). The launcher
appends a generated `## This machine (generated)` section after your text, so
do not write that section. Audience: a capable AI coding agent. Style: second
person ("You are..."), concise, scannable headings and bullets, concrete
commands. Markdown. 120-240 lines. Every command you show must be real and
correct for the stated environment; when unsure of a flag, leave it out.

## Shared rules (put these, in your own words, near the top of every file)
- You are running from the AI-USB stick. The user's logins live only on the stick; never copy
  credentials, tokens, keys or the vault anywhere, never print them, never store secrets on this PC
  (no persistent env vars, no git credential helpers, no saved passwords).
- You have full administrator/root access to the whole PC. That power needs care:
  diagnose read-only first; explain findings in plain language; propose a plan; get the user's
  explicit OK before any change; back up anything before modifying it; prefer reversible steps.
- Never format, repartition, wipe, encrypt/decrypt, change BitLocker protectors, reset firmware,
  or delete user data without the user typing an explicit confirmation for that exact action.
- Do not install software or drivers without asking. Do not disable security software.
  Do not bypass or alter account passwords or sign-in protections.
- Keep a short report of findings and actions in the workspace folder
  (`reports/<YYYY-MM-DD>-<hostname>.md`), no secrets in it.
- Work across the whole machine (all drives/mounts), not just the workspace.

## File 1: `payload/aiusb/context/rescue.md` (rescue boot mode)
Environment: Debian 13 live system booted from the stick on the user's PC because Windows is
broken; you run as root; Windows is NOT running. Paths: `/mnt/windows` (symlink to the Windows
system volume, if found), `/mnt/win/<dev>` (all NTFS volumes), `/mnt/win-esp/<dev>` (EFI system
partitions), `/mnt/aiusb` (the stick), workspace `/mnt/aiusb/aiusb/workspace`, backups
`/mnt/aiusb/aiusb/backups/<YYYYmmdd-HHMMSS>/`. Volume helper:
`bash /mnt/aiusb/aiusb/rescue/win-mount.sh --status | --mount-all [--ro] | --umount-all`.
Tools installed: smartctl, nvme, lsblk, blkid, ntfs-3g, ntfsfix, ntfsinfo, ntfsls, hivexsh,
hivexget, hivexregedit, reglookup (may be missing), wimlib-imagex, testdisk, photorec, ddrescue,
efibootmgr, os-prober, 7z, cabextract, clamscan and freshclam, python3 (`evtx_dump.py` from
python3-evtx may be available), rsync, curl, jq, git, firefox-esr.
Content to include:
- Rescue-specific rules: back up before any write (registry hives
  `Windows/System32/config/{SYSTEM,SOFTWARE,DEFAULT}` plus their `.LOG1`/`.LOG2` files, the BCD
  store `EFI/Microsoft/Boot/BCD` on the ESP, any file you edit); never remove the hibernation file
  without consent (it discards unsaved work); if the disk looks like it is failing, stop writing and
  offer to rescue the user's files / image the disk first.
- A diagnostic playbook in order: (1) hardware health (SMART/NVMe log, `dmesg` I/O errors);
  (2) partitions, BitLocker state and mounts; (3) UEFI boot chain: ESP files, `efibootmgr -v`, BCD
  inspection with `hivexsh` / `hivexregedit --export`; restoring missing boot files by copying
  `Windows/Boot/EFI/*` into the ESP's `EFI/Microsoft/Boot/` (what bcdboot copies), and being
  honest that rebuilding a BCD store is best done in Windows RE with `bcdboot C:\Windows`;
  (4) stuck/failed updates (`Windows/WinSxS/pending.xml`, `SoftwareDistribution`);
  (5) boot loops and blue screens: list `Windows/Minidump/*.dmp` with dates, read the System event
  log (`Windows/System32/winevt/Logs/System.evtx`; useful IDs 41, 1001, 6008, 7000, 7001, 7023,
  7026, 7, 51, 153, 55, 98, WHEA 17/18/19), find the current control set via `SYSTEM\Select\Current`,
  and disable a suspect third-party driver/service offline by setting its `Start` value to 4 (record
  the old value in the report so it can be undone); (6) malware: `freshclam` then
  `clamscan -r --infected` on the Windows volume, report only, quarantine only with consent;
  (7) disk full: find space hogs, safe cleanups only (Windows/Temp, SoftwareDistribution/Download),
  never delete WinSxS by hand; (8) file rescue to the stick or another external disk (check free
  space first with `df -h /mnt/aiusb`).
- Things that need Windows itself: `sfc`, `DISM`, `chkdsk /f`, `bcdboot`, System Restore. Give the
  user exact steps to reach Windows RE (hold Shift while clicking Restart, then Troubleshoot >
  Advanced options > Command Prompt / Startup Settings / System Restore) and the exact commands;
  WinRE often assigns different drive letters, so tell them to check with `diskpart` then
  `list volume` first.
- Network: if offline, tell the user to press N in the menu (nmtui) or plug in Ethernet.

## File 2: `payload/aiusb/context/host-windows.md` (Windows host mode)
Environment: the user's running Windows PC; you were started from the stick by
`Start AI Agent.cmd`; usually elevated (Administrator); the generated section says whether;
your shell tool is PowerShell (Git Bash only if the PC has Git installed); the stick is a drive
letter (see generated section). Content: rules above; useful built-ins with one-line purpose:
`Get-ComputerInfo`, `systeminfo`, `Get-WinEvent -FilterHashtable`, `Get-CimInstance Win32_ReliabilityRecords`,
`Get-PhysicalDisk`, `Get-StorageReliabilityCounter`, `chkdsk C: /scan`, `sfc /scannow`,
`DISM /Online /Cleanup-Image /ScanHealth` and `/RestoreHealth`, `Get-Service`, `Get-ScheduledTask`,
startup items (`Get-CimInstance Win32_StartupCommand`), `driverquery /v`, `pnputil /enum-drivers`,
`Get-MpComputerStatus`, `Start-MpScan`, `Get-MpThreatDetection`, `powercfg /batteryreport`,
`powercfg /sleepstudy`, `ipconfig /all`, `Test-NetConnection`, `Get-NetAdapter`, Windows Update
history (`Get-HotFix`), `winget` (installs software: ask first). Safety habits: create a restore
point before system changes (`Checkpoint-Computer -Description 'AI-USB' -RestorePointType MODIFY_SETTINGS`;
it may be disabled or rate-limited; tell the user), export registry keys before editing
(`reg export <key> <file>` into the stick's backups folder), avoid reboots without asking.
Do not leave files on the PC except what the user asked for; put reports/backups on the stick.

## File 3: `payload/aiusb/context/host-linux.md` (Linux host mode)
Environment: the user's running Linux PC, started from the stick by `start-ai-agent.sh`; usually
root via sudo (generated section says). Content: rules above; tools: `journalctl -b -p warning`,
`journalctl --list-boots`, `systemctl --failed`, `dmesg -T`, `smartctl -a`, `lsblk -f`, `df -h`,
`du -xh --max-depth=1`, `free -h`, `ip a`, `nmcli`, `resolvectl status`, package managers
(apt/dnf/pacman/zypper: detect which; ask before upgrades), snapshot first when available
(timeshift, snapper, btrfs subvolume snapshot) before risky changes, back up config files you
edit into the stick's backups folder. Do not leave files on the PC except what the user asked for.

Write ONLY the file named in your prompt.
