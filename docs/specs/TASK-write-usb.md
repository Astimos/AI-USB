# Task: write `scripts/write-usb.sh`

DESTRUCTIVE: erases a USB stick and writes the AI-USB layout (ARCHITECTURE §2). Runs as root
(via pkexec, so there is no interactive terminal; all confirmation comes from arguments).
Bash, `set -euo pipefail`.

## Usage
`write-usb.sh --device /dev/sdX --serial <SERIAL> --esp-tree <DIR> --i-understand-this-erases-the-device`

## Safety checks (abort with a clear message if any fails; this is the most important part)
1. All four arguments present; `--esp-tree` contains `EFI/BOOT/BOOTX64.EFI`, `boot/grub/grub.cfg`,
   `live/vmlinuz`, `live/initrd.img`, `live/filesystem.squashfs`.
2. `--device` is a whole disk (`lsblk -dno TYPE` = `disk`), `TRAN` = `usb`, `RM` = `1`,
   `lsblk -dno SERIAL` equals `--serial` exactly.
3. Size between 16 GB and 2 TB.
4. Neither the disk nor any of its partitions holds `/`, `/boot`, `/home`, `/efi`, `/boot/efi`
   or swap (`findmnt`, `swapon --show`), and no partition of it is a LUKS/LVM/RAID member in use.
5. Print a summary (device, model, vendor, serial, size, current partitions) before acting.

## Steps
1. Unmount every mounted partition of the device (`umount`; fail if any stays mounted).
2. `wipefs -a` on each partition, then on the disk; `sgdisk --zap-all`.
3. `sgdisk -n 1:2048:+1M -t 1:ef02 -c 1:BIOSBOOT -n 2:0:+8G -t 2:ef00 -c 2:AIRESCUE -n 3:0:0 -t 3:0700 -c 3:AIUSB "$dev"`
   then `partprobe "$dev"` and `udevadm settle`; partition device names: handle both `/dev/sdX2`
   and `/dev/nvme0n1p2` styles (use `lsblk -lnpo NAME "$dev"` order).
4. `mkfs.fat -F 32 -n AIRESCUE` partition 2. Mount it on a `mktemp -d` dir; `cp -r` the esp tree
   into it (FAT has no permissions: use `cp -r --no-preserve=all`); `sync`.
5. BIOS GRUB (best effort, warn on failure, do not abort): if `grub-install` exists,
   `grub-install --target=i386-pc --boot-directory="$mnt/boot" --modules="part_gpt fat search search_label configfile normal linux" --no-floppy "$dev"`.
   It must not replace the existing `boot/grub/grub.cfg` (verify the file is unchanged by comparing sha256 before/after; restore from the esp tree if changed).
6. Unmount; `mkfs.exfat -L AIUSB` partition 3 (exfatprogs). `sync`; `udevadm settle`.
7. Verify: `lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL "$dev"` shows AIRESCUE vat/FAT32 and AIUSB exfat;
   print it, then print the next step for the user: "Now copy the payload as your normal user."
Trap EXIT to unmount the temp mount and remove the temp dir.
Must pass `shellcheck -S warning`.
