#!/usr/bin/env bash
#
# write-usb.sh - DESTRUCTIVE: erase a USB stick and write the AI-USB disk
# layout (docs/ARCHITECTURE.md section 2). Runs as root via pkexec, so there
# is no interactive terminal: every confirmation comes from the arguments.

set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

readonly MIN_SIZE_BYTES=$((16 * 1000 * 1000 * 1000))
readonly MAX_SIZE_BYTES=$((2 * 1000 * 1000 * 1000 * 1000))

dev=""
serial=""
esp_tree=""
esp_tree_abs=""
confirmed="no"
dry_run="no"
mnt=""

usage() {
    cat >&2 <<'EOF'
Usage:
  write-usb.sh --device /dev/sdX --serial <SERIAL> --esp-tree <DIR> \
      --i-understand-this-erases-the-device [--dry-run]

DESTRUCTIVE: erases the USB stick and writes the AI-USB boot layout.
--dry-run runs every safety check and prints the summary, then stops
without changing anything (works without root).
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

cleanup() {
    if [[ -n "$mnt" ]] && mountpoint -q "$mnt" 2>/dev/null; then
        umount "$mnt" 2>/dev/null || true
    fi
    # rmdir only: never recurse into a directory that might still be a mount.
    if [[ -n "$mnt" ]] && [[ -d "$mnt" ]]; then
        rmdir "$mnt" 2>/dev/null || echo "Note: could not remove $mnt (still mounted?)." >&2
    fi
}

count_parts() {
    lsblk -l -n -p -o NAME,TYPE "$dev" | awk '$2 == "part" { n++ } END { print n + 0 }'
}

check_fs_label() {
    local want_fs="$1"
    local want_label="$2"
    lsblk -r -n -o FSTYPE,LABEL "$dev" \
        | awk -v f="$want_fs" -v l="$want_label" \
              'BEGIN { ok = 0 } $1 == f && $2 == l { ok = 1 } END { exit ok ? 0 : 1 }'
}

trap cleanup EXIT

# ------------------------------------------------------------------ arguments

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)
            [[ $# -ge 2 ]] || die "Option --device needs a value."
            dev="$2"
            shift 2
            ;;
        --serial)
            [[ $# -ge 2 ]] || die "Option --serial needs a value."
            serial="$2"
            shift 2
            ;;
        --esp-tree)
            [[ $# -ge 2 ]] || die "Option --esp-tree needs a value."
            esp_tree="$2"
            shift 2
            ;;
        --i-understand-this-erases-the-device)
            confirmed="yes"
            shift
            ;;
        --dry-run)
            dry_run="yes"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            die "Unknown argument: $1"
            ;;
    esac
done

if [[ -z "$dev" ]]; then
    usage
    die "Missing --device."
fi
if [[ -z "$serial" ]]; then
    usage
    die "Missing --serial."
fi
if [[ -z "$esp_tree" ]]; then
    usage
    die "Missing --esp-tree."
fi
if [[ "$confirmed" != "yes" ]]; then
    usage
    die "Missing --i-understand-this-erases-the-device."
fi

# --------------------------------------------------------- safety check 1: args

if ! esp_tree_abs="$(cd "$esp_tree" 2>/dev/null && pwd)"; then
    die "Cannot read the esp tree directory: $esp_tree"
fi

missing=""
for need in \
    "EFI/BOOT/BOOTX64.EFI" \
    "boot/grub/grub.cfg" \
    "live/vmlinuz" \
    "live/initrd.img" \
    "live/filesystem.squashfs"
do
    if [[ ! -f "$esp_tree_abs/$need" ]]; then
        missing="$missing $need"
    fi
done
if [[ -n "$missing" ]]; then
    die "esp tree check failed - missing:$missing"
fi

if [[ $EUID -ne 0 && "$dry_run" != "yes" ]]; then
    die "This script must run as root."
fi

# ------------------------------------------------- safety check 2: the device

if [[ ! -b "$dev" ]]; then
    die "$dev is not a block device."
fi
dev="$(readlink -f "$dev")"

if ! lsblk -d -n -o TYPE "$dev" >/dev/null 2>&1; then
    die "Cannot query $dev with lsblk."
fi

dev_type="$(trim "$(lsblk -d -n -o TYPE "$dev")")"
if [[ "$dev_type" != "disk" ]]; then
    die "$dev is not a whole disk (lsblk TYPE: '${dev_type:-none}')."
fi

dev_tran="$(trim "$(lsblk -d -n -o TRAN "$dev")")"
if [[ "$dev_tran" != "usb" ]]; then
    die "$dev is not a USB device (lsblk TRAN: '${dev_tran:-none}')."
fi

dev_rm="$(trim "$(lsblk -d -n -o RM "$dev")")"
if [[ "$dev_rm" != "1" ]]; then
    die "$dev is not marked removable (lsblk RM: '${dev_rm:-none}')."
fi

dev_serial="$(trim "$(lsblk -d -n -o SERIAL "$dev")")"
if [[ "$dev_serial" != "$serial" ]]; then
    die "Serial number mismatch: $dev reports '${dev_serial:-none}', --serial says '$serial'."
fi

# --------------------------------------------------- safety check 3: disk size

dev_size_b="$(trim "$(lsblk -d -n -b -o SIZE "$dev")")"
if ! [[ "$dev_size_b" =~ ^[0-9]+$ ]]; then
    die "Cannot read the size of $dev."
fi
if (( dev_size_b < MIN_SIZE_BYTES )) || (( dev_size_b > MAX_SIZE_BYTES )); then
    die "Refusing: $dev is $dev_size_b bytes (allowed: 16 GB to 2 TB)."
fi

# ------------------------------------------------ safety check 4: disk in use

mapfile -t nodes < <(lsblk -l -n -p -o NAME "$dev")

for node in "${nodes[@]}"; do
    while IFS= read -r mp; do
        [[ -n "$mp" ]] || continue
        case "$mp" in
            "/"|"/boot"|"/home"|"/efi"|"/boot/efi")
                die "Refusing: $node is mounted at $mp."
                ;;
        esac
    done < <(findmnt -r -n -o TARGET --source "$node")
done

while IFS= read -r swap_name; do
    [[ -n "$swap_name" ]] || continue
    swap_real="$(readlink -f "$swap_name" 2>/dev/null || printf '%s' "$swap_name")"
    for node in "${nodes[@]}"; do
        if [[ "$swap_real" == "$node" ]]; then
            die "Refusing: $node is in use as swap."
        fi
    done
done < <(swapon --show=NAME --noheadings 2>/dev/null)

while read -r hname htype; do
    [[ -n "$hname" ]] || continue
    case "$htype" in
        disk|part)
            ;;
        *)
            die "Refusing: $hname is an active $htype device (LUKS/LVM/RAID) on this disk."
            ;;
    esac
