#!/usr/bin/env bash
# Build build/test/test.img: a small disk image with the same MBR layout as the stick
# (entry 1 AIUSB exFAT, entry 2 AIRESCUE FAT32) for testing in QEMU. No root needed:
# FAT is filled with mtools, exFAT through a udisks loop mount.
set -euo pipefail
repo="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
esp="$repo/build/esp"
payload="$repo/build/payload"
dir="$repo/build/test"
mkdir -p "$dir"
[[ -d "$esp" && -d "$payload" ]] || { echo "Need build/esp and build/payload first." >&2; exit 1; }

mib() { du -sm "$1" | cut -f1; }
esp_mib=$(( $(mib "$esp") + 256 ))
data_mib=$(( $(mib "$payload") + 1024 ))

echo "ESP ${esp_mib} MiB, data ${data_mib} MiB"
rm -f "$dir/esp.img" "$dir/data.img" "$dir/test.img"

# FAT32 boot partition
mkfs.fat -F 32 -n AIRESCUE -C "$dir/esp.img" $(( esp_mib * 1024 )) >/dev/null
( cd "$esp" && mcopy -s -i "$dir/esp.img" EFI boot live .disk ::/ )

# exFAT data partition
truncate -s "${data_mib}M" "$dir/data.img"
mkfs.exfat -L AIUSB "$dir/data.img" >/dev/null
loop=$(udisksctl loop-setup -f "$dir/data.img" --no-user-interaction | grep -o '/dev/loop[0-9]*')
cleanup() { udisksctl unmount -b "$loop" --no-user-interaction >/dev/null 2>&1 || true
            udisksctl loop-delete -b "$loop" --no-user-interaction >/dev/null 2>&1 || true; }
trap cleanup EXIT
sleep 1
mp=$(findmnt -rno TARGET "$loop" || true)
if [[ -z "$mp" ]]; then
    udisksctl mount -b "$loop" --no-user-interaction >/dev/null
    mp=$(findmnt -rno TARGET "$loop")
fi
cp -r "$payload/." "$mp/"
sync
cleanup
trap - EXIT

# Assemble the disk like the stick (MBR): 1 MiB gap, ESP (entry 2), data (entry 1)
total=$(( 1 + esp_mib + data_mib ))
truncate -s "${total}M" "$dir/test.img"
esp_start=2048
data_start=$(( esp_start + esp_mib * 2048 ))
printf 'label: dos\nstart=%s, size=%s, type=7\nstart=%s, size=%s, type=ef\n' \
    "$data_start" "$(( data_mib * 2048 ))" "$esp_start" "$(( esp_mib * 2048 ))" \
    | sfdisk --wipe always "$dir/test.img" >/dev/null
dd if="$dir/esp.img"  of="$dir/test.img" bs=512 seek="$esp_start" conv=notrunc,sparse status=none
dd if="$dir/data.img" of="$dir/test.img" bs=512 seek="$data_start" conv=notrunc,sparse status=none
rm -f "$dir/esp.img" "$dir/data.img"
sfdisk -d "$dir/test.img"
echo "Wrote $dir/test.img"
