#!/usr/bin/env bash
# shellcheck disable=SC2054  # QEMU options contain commas on purpose
# Boot build/test/test.img (or a given image) as a USB stick in QEMU.
#   --secureboot  UEFI with Secure Boot ON and Microsoft keys enrolled (Debian OVMF *.ms.fd)
#   --uefi        UEFI without Secure Boot (default)
#   --bios        legacy BIOS (SeaBIOS)
#   --headless    no window; VNC on :5 and QEMU monitor on build/test/qemu-monitor.sock
#   --windisk F   attach F as an extra (NVMe) disk, e.g. a fake "Windows" disk
set -euo pipefail
repo="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
img="$repo/build/test/test.img"; mode=uefi; display=(-display gtk); extra=()
ovmf="$repo/build/rescue/ovmf"
while (($#)); do
    case "$1" in
        --secureboot) mode=sb ;; --uefi) mode=uefi ;; --bios) mode=bios ;;
        --headless) display=(-display none -vnc :5 -monitor "unix:$repo/build/test/qemu-monitor.sock,server,nowait") ;;
        --windisk) extra+=(-drive "if=none,id=win,file=$2,format=raw" -device nvme,drive=win,serial=WIN0); shift ;;
        *) img="$1" ;;
    esac; shift
done
fw=()
case "$mode" in
    sb)   cp "$ovmf/OVMF_VARS_4M.ms.fd" "$repo/build/test/vars.fd"
          fw=(-machine q35,smm=on -global driver=cfi.pflash01,property=secure,value=on
              -drive "if=pflash,format=raw,unit=0,readonly=on,file=$ovmf/OVMF_CODE_4M.ms.fd"
              -drive "if=pflash,format=raw,unit=1,file=$repo/build/test/vars.fd") ;;
    uefi) cp "$ovmf/OVMF_VARS_4M.fd" "$repo/build/test/vars.fd"
          fw=(-machine q35
              -drive "if=pflash,format=raw,unit=0,readonly=on,file=$ovmf/OVMF_CODE_4M.fd"
              -drive "if=pflash,format=raw,unit=1,file=$repo/build/test/vars.fd") ;;
    bios) fw=(-machine q35) ;;
esac
exec qemu-system-x86_64 -enable-kvm -cpu host -smp 2 -m 2560 "${fw[@]}" \
    -device qemu-xhci,id=xhci \
    -drive "if=none,id=stick,file=$img,format=raw,snapshot=on" \
    -device usb-storage,bus=xhci.0,drive=stick,removable=on \
    -nic user,model=virtio-net-pci -vga virtio "${display[@]}" "${extra[@]}"