done < <(lsblk -l -n -p -o NAME,TYPE "$dev")

# ------------------------------------------------ safety check 5: the summary

dev_size_h="$(trim "$(lsblk -d -n -o SIZE "$dev")")"
dev_model="$(trim "$(lsblk -d -n -o MODEL "$dev")")"
dev_vendor="$(trim "$(lsblk -d -n -o VENDOR "$dev")")"

echo "About to ERASE this device:"
echo "  Device : $dev"
echo "  Model  : ${dev_model:-unknown}"
echo "  Vendor : ${dev_vendor:-unknown}"
echo "  Serial : $dev_serial"
echo "  Size   : ${dev_size_h:-unknown} ($dev_size_b bytes)"
echo ""
echo "Current partitions on $dev:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL "$dev"
echo ""
if [[ "$dry_run" == "yes" ]]; then
    echo "All safety checks passed. Dry run: nothing was changed."
    exit 0
fi
echo "All safety checks passed; writing the AI-USB layout."

# ------------------------------------------------------------- step 1: unmount

pass=0
while (( pass < 3 )); do
    pass=$((pass + 1))
    any_mounted="no"
    for node in "${nodes[@]}"; do
        while IFS= read -r mp; do
            [[ -n "$mp" ]] || continue
            any_mounted="yes"
            echo "Unmounting $node from $mp"
            umount "$mp" || true
        done < <(findmnt -r -n -o TARGET --source "$node")
    done
    if [[ "$any_mounted" == "no" ]]; then
        break
    fi
done

for node in "${nodes[@]}"; do
    if findmnt -r -n -o TARGET --source "$node" | grep -q .; then
        die "Could not unmount everything on $node."
    fi
done

# ---------------------------------------------------------------- step 2: wipe

echo "Wiping old signatures..."
for node in "${nodes[@]}"; do
    if [[ "$node" != "$dev" ]]; then
        wipefs -a "$node"
    fi
done
wipefs -a "$dev"
sgdisk --zap-all "$dev"

# ------------------------------------------------------------ step 3: partition

