# Task: write `scripts/add-win-installer.sh`

Puts the official Windows 11 installer (from a Microsoft ISO) onto an already written AI-USB
stick, so that the stick's boot menu can start Windows Setup on another PC. NOT destructive:
the vault, the launchers and the rescue system are never touched. Runs as root via `pkexec`
(no interactive terminal: everything comes from the arguments). Bash, `set -euo pipefail`.
Follow docs/specs/COMMON.md (attached). Style reference: scripts/write-usb.sh (attached) - reuse
its helpers (`die`, `trim`) and its device checks.

## Background (why the files go where they go)
- The stick (ARCHITECTURE section 2) has two partitions: `AIRESCUE` (FAT32, 8 GiB, MBR type `ef`,
  boots shim -> Debian GRUB) and `AIUSB` (exFAT, ~222 GiB, data). GRUB's menu is
  `/boot/grub/grub.cfg` on AIRESCUE.
- Windows boot manager (the ISO's `efi/boot/bootx64.efi`) always reads its BCD from
  `\EFI\Microsoft\Boot\BCD` on the partition it was started from; the ISO's BCD then loads
  `\sources\boot.wim` with `\boot\boot.sdi` from that same partition. So these go on AIRESCUE.
  The boot manager itself goes to `/EFI/WinSetup/bootx64.efi`, NOT `/EFI/BOOT/BOOTX64.EFI`
  (that is shim) and NOT `/EFI/Microsoft/Boot/bootmgfw.efi` (the GRUB entry "Start Windows
  instead" searches every disk for that file and must only ever find the PC's own Windows).
- `install.wim` is larger than 4 GiB (FAT32 limit). Windows Setup searches every drive for
  `\sources\install.wim` / `install.esd` / `install.swm`, so the whole ISO `sources/` folder goes
  to the root of the exFAT `AIUSB` partition (`/sources`), where file size does not matter.
- GRUB shows "Install Windows 11" only when `/EFI/WinSetup/bootx64.efi` exists. That file is
  therefore copied LAST (after everything else is copied and verified) and removed FIRST (before
  anything else is replaced or removed), so an interrupted run never leaves a menu entry that
  starts a half-copied installer.

## Usage
```
add-win-installer.sh --device /dev/sdX --serial <SERIAL> --iso <FILE.iso> [--sha256 <HEX>]
                     [--grub-cfg <FILE>] [--dry-run]
add-win-installer.sh --device /dev/sdX --serial <SERIAL> --remove [--grub-cfg <FILE>] [--dry-run]
```
- `--iso` and `--remove` are mutually exclusive; exactly one is required.
- `--sha256 HEX`: if given, the ISO's SHA-256 must match (case-insensitive) before anything is
  mounted or written. Print "Checking the ISO checksum..." first (takes ~30 s).
- `--grub-cfg FILE`: optional; the new GRUB menu. If given, it must exist and contain the text
  `/EFI/WinSetup/bootx64.efi`; it is copied to `/boot/grub/grub.cfg` on AIRESCUE (the old one is
  first saved as `/boot/grub/grub.cfg.bak`). Do this as the very last write of a normal run, and
  also in `--remove` mode.
- `--dry-run`: run every check (arguments, ISO contents, device, free space), print the plan,
  then stop without writing. Works without root ONLY for the argument and device checks: in dry
  run without root, skip mounting and say "Dry run without root: ISO contents and free space were
  not checked." With root, a dry run mounts read-only and checks everything, then unmounts.

## Device checks (abort with a clear message if any fails)
Same as write-usb.sh safety checks 2-4 (block device, whole disk, TRAN usb, RM 1, serial equals
`--serial` exactly, refuses system mounts / swap / LUKS-LVM-RAID), plus:
- The disk has exactly two partitions. Find them by filesystem label, not by number:
  `lsblk -l -n -p -o NAME,FSTYPE,LABEL "$dev"`: exactly one `vfat` with label `AIRESCUE` and
  exactly one `exfat` with label `AIUSB`. Otherwise die ("This is not an AI-USB stick").
No size limits are needed here.

## Mounting
For each of the two partitions: if it is already mounted (`findmnt -n -r -o TARGET --source`,
first line), use that mount point and do not unmount it at the end (the desktop mounted it).
Otherwise create `mktemp -d /run/aiusb-wininst.XXXXXX` and mount it there (`-t vfat` / `-t exfat`;
read-only `-o ro` in dry run) and unmount it at the end. If an existing mount is read-only and
this is not a dry run, die with a clear message. The ISO is mounted with
`mount -o loop,ro -t udf` on its own `mktemp -d` dir (the ISO's ISO9660 layer only has a readme;
the real files are UDF). An EXIT trap unmounts what the script mounted (never what it found
mounted) and removes its temp dirs with `rmdir` only (never `rm -r` on a mount point). Use
`sync` before every unmount.

Note: FAT32 and exFAT are case-insensitive but the UDF ISO is case-sensitive and uses lowercase
names (`efi/boot/bootx64.efi`, `efi/microsoft/boot/bcd`, `boot/boot.sdi`, `sources/boot.wim`).
Look up ISO paths case-insensitively with a helper `iso_path <relative path>` that walks the
path one component at a time (`find "$dir" -maxdepth 1 -iname "$component"`), prints the real
path, and returns 1 if a component is missing or matches more than one entry.

## ISO checks (after mounting the ISO, before writing anything)
Required (case-insensitive): `efi/boot/bootx64.efi`, `efi/microsoft/boot/bcd`, `boot/boot.sdi`,
`sources/boot.wim`, `sources/setup.exe`, and one of `sources/install.wim`, `sources/install.esd`,
`sources/install.swm`. Die listing whatever is missing ("This does not look like a Windows
installation ISO").
Every file that goes to AIRESCUE must be smaller than 4 GiB (FAT32), else die.

## What gets copied (normal run)
AIRESCUE (all paths below relative to its mount point; create directories as needed):
| source on the ISO | destination on AIRESCUE |
|---|---|
| `efi/microsoft/boot/` (whole tree) EXCEPT files named `cdboot*.efi`, `efisys*.bin` and `bootmgfw.efi` (any case, any depth) | `/EFI/Microsoft/Boot/` |
| `boot/boot.sdi` | `/boot/boot.sdi` |
| `sources/boot.wim` | `/sources/boot.wim` |
| `efi/boot/bootx64.efi` | `/EFI/WinSetup/bootx64.efi` (LAST, see below) |

AIUSB: the ISO's whole `sources/` tree -> `/sources/` at the root of AIUSB.

Copy with `cp -r --no-preserve=all` (FAT/exFAT keep no owners or modes). Directory names on the
destination are written in the exact case shown in the table.

## Free space
Before writing: needed space on each partition = total size of the files to copy there minus the
size of the installer files already there that will be replaced (the paths listed under "Removing
an old installer"), plus a 64 MiB margin. Use `du -sb` / `stat -c %s` and `df -B1 --output=avail`.
Print both numbers per partition. Die if either partition is short ("AIRESCUE needs X MB more
free space").

## Order of a normal run
1. Parse arguments, check the ISO file exists and is readable, optional SHA-256 check.
2. Device checks; print a summary (device, model, serial, both partitions with mount points,
   ISO name and size).
3. Mount (or reuse) the partitions and the ISO; ISO checks; free-space check.
4. Dry run: print what would be copied where, then exit 0 (trap unmounts).
5. Remove the old installer (see below) - `/EFI/WinSetup/bootx64.efi` first.
6. Copy, in this order: AIUSB `/sources/`; AIRESCUE `/EFI/Microsoft/Boot/`, `/boot/boot.sdi`,
   `/sources/boot.wim`. Print one line per step ("Copying the installer files to AIUSB
   (about 8 GB, this takes several minutes)..."). For the big AIUSB copy show progress if
   possible without extra tools (e.g. `rsync --info=progress2 --no-perms --no-owner --no-group
   --no-times -r` when `rsync` exists, else plain `cp`).
7. Verify: `sync`; then for every copied file drop it from the page cache
   (`dd if="$f" iflag=nocache count=0 status=none`) so the next read really comes from the stick;
   then compare every copied file byte for byte with its ISO source (`cmp -s`). Die naming the
   first bad file. Print "Verifying (reads everything back from the stick)...".
8. Copy `efi/boot/bootx64.efi` to `/EFI/WinSetup/bootx64.efi`, `sync`, verify it the same way.
9. Write `/EFI/WinSetup/INSTALLER.TXT` (ASCII, CRLF line endings not needed):
   ```
   Windows installer added by AI-USB add-win-installer.sh
   ISO: <basename of the ISO>
   ISO size: <bytes>
   ISO SHA-256: <hex or "not checked">
   Added: <date -u +%Y-%m-%dT%H:%M:%SZ>
   ```
10. If `--grub-cfg` was given: back up and replace `/boot/grub/grub.cfg`, `sync`, verify with `cmp`.
11. Unmount what the script mounted. Print a short final message:
    "Done. Boot another PC from this stick and choose \"Install Windows 11\" in the menu."
    If `--grub-cfg` was not given and the stick's grub.cfg does not contain
    `/EFI/WinSetup/bootx64.efi`, warn: "The boot menu on the stick has no Windows entry yet; run
    again with --grub-cfg rescue/grub/grub.cfg."

## Removing an old installer (step 5, and the whole job of `--remove`)
Delete, in this order, only if present (use `rm -f` for files, `rm -rf` only on these exact
directories, which are real directories on the stick's own mounted filesystems - check with
`[[ -d ... && ! -L ... ]]` and that the path starts with the partition's mount point):
1. AIRESCUE `/EFI/WinSetup/bootx64.efi`, then `sync`.
2. AIRESCUE `/EFI/WinSetup/` (directory), `/EFI/Microsoft/` (directory), `/boot/boot.sdi`,
   `/sources/` (directory).
3. AIUSB `/sources/` (directory).
Never touch anything else (`/EFI/BOOT`, `/EFI/debian`, `/boot/grub`, `/live`, `/.disk`, `aiusb/`,
the launchers). FAT/exFAT names are case-insensitive, so `/EFI/Microsoft` also matches
`/efi/microsoft` - use the names exactly as written and let the filesystem resolve case.
`--remove` then optionally installs `--grub-cfg` (step 10), syncs and unmounts.
In `--remove --dry-run`: list what would be deleted, delete nothing.

## Messages and exit codes
Short plain-English lines, prefixed by nothing. Errors via `die` (to stderr, exit 1). Exit 0 on
success. Must pass `shellcheck -S warning`. No `eval`. Quote every expansion.
