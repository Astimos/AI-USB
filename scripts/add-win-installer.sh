#!/usr/bin/env bash
#
# add-win-installer.sh - put the official Windows 11 installer (from a Microsoft
# ISO) onto an already written AI-USB stick, so the stick's boot menu can start
# Windows Setup on another PC. Not destructive: the vault, the launchers and the
# rescue system are never touched. Runs as root via pkexec, so every choice
# comes from the arguments. Layout and reasons: docs/specs/TASK-win-installer.md
# and docs/ARCHITECTURE.md section 2.2.

set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

readonly FAT32_MAX_BYTES=$((4 * 1024 * 1024 * 1024 - 1))
readonly MARGIN_BYTES=$((64 * 1024 * 1024))
# GRUB shows "Install Windows 11" only while this file exists: removed first, written last.
readonly BOOTMGR_REL="EFI/WinSetup/bootx64.efi"
readonly MARKER_REL="EFI/WinSetup/INSTALLER.TXT"
# Installer paths on each partition, in removal order (after BOOTMGR_REL).
readonly ESP_OLD=("EFI/WinSetup" "EFI/Microsoft" "boot/boot.sdi" "sources")
readonly DATA_OLD=("sources")

dev=""
serial=""
iso=""
iso_abs=""
want_sha=""
grub_cfg=""
grub_cfg_abs=""
mode=""
dry_run="no"
esp_part=""
data_part=""
esp_mnt=""
data_mnt=""
iso_mnt=""
iso_sha="not checked"
made_mounts=()
made_dirs=()
# Copy plan: parallel arrays of source file (on the ISO) and destination file (on the stick).
plan_src=()
plan_dst=()