# MBR, not GPT: Windows before 10 1703 (and some locked-down PCs) only use the first
# partition of a USB stick or cannot read GPT on removable media, and then offer to
# "format" it. Entry 1 is the exFAT data partition (what Windows shows); entry 2 is
# the 8 GiB FAT32 boot partition, physically first at 1 MiB (UEFI finds it by type 0xEF;
# legacy-BIOS GRUB embeds itself in the 1 MiB gap before it).
echo "Creating the AI-USB partition layout (MBR)..."
esp_start=2048
esp_size=$(( 8 * 1024 * 1024 * 1024 / 512 ))
data_start=$(( esp_start + esp_size ))
printf 'label: dos\nlabel-id: 0x%s\nstart=%s, type=7\nstart=%s, size=%s, type=ef\n' \
    "$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')" "$data_start" "$esp_start" "$esp_size" \
    | sfdisk --wipe always "$dev"
partprobe "$dev" || true
udevadm settle || true

waited=0
until [[ "$(count_parts)" -ge 2 ]] || (( waited >= 10 )); do
    waited=$((waited + 1))
    sleep 1
    udevadm settle >/dev/null 2>&1 || true
done

# Partition names in lsblk order (handles /dev/sdX2 and /dev/nvme0n1p2 styles).
mapfile -t parts < <(lsblk -l -n -p -o NAME,TYPE "$dev" | awk '$2 == "part" { print $1 }')
if [[ "${#parts[@]}" -ne 2 ]]; then
    die "The new partitions did not appear on $dev (found ${#parts[@]})."
fi
data_part="${parts[0]}"
esp_part="${parts[1]}"
echo "Boot partition (AIRESCUE):      $esp_part"
echo "Data partition (AIUSB):         $data_part"

# ----------------------------------------------------------- step 4: boot part

echo "Formatting $esp_part as FAT32, label AIRESCUE..."
if ! mkfs.fat -F 32 -n AIRESCUE "$esp_part"; then
    die "mkfs.fat failed on $esp_part."
fi

mnt="$(mktemp -d /tmp/aiusb-writeusb.XXXXXX)"
if ! mount -t vfat "$esp_part" "$mnt"; then
    die "Could not mount $esp_part on $mnt."
fi

echo "Copying the boot files..."
if ! cp -r --no-preserve=all "$esp_tree_abs/." "$mnt/"; then
    die "Could not copy the esp tree onto $esp_part."
fi
sync

if [[ ! -f "$mnt/EFI/BOOT/BOOTX64.EFI" ]]; then
    die "The copy to the boot partition is incomplete."
fi

# ---------------------------------------------------------- step 5: BIOS GRUB

if command -v grub-install >/dev/null 2>&1; then
    echo "Installing BIOS GRUB (best effort)..."
    grub_cfg="$mnt/boot/grub/grub.cfg"
    grub_cfg_hash=""
    if [[ -f "$grub_cfg" ]]; then
        grub_cfg_hash="$(sha256sum "$grub_cfg" | awk '{ print $1 }')"
    fi
    if grub-install \
        --target=i386-pc \
        --boot-directory="$mnt/boot" \
        --modules="part_msdos part_gpt fat search search_label configfile normal linux" \
        --no-floppy \
        "$dev"
    then
        grub_cfg_hash_new=""
        if [[ -f "$grub_cfg" ]]; then
            grub_cfg_hash_new="$(sha256sum "$grub_cfg" | awk '{ print $1 }')"
        fi
        if [[ "$grub_cfg_hash_new" != "$grub_cfg_hash" ]]; then
            echo "Warning: grub-install changed boot/grub/grub.cfg; restoring it."
            cp --no-preserve=all "$esp_tree_abs/boot/grub/grub.cfg" "$grub_cfg"
        fi
    else
        echo "Warning: BIOS GRUB install failed; skipping it (UEFI boot still works)."
    fi
else
    echo "Warning: grub-install not found; skipping BIOS boot setup."
fi

# ------------------------------------------------------------ step 6: data part

sync
echo "Closing the boot partition..."
if ! umount "$mnt"; then
    die "Could not unmount $mnt."
fi

echo "Formatting $data_part as exFAT, label AIUSB..."
if ! mkfs.exfat -L AIUSB "$data_part"; then
    die "mkfs.exfat failed on $data_part."
fi
sync
udevadm settle || true

# ----------------------------------------------------------- step 7: verify

echo "Verifying the new layout..."
verified="no"
for _ in 1 2 3 4 5; do
    if check_fs_label "vfat" "AIRESCUE" && check_fs_label "exfat" "AIUSB"; then
        verified="yes"
        break
    fi
    udevadm settle >/dev/null 2>&1 || true
    sleep 1
done
if [[ "$verified" != "yes" ]]; then
    die "Verification failed: AIRESCUE (FAT32) or AIUSB (exFAT) not found on $dev."
fi

echo ""
echo "Done. The AI-USB layout is now on $dev:"
lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL "$dev"
echo ""
echo "Now copy the payload as your normal user."