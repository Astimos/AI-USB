# Task A: write `payload/aiusb/rescue/win-mount.sh`

Implements ARCHITECTURE.md §8. Runs as root in the Debian 13 rescue system.
Tools available: lsblk (util-linux 2.41, supports `-J` and `-o PATH,PKNAME,PARTTYPE,MOUNTPOINTS`),
jq, blkid, cryptsetup 2.7, dislocker 0.7.3, ntfs-3g, mount/umount, findmnt.

- Identify the stick's disk: the parent disk (`PKNAME`) of any partition labelled `AIUSB` or
  `AIRESCUE`. Exclude it and all its partitions, plus TYPE `loop`, `rom`, `zram` devices, from everything.
- KIND: `bitlocker` when FSTYPE is `BitLocker`; `ntfs` when FSTYPE is `ntfs`; `efi` when PARTTYPE is
  `c12a7328-f81f-11d2-ba4b-00a0c93ec93b`; else `other`.
- State file `/run/aiusb-winmount.state`: one line per thing mounted/opened:
  `mount <mountpoint> <device> <rw|ro> <note>` or `bitlk <mapper-name> <device>` or `dislocker <dir> <device>`.
- `--mount-all [--ro]`:
  - For each `bitlocker` volume not already opened: explain how to find the recovery key
    (https://aka.ms/myrecoverykey, or printed/saved copies), then run
    `cryptsetup open --type bitlk "$dev" "bitlk-$name"` and let cryptsetup prompt on the terminal
    (it accepts the 48-digit recovery key). Empty input / failure → offer one try with dislocker:
    `mkdir -p "/run/dislocker/$name"; dislocker -V "$dev" -p -- "/run/dislocker/$name"`
    (bare `-p` makes dislocker prompt for the recovery password itself), then the NTFS device is
    `/run/dislocker/$name/dislocker-file` (mount with `-o loop`). Allow skipping.
  - Mount each NTFS device at `/mnt/win/<name>` (`<name>` = kernel name like `nvme0n1p3`, or `bitlk-...`).
    rw: `ntfs-3g -o windows_names "$dev" "$mp"`; on failure retry `ntfs-3g -o ro "$dev" "$mp"` and
    record note `hibernated-or-unclean` and print why plus the manual fix
    (`ntfs-3g -o remove_hiberfile`, only after the user agrees; this discards the hibernated session).
    With `--ro` mount everything read-only.
  - Mount EFI partitions at `/mnt/win-esp/<name>` (`mount -t vfat`, rw unless `--ro`).
  - First NTFS mount containing `Windows/System32/config/SYSTEM` → `ln -sfn "$mp" /mnt/windows`.
  - Idempotent: skip anything already mounted (check with `findmnt`).
- `--status`: readable summary (what is mounted where, rw/ro, notes, which is /mnt/windows,
  BitLocker volumes still locked). Output goes into agent instructions, so make it compact.
- `--umount-all`: reverse order of the state file; `umount`, `cryptsetup close`, `fusermount -u` / `umount` for dislocker; remove the symlink; clear the state file.
- `--scan`: table per ARCHITECTURE §8.
- Append one line per action to `/mnt/aiusb/aiusb/logs/rescue-actions.log` if that dir exists (never keys).
- Usage text on bad arguments; exit 0/1.

# Task B: write `payload/aiusb/rescue/rescue-session.sh`

Implements ARCHITECTURE.md §7. Runs as root on tty1 (from `/usr/local/sbin/aiusb-boot`) or inside
foot (with `--inner`).

- Constants: `USB=/mnt/aiusb`, `R=$USB/aiusb/rescue`, `L=$USB/aiusb/launcher/launcher.sh`.
- Keyboard layout (outer stage only, on the TTY, before cage): default from `aiusb.conf` key
  `KEYBOARD_LAYOUT` (text parse; fallback `us`). Prompt
  `Keyboard layout [gb]: ` with a 15-second timeout (`read -t 15`); accept an XKB layout name like
  `us`, `gb`, `de`, `sk`, `fr`. Apply to the TTY with `ckbcomp -layout "$layout" | loadkeys -q`
  (ignore failure) and `export XKB_DEFAULT_LAYOUT="$layout"` for cage/foot. Export
  `AIUSB_KBD="$layout"` so `--inner` can display it.
- TTY font: if `/usr/share/consolefonts/Uni3-TerminusBold28x14.psf.gz` exists and the screen is wide
  (`stty size` columns >= 160), `setfont` it.
- GUI attempt per §7 step 2: check `/proc/cmdline` for `aiusb.nogui`; `ls /dev/dri/card*`;
  `command -v cage foot`. Export `XDG_RUNTIME_DIR=/run/user/0` (mkdir -p, chmod 700) if unset.
  Measure runtime with `SECONDS`. Retry with `WLR_RENDERER=pixman`, then TTY fallback.
- `--inner`: banner (ASCII) with "AI USB Rescue", keyboard layout, IP addresses (`ip -br addr`);
  network check + offline menu (§7 step 3); Windows disks step (§7 step 4); then run the
  launcher (NOT exec, so that step 6 runs after it): `bash "$L" --mode rescue`; then step 6
  (`exec bash -l`).
- Outer stage after the GUI/TTY run returns: print the step-6 message and `exec bash -l`.
- Log steps to `$USB/aiusb/logs/rescue-actions.log`.
- Usage: `rescue-session.sh` (outer) or `rescue-session.sh --inner`.