usage() {
    cat >&2 <<'EOF'
Usage:
  add-win-installer.sh --device /dev/sdX --serial <SERIAL> --iso <FILE.iso>
                       [--sha256 <HEX>] [--grub-cfg <FILE>] [--dry-run]
  add-win-installer.sh --device /dev/sdX --serial <SERIAL> --remove
                       [--grub-cfg <FILE>] [--dry-run]

Adds (or replaces, or with --remove deletes) the Windows 11 installer on an
AI-USB stick. The vault and the rest of the stick are not touched.
--grub-cfg installs a new boot menu (rescue/grub/grub.cfg) on the stick.
--dry-run runs every check and prints the plan without writing anything.
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
    local i mp
    sync 2>/dev/null || true
    for (( i = ${#made_mounts[@]} - 1; i >= 0; i-- )); do
        mp="${made_mounts[$i]}"
        if mountpoint -q "$mp" 2>/dev/null; then
            umount "$mp" 2>/dev/null || echo "Note: could not unmount $mp." >&2
        fi
    done
    # rmdir only: never recurse into a directory that might still be a mount.
    for (( i = ${#made_dirs[@]} - 1; i >= 0; i-- )); do
        rmdir "${made_dirs[$i]}" 2>/dev/null || echo "Note: could not remove ${made_dirs[$i]}." >&2
    done
}

trap cleanup EXIT

mb() {
    echo $(( ($1 + 1024 * 1024 - 1) / (1024 * 1024) ))
}

first_mount_of() {
    findmnt -n -l -o TARGET --source "$1" 2>/dev/null | awk 'NR == 1' || true
}

# mount_or_reuse <device> <fstype> <var>: sets <var> to the device's mount point.
mount_or_reuse() {
    local node="$1" fstype="$2" var="$3" mp opts
    mp="$(first_mount_of "$node")"
    if [[ -n "$mp" ]]; then
        opts="$(findmnt -n -l -o OPTIONS --target "$mp" 2>/dev/null | awk 'NR == 1' || true)"
        if [[ ",$opts," == *,ro,* && "$dry_run" != "yes" ]]; then
            die "$node is mounted read-only at $mp. Unmount it (or eject it in the file manager) and run again."
        fi
        echo "Using $node, already mounted at $mp."
    else
        mp="$(mktemp -d /run/aiusb-wininst.XXXXXX)"
        made_dirs+=("$mp")
        if [[ "$dry_run" == "yes" ]]; then
            mount -t "$fstype" -o ro "$node" "$mp" || die "Could not mount $node."
        else
            mount -t "$fstype" "$node" "$mp" || die "Could not mount $node."
        fi
        made_mounts+=("$mp")
    fi
    printf -v "$var" '%s' "$mp"
}

# iso_path <relative path>: print the real path of a file on the (case-sensitive) ISO,
# matching each component case-insensitively. Returns 1 if missing or ambiguous.
iso_path() {
    local cur="$iso_mnt" comp
    local -a comps matches
    IFS='/' read -r -a comps <<< "$1"
    for comp in "${comps[@]}"; do
        [[ -n "$comp" ]] || continue
        [[ -d "$cur" ]] || return 1
        mapfile -t matches < <(find "$cur" -mindepth 1 -maxdepth 1 -iname "$comp")
        [[ "${#matches[@]}" -eq 1 ]] || return 1
        cur="${matches[0]}"
    done
    printf '%s\n' "$cur"
}

# Size of a file rounded up to whole clusters of the destination filesystem.
on_disk() {
    local size="$1" bs="$2"
    echo $(( (size + bs - 1) / bs * bs ))
}

# Bytes the existing installer files under <mount point> occupy (paths from the list).
old_bytes() {
    local base="$1" rel total=0 n
    shift
    for rel in "$@"; do
        if [[ -e "$base/$rel" ]]; then
            n="$(du -s -B1 -- "$base/$rel" | awk '{ print $1 }')"
            total=$(( total + n ))
        fi
    done
    echo "$total"
}

# remove_rel <mount point> <relative path>: delete one known installer path.
remove_rel() {
    local base="$1" rel="$2" p
    [[ "$base" == /?* ]] || die "Internal error: bad mount point '$base'."
    mountpoint -q "$base" || die "Internal error: $base is not a mount point."
    [[ -n "$rel" && "$rel" != /* && "$rel" != *..* ]] || die "Internal error: bad path '$rel'."
    p="$base/$rel"
    if [[ -L "$p" ]]; then
        die "Refusing: $p is a symbolic link."
    elif [[ -d "$p" ]]; then
        echo "Removing $p"
        rm -rf -- "$p"
    elif [[ -e "$p" ]]; then
        echo "Removing $p"
        rm -f -- "$p"
    fi
}

# plan_add <source file> <destination file>
plan_add() {
    plan_src+=("$1")
    plan_dst+=("$2")
}

# Read a file back from the stick (not from the page cache) and compare it with its source.
verify_file() {
    local src="$1" dst="$2"
    [[ -f "$dst" ]] || die "Verify failed: $dst is missing."
    dd if="$dst" iflag=nocache count=0 status=none 2>/dev/null || true
    cmp -s -- "$src" "$dst" || die "Verify failed: $dst differs from the ISO. The stick may be faulty; run again."
}

install_grub_cfg() {
    local dst="$esp_mnt/boot/grub/grub.cfg"
    [[ -d "$esp_mnt/boot/grub" ]] || die "$esp_mnt/boot/grub is missing: this stick has no AI-USB boot menu."
    echo "Installing the new boot menu ($grub_cfg_abs)..."
    if [[ -f "$dst" ]]; then
        cp --no-preserve=all -- "$dst" "$dst.bak"
    fi
    cp --no-preserve=all -- "$grub_cfg_abs" "$dst"
    sync
    verify_file "$grub_cfg_abs" "$dst"
}

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
        --iso)
            [[ $# -ge 2 ]] || die "Option --iso needs a value."
            [[ -z "$mode" ]] || die "Use either --iso or --remove, not both."
            iso="$2"
            mode="add"
            shift 2
            ;;
        --remove)
            [[ -z "$mode" ]] || die "Use either --iso or --remove, not both."
            mode="remove"
            shift
            ;;
        --sha256)
            [[ $# -ge 2 ]] || die "Option --sha256 needs a value."
            want_sha="$2"
            shift 2
            ;;
        --grub-cfg)
            [[ $# -ge 2 ]] || die "Option --grub-cfg needs a value."
            grub_cfg="$2"
            shift 2
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

[[ -n "$dev" ]] || { usage; die "Missing --device."; }
[[ -n "$serial" ]] || { usage; die "Missing --serial."; }
[[ -n "$mode" ]] || { usage; die "Missing --iso or --remove."; }

if [[ -n "$want_sha" ]]; then
    [[ "$mode" == "add" ]] || die "--sha256 only goes with --iso."
    [[ "$want_sha" =~ ^[0-9a-fA-F]{64}$ ]] || die "--sha256 must be 64 hex digits."
    want_sha="${want_sha,,}"
fi

if [[ -n "$grub_cfg" ]]; then
    [[ -f "$grub_cfg" && -r "$grub_cfg" ]] || die "Cannot read the boot menu file: $grub_cfg"
    grub_cfg_abs="$(readlink -f -- "$grub_cfg")"
    grep -q -F "/$BOOTMGR_REL" -- "$grub_cfg_abs" \
        || die "$grub_cfg has no Windows installer entry (no /$BOOTMGR_REL in it)."
fi

if [[ "$mode" == "add" ]]; then
    [[ -f "$iso" && -r "$iso" ]] || die "Cannot read the ISO file: $iso"
    iso_abs="$(readlink -f -- "$iso")"
fi

if [[ $EUID -ne 0 && "$dry_run" != "yes" ]]; then
    die "This script must run as root (pkexec)."
fi

if [[ -n "$want_sha" ]]; then
    echo "Checking the ISO checksum (takes about half a minute)..."
    iso_sha="$(sha256sum -- "$iso_abs" | awk '{ print $1 }')"
    [[ "$iso_sha" == "$want_sha" ]] \
        || die "The ISO checksum does not match: got $iso_sha. Download the ISO again."
    echo "ISO checksum OK."
fi

# ------------------------------------------------------------- device checks

[[ -b "$dev" ]] || die "$dev is not a block device."
dev="$(readlink -f -- "$dev")"

lsblk -d -n -o TYPE "$dev" >/dev/null 2>&1 || die "Cannot query $dev with lsblk."

dev_type="$(trim "$(lsblk -d -n -o TYPE "$dev")")"
[[ "$dev_type" == "disk" ]] || die "$dev is not a whole disk (lsblk TYPE: '${dev_type:-none}')."

dev_tran="$(trim "$(lsblk -d -n -o TRAN "$dev")")"
[[ "$dev_tran" == "usb" ]] || die "$dev is not a USB device (lsblk TRAN: '${dev_tran:-none}')."

dev_rm="$(trim "$(lsblk -d -n -o RM "$dev")")"
[[ "$dev_rm" == "1" ]] || die "$dev is not marked removable (lsblk RM: '${dev_rm:-none}')."

dev_serial="$(trim "$(lsblk -d -n -o SERIAL "$dev")")"
[[ "$dev_serial" == "$serial" ]] \
    || die "Serial number mismatch: $dev reports '${dev_serial:-none}', --serial says '$serial'."

mapfile -t nodes < <(lsblk -l -n -p -o NAME "$dev")

for node in "${nodes[@]}"; do
    while IFS= read -r mp; do
        [[ -n "$mp" ]] || continue
        case "$mp" in
            "/"|"/boot"|"/home"|"/efi"|"/boot/efi")
                die "Refusing: $node is mounted at $mp."
                ;;
        esac
    done < <(findmnt -n -l -o TARGET --source "$node" 2>/dev/null || true)
done

while IFS= read -r swap_name; do
    [[ -n "$swap_name" ]] || continue
    swap_real="$(readlink -f -- "$swap_name" 2>/dev/null || printf '%s' "$swap_name")"
    for node in "${nodes[@]}"; do
        [[ "$swap_real" != "$node" ]] || die "Refusing: $node is in use as swap."
    done
done < <(swapon --show=NAME --noheadings 2>/dev/null || true)

mapfile -t parts < <(lsblk -l -n -p -o NAME,TYPE "$dev" | awk '$2 == "part" { print $1 }')
while read -r hname htype; do
    [[ -n "$hname" ]] || continue
    case "$htype" in
        disk|part) ;;
        *) die "Refusing: $hname is an active $htype device (LUKS/LVM/RAID) on this disk." ;;
    esac
done < <(lsblk -l -n -p -o NAME,TYPE "$dev")

# The two AI-USB partitions, found by filesystem and label (never by number).
[[ "${#parts[@]}" -eq 2 ]] || die "This is not an AI-USB stick: $dev has ${#parts[@]} partitions, expected 2."
for p in "${parts[@]}"; do
    p_fs="$(trim "$(lsblk -d -n -o FSTYPE "$p")")"
    p_label="$(trim "$(lsblk -d -n -o LABEL "$p")")"
    if [[ "$p_fs" == "vfat" && "$p_label" == "AIRESCUE" ]]; then
        esp_part="$p"
    elif [[ "$p_fs" == "exfat" && "$p_label" == "AIUSB" ]]; then
        data_part="$p"
    fi
done
[[ -n "$esp_part" && -n "$data_part" ]] \
    || die "This is not an AI-USB stick: expected a vfat AIRESCUE and an exfat AIUSB partition."

echo "AI-USB stick:"
echo "  Device : $dev"
echo "  Model  : $(trim "$(lsblk -d -n -o VENDOR "$dev")") $(trim "$(lsblk -d -n -o MODEL "$dev")")"
echo "  Serial : $dev_serial"
echo "  Boot   : $esp_part (AIRESCUE)"
echo "  Data   : $data_part (AIUSB)"
if [[ "$mode" == "add" ]]; then
    echo "  ISO    : $iso_abs ($(mb "$(stat -c %s -- "$iso_abs")") MB)"
else
    echo "  Action : remove the Windows installer"
fi
echo ""

if [[ $EUID -ne 0 ]]; then
    echo "Dry run without root: ISO contents and free space were not checked."
    echo "All other checks passed. Nothing was changed."
    exit 0
fi

# ------------------------------------------------------------------ mounting

mount_or_reuse "$esp_part" vfat esp_mnt
mount_or_reuse "$data_part" exfat data_mnt

[[ -f "$esp_mnt/EFI/BOOT/BOOTX64.EFI" && -d "$esp_mnt/boot/grub" ]] \
    || die "$esp_part has no AI-USB boot files (EFI/BOOT/BOOTX64.EFI, boot/grub)."

# Only ever delete an AIUSB /sources folder that is a Windows installer (or that a run of this
# script started copying): it sits on the user's data partition.
if [[ -d "$data_mnt/sources" && ! -f "$esp_mnt/$MARKER_REL" ]]; then
    if [[ ! -f "$data_mnt/sources/setup.exe" || ! -f "$data_mnt/sources/boot.wim" ]]; then
        die "AIUSB already has a folder named 'sources' that is not a Windows installer. Move it away and run again."
    fi
fi

# ------------------------------------------------------------------ remove mode

if [[ "$mode" == "remove" ]]; then
    if [[ "$dry_run" == "yes" ]]; then
        echo "Dry run. Would delete (where present):"
        for rel in "$BOOTMGR_REL" "${ESP_OLD[@]}"; do
            if [[ -e "$esp_mnt/$rel" ]]; then
                echo "  $esp_mnt/$rel"
            fi
        done
        for rel in "${DATA_OLD[@]}"; do
            if [[ -e "$data_mnt/$rel" ]]; then
                echo "  $data_mnt/$rel"
            fi
        done
        if [[ -n "$grub_cfg_abs" ]]; then
            echo "Would install the boot menu $grub_cfg_abs."
        fi
        echo "Nothing was changed."
        exit 0
    fi
    remove_rel "$esp_mnt" "$BOOTMGR_REL"
    sync
    for rel in "${ESP_OLD[@]}"; do
        remove_rel "$esp_mnt" "$rel"
    done
    for rel in "${DATA_OLD[@]}"; do
        remove_rel "$data_mnt" "$rel"
    done
    sync
    [[ -z "$grub_cfg_abs" ]] || install_grub_cfg
    echo "Done. The Windows installer was removed from the stick."
    exit 0
fi

# ---------------------------------------------------------------- the ISO

iso_mnt="$(mktemp -d /run/aiusb-wininst-iso.XXXXXX)"
made_dirs+=("$iso_mnt")
mount -o loop,ro -t udf -- "$iso_abs" "$iso_mnt" \
    || die "Could not mount the ISO (needs the udf kernel module)."
made_mounts+=("$iso_mnt")

missing=""
for need in efi/boot/bootx64.efi efi/microsoft/boot/bcd boot/boot.sdi sources/boot.wim sources/setup.exe; do
    if ! iso_path "$need" >/dev/null; then
        missing="$missing $need"
    fi
done
have_image="no"
for img in sources/install.wim sources/install.esd sources/install.swm; do
    if iso_path "$img" >/dev/null; then
        have_image="yes"
    fi
done
[[ "$have_image" == "yes" ]] || missing="$missing sources/install.wim|esd|swm"
[[ -z "$missing" ]] || die "This does not look like a Windows installation ISO. Missing:$missing"

iso_bootmgr="$(iso_path efi/boot/bootx64.efi)"
iso_msboot="$(iso_path efi/microsoft/boot)"
iso_sdi="$(iso_path boot/boot.sdi)"
iso_bootwim="$(iso_path sources/boot.wim)"
iso_sources="$(iso_path sources)"

# ------------------------------------------------------------------ the plan

esp_bs="$(stat -f -c %S -- "$esp_mnt")"
data_bs="$(stat -f -c %S -- "$data_mnt")"
esp_need=0
data_need=0

# AIUSB first (copied first): the whole sources tree.
while IFS= read -r -d '' rel; do
    plan_add "$iso_sources/$rel" "$data_mnt/sources/$rel"
    data_need=$(( data_need + $(on_disk "$(stat -c %s -- "$iso_sources/$rel")" "$data_bs") ))
done < <(find "$iso_sources" -type f -printf '%P\0' | sort -z)
data_plan_end=${#plan_src[@]}

# AIRESCUE: boot manager data (without the CD-only and bootmgfw.efi files), boot.sdi, boot.wim.
while IFS= read -r -d '' rel; do
    plan_add "$iso_msboot/$rel" "$esp_mnt/EFI/Microsoft/Boot/$rel"
done < <(find "$iso_msboot" -type f ! -iname 'cdboot*.efi' ! -iname 'efisys*.bin' \
             ! -iname 'bootmgfw.efi' -printf '%P\0' | sort -z)
plan_add "$iso_sdi" "$esp_mnt/boot/boot.sdi"
plan_add "$iso_bootwim" "$esp_mnt/sources/boot.wim"

for (( i = data_plan_end; i < ${#plan_src[@]}; i++ )); do
    size="$(stat -c %s -- "${plan_src[$i]}")"
    (( size <= FAT32_MAX_BYTES )) || die "${plan_src[$i]} is larger than 4 GiB and cannot go on FAT32."
    esp_need=$(( esp_need + $(on_disk "$size" "$esp_bs") ))
done
esp_need=$(( esp_need + $(on_disk "$(stat -c %s -- "$iso_bootmgr")" "$esp_bs") + 2 * esp_bs ))

esp_old="$(old_bytes "$esp_mnt" "${ESP_OLD[@]}")"
data_old="$(old_bytes "$data_mnt" "${DATA_OLD[@]}")"
esp_avail="$(df -B1 --output=avail -- "$esp_mnt" | awk 'NR == 2 { print $1 }')"
data_avail="$(df -B1 --output=avail -- "$data_mnt" | awk 'NR == 2 { print $1 }')"
esp_short=$(( esp_need + MARGIN_BYTES - esp_old - esp_avail ))
data_short=$(( data_need + MARGIN_BYTES - data_old - data_avail ))

echo "Space on AIRESCUE: needs $(mb "$esp_need") MB, has $(mb "$(( esp_avail + esp_old ))") MB."
echo "Space on AIUSB:    needs $(mb "$data_need") MB, has $(mb "$(( data_avail + data_old ))") MB."
(( esp_short <= 0 )) || die "AIRESCUE needs $(mb "$esp_short") MB more free space."
(( data_short <= 0 )) || die "AIUSB needs $(mb "$data_short") MB more free space."

if [[ "$dry_run" == "yes" ]]; then
    echo ""
    echo "Dry run. Would copy:"
    echo "  ISO sources/ ($data_plan_end files) -> $data_mnt/sources/"
    for (( i = data_plan_end; i < ${#plan_src[@]}; i++ )); do
        echo "  ${plan_src[$i]#"$iso_mnt"/} -> ${plan_dst[$i]}"
    done
    echo "  ${iso_bootmgr#"$iso_mnt"/} -> $esp_mnt/$BOOTMGR_REL (last)"
    [[ -z "$grub_cfg_abs" ]] || echo "Would install the boot menu $grub_cfg_abs."
    echo "Nothing was changed."
    exit 0
fi

# ------------------------------------------------- remove the old installer

remove_rel "$esp_mnt" "$BOOTMGR_REL"
sync
for rel in "${ESP_OLD[@]}"; do
    remove_rel "$esp_mnt" "$rel"
done
for rel in "${DATA_OLD[@]}"; do
    remove_rel "$data_mnt" "$rel"
done
sync

# Marker first, so a rerun after an interruption may clean up the half-copied files.
mkdir -p -- "$esp_mnt/EFI/WinSetup"
printf 'Windows installer added by AI-USB add-win-installer.sh\nStatus: copying (incomplete)\n' \
    > "$esp_mnt/$MARKER_REL"
sync

# ------------------------------------------------------------------- copy

echo "Copying the installer files to AIUSB ($(mb "$data_need") MB, this takes several minutes)..."
mkdir -p -- "$data_mnt/sources"
if command -v rsync >/dev/null 2>&1; then
    rsync -r --inplace --no-perms --no-owner --no-group --no-times --info=progress2 \
        -- "$iso_sources/" "$data_mnt/sources/" || die "Copying to AIUSB failed."
else
    cp -r --no-preserve=all -- "$iso_sources/." "$data_mnt/sources/" || die "Copying to AIUSB failed."
fi

echo "Copying the boot files to AIRESCUE..."
for (( i = data_plan_end; i < ${#plan_src[@]}; i++ )); do
    mkdir -p -- "$(dirname -- "${plan_dst[$i]}")"
    cp --no-preserve=all -- "${plan_src[$i]}" "${plan_dst[$i]}" || die "Copying ${plan_dst[$i]} failed."
done

echo "Verifying (reads everything back from the stick)..."
sync
for (( i = 0; i < ${#plan_src[@]}; i++ )); do
    verify_file "${plan_src[$i]}" "${plan_dst[$i]}"
done
# Nothing extra on AIUSB (e.g. a file the copy produced under another name).
extra="$(comm -13 <(find "$iso_sources" -type f -printf '%P\n' | LC_ALL=C sort) \
                  <(find "$data_mnt/sources" -type f -printf '%P\n' | LC_ALL=C sort) | head -n 5 || true)"
[[ -z "$extra" ]] || die "Unexpected files in $data_mnt/sources: $extra"
echo "All ${#plan_src[@]} files verified."

# ------------------------------------------------- the boot manager, last

cp --no-preserve=all -- "$iso_bootmgr" "$esp_mnt/$BOOTMGR_REL" || die "Copying the boot manager failed."
sync
verify_file "$iso_bootmgr" "$esp_mnt/$BOOTMGR_REL"

{
    printf 'Windows installer added by AI-USB add-win-installer.sh\n'
    printf 'Status: complete\n'
    printf 'ISO: %s\n' "$(basename -- "$iso_abs")"
    printf 'ISO size: %s\n' "$(stat -c %s -- "$iso_abs")"
    printf 'ISO SHA-256: %s\n' "$iso_sha"
    printf 'Added: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$esp_mnt/$MARKER_REL"
sync

if [[ -n "$grub_cfg_abs" ]]; then
    install_grub_cfg
elif ! grep -q -F "/$BOOTMGR_REL" -- "$esp_mnt/boot/grub/grub.cfg" 2>/dev/null; then
    echo "Warning: the boot menu on the stick has no Windows entry yet; run again with --grub-cfg rescue/grub/grub.cfg."
fi

echo ""
echo "Done. Boot another PC from this stick and choose \"Install Windows 11\" in the menu."
