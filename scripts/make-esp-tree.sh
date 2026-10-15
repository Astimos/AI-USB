#!/usr/bin/env bash
# Assemble build/esp: the exact file tree of the AIRESCUE (FAT32 EFI) partition.
# Inputs: build/rescue (from build-rescue-rootfs.sh) and rescue/grub. No root needed.
set -euo pipefail
repo="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
src="$repo/build/rescue"
out="$repo/build/esp"

for f in efi/shimx64.efi.signed efi/mmx64.efi.signed efi/grubx64.efi.signed \
         live/vmlinuz live/initrd.img live/filesystem.squashfs; do
    [[ -f "$src/$f" ]] || { echo "Missing $src/$f - run scripts/build-rescue-rootfs.sh first." >&2; exit 1; }
done

[[ "$out" == */build/esp ]] || exit 1
rm -rf -- "$out"
mkdir -p "$out/EFI/BOOT" "$out/EFI/debian" "$out/boot/grub" "$out/live" "$out/.disk"

# Secure Boot chain: firmware -> shim (Microsoft-signed) -> GRUB (Debian-signed) -> kernel (Debian-signed).
# fbx64.efi is deliberately NOT copied: shim's fallback would create boot entries in the host's NVRAM.
cp "$src/efi/shimx64.efi.signed" "$out/EFI/BOOT/BOOTX64.EFI"
cp "$src/efi/grubx64.efi.signed" "$out/EFI/BOOT/grubx64.efi"
cp "$src/efi/mmx64.efi.signed"   "$out/EFI/BOOT/mmx64.efi"
cp "$repo/rescue/grub/stub.cfg"  "$out/EFI/BOOT/grub.cfg"
cp "$repo/rescue/grub/stub.cfg"  "$out/EFI/debian/grub.cfg"
cp "$repo/rescue/grub/grub.cfg"  "$out/boot/grub/grub.cfg"
printf 'AI-USB Rescue\n' > "$out/.disk/info"
cp "$src/live/vmlinuz" "$src/live/initrd.img" "$src/live/filesystem.squashfs" "$out/live/"
[[ -f "$src/live/VERSION" ]] && cp "$src/live/VERSION" "$out/live/"

big=$(find "$out" -type f -size +4095M)
[[ -z "$big" ]] || { echo "File too large for FAT32: $big" >&2; exit 1; }
du -sh "$out"
