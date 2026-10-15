#!/usr/bin/env bash
#
# convert-to-mbr.sh - switch an existing AI-USB stick from the old GPT layout
# (BIOSBOOT, AIRESCUE, AIUSB) to the MBR layout (entry 1 = AIUSB exFAT, entry 2 =
# AIRESCUE FAT32) IN PLACE: no data moves, the vault and all files stay.
# Why: Windows before 10 1703 (and some locked-down PCs) only use the first
# partition of a USB stick or do not read GPT on removable media; they then offer
# to "format the disk". With MBR and the data partition listed first, they open it.
#
# Runs as root (pkexec). Usage:
#   convert-to-mbr.sh --device /dev/sdX --serial <SERIAL> --i-understand [--dry-run]
# Backups (partition table, first/last MiB) go to /dev/shm/aiusb-convert-<ts>/.

set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

dev="" serial="" confirmed="no" dry_run="no"
die() { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device) dev="${2:-}"; shift 2 ;;
        --serial) serial="${2:-}"; shift 2 ;;
        --i-understand) confirmed="yes"; shift ;;
        --dry-run) dry_run="yes"; shift ;;
        *) die "Unknown argument: $1" ;;
    esac
done
[[ -n "$dev" && -n "$serial" && "$confirmed" == "yes" ]] \
    || die "Usage: convert-to-mbr.sh --device /dev/sdX --serial <SERIAL> --i-understand [--dry-run]"
[[ -b "$dev" ]] || die "$dev is not a block device."
dev="$(readlink -f "$dev")"

# --- the right stick
[[ "$(lsblk -dno TYPE "$dev" | tr -d ' ')" == "disk" ]] || die "$dev is not a whole disk."
[[ "$(lsblk -dno TRAN "$dev" | tr -d ' ')" == "usb" ]] || die "$dev is not a USB device."
[[ "$(lsblk -dno RM "$dev" | tr -d ' ')" == "1" ]] || die "$dev is not removable."
[[ "$(lsblk -dno SERIAL "$dev" | tr -d ' ')" == "$serial" ]] || die "Serial number mismatch."

# --- the expected old layout: GPT with BIOSBOOT, AIRESCUE (FAT32), AIUSB (exFAT)
# (lsblk reads udev's data, so the dry run works without root)
[[ "$(lsblk -dno PTTYPE "$dev" | tr -d ' ')" == "gpt" ]] \
    || die "$dev has no GPT partition table (already converted?)."
table="$(lsblk -lnpo NAME,PARTTYPE,PARTLABEL,FSTYPE,LABEL "$dev" | awk 'NR > 1')"
mapfile -t parts < <(lsblk -lnpo NAME,TYPE "$dev" | awk '$2 == "part" { print $1 }')
[[ "${#parts[@]}" -eq 3 ]] || die "Expected 3 partitions, found ${#parts[@]}."
expect() {  # expect <partition> <GPT type GUID> <partlabel> <fstype or -> <label or ->
    local line
    line="$(lsblk -dnpo PARTTYPE,PARTLABEL,FSTYPE,LABEL "$1" | tr -s ' ')"
    line="${line%"${line##*[![:space:]]}"}"
    local want="$2 $3${4:+ $4}${5:+ $5}"
    [[ "${line,,}" == "${want,,}" ]] || die "Unexpected layout at $1: $line"
}
expect "${parts[0]}" 21686148-6449-6e6f-744e-656564454649 BIOSBOOT "" ""
expect "${parts[1]}" c12a7328-f81f-11d2-ba4b-00a0c93ec93b AIRESCUE vfat AIRESCUE
expect "${parts[2]}" ebd0a0a2-b9e5-4433-87c0-68b6b72699c7 AIUSB exfat AIUSB

echo "Converting $dev ($(lsblk -dno VENDOR,MODEL "$dev" | xargs), serial $serial) to MBR:"
echo "$table"
if [[ "$dry_run" == "yes" ]]; then
    echo "All checks passed. Dry run: nothing was changed."
    exit 0
fi
[[ $EUID -eq 0 ]] || die "Must run as root."

# --- backups (RAM)
bk="/dev/shm/aiusb-convert-$(date -u +%Y%m%d-%H%M%S)"
mkdir -p "$bk"
sgdisk --backup="$bk/gpt-backup.bin" "$dev" >/dev/null
dd if="$dev" of="$bk/first-1MiB.bin" bs=1M count=1 status=none
size_sectors="$(blockdev --getsz "$dev")"
dd if="$dev" of="$bk/last-1MiB.bin" bs=512 skip=$(( size_sectors - 2048 )) count=2048 status=none
echo "Backups in $bk (restore the table with: sgdisk --load-backup=$bk/gpt-backup.bin $dev)"

# --- unmount, convert, new disk id
for p in "${parts[@]}"; do
    while read -r mp; do
        [[ -n "$mp" ]] && umount "$mp"
    done < <(findmnt -rno TARGET --source "$p" || true)
done
sync
sgdisk --gpttombr=3:2 "$dev"
sfdisk --disk-id "$dev" "0x$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
partprobe "$dev" || true
udevadm settle || true
sleep 1

# --- verify
[[ "$(blkid -p -o value -s PTTYPE "$dev")" == "dos" ]] || die "Partition table is not MBR after the conversion."
mapfile -t newparts < <(lsblk -lnpo NAME,TYPE "$dev" | awk '$2 == "part" { print $1 }')
[[ "${#newparts[@]}" -eq 2 ]] || die "Expected 2 partitions after the conversion."
[[ "$(blkid -p -o value -s LABEL "${newparts[0]}")" == "AIUSB" ]] || die "Entry 1 is not AIUSB."
[[ "$(blkid -p -o value -s LABEL "${newparts[1]}")" == "AIRESCUE" ]] || die "Entry 2 is not AIRESCUE."
fsck.exfat -n "${newparts[0]}"
fsck.fat -n "${newparts[1]}"
sfdisk -d "$dev"
echo "Done: $dev is MBR now (entry 1 AIUSB, entry 2 AIRESCUE). Data unchanged."
