# Task: write `scripts/build-rescue-rootfs.sh`

Builds the Debian 13 rescue live system (ARCHITECTURE §2.1 and §4) on an Arch/CachyOS host.
Runs as root (started via `pkexec` or `sudo`). Bash, `set -euo pipefail`.

## Usage
`build-rescue-rootfs.sh [--repo DIR] [--keep-rootfs]`
REPO = `--repo` or parent of the script dir. WORK = `$REPO/build/rescue-work`,
ROOT = `$WORK/rootfs`, OUT = `$REPO/build/rescue`. The invoking user is
`${PKEXEC_UID:-}` (numeric) or `${SUDO_USER:-}`; at the end `chown -R` OUT to that user.

## Safety (most important part, review-critical)
- Mount tracking: a function `chroot_mount` bind-mounts `/dev`, `/dev/pts`, `/proc`, `/sys`, `/run`
  (tmpfs, not the host's), and records each in an array; `chroot_umount` unmounts them in reverse
  order with `umount -R` fallback `umount -l`, and is installed as `trap ... EXIT`.
- Before ANY `rm -rf "$ROOT"`: call `chroot_umount`, then verify with `findmnt -R "$ROOT"`
  (or `grep " $ROOT" /proc/self/mounts`) that NOTHING is mounted below ROOT; if something is,
  abort WITHOUT deleting. Also verify `$ROOT` ends with `/build/rescue-work/rootfs`.
- `policy-rc.d` returning 101 inside the chroot during package installation (remove at the end).
- Never touch host files outside WORK/OUT.

## Steps
1. Check tools: debootstrap, mksquashfs, chroot, findmnt (print the pacman command to install
   missing ones: `pacman -S --needed debootstrap debian-archive-keyring squashfs-tools`).
2. Fresh ROOT (rm per the safety rules), then
   `debootstrap --arch=amd64 --variant=minbase --components=main,contrib,non-free,non-free-firmware --keyring=/usr/share/keyrings/debian-archive-keyring.gpg trixie "$ROOT" http://deb.debian.org/debian`.
3. `/etc/apt/sources.list` (deb822 not required) with `trixie`, `trixie-updates` and
   `trixie-security` (`http://security.debian.org/debian-security trixie-security`) for components
   `main contrib non-free non-free-firmware`. Write `/etc/hostname` = `aiusb-rescue`, `/etc/hosts`.
4. Mount, `apt-get update`, then install with `DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends`
   the package list in `$REPO/rescue/packages.txt` (one package per line, `#` comments; the file
   exists; read it, skip blanks/comments). Then `apt-get install -y` (WITH recommends) `firefox-esr`.
   Preseed `keyboard-configuration` and `console-setup` via `debconf-set-selections` to avoid prompts
   (layout `us`).
5. Configure: locale `C.UTF-8` (`/etc/default/locale` LANG=C.UTF-8), timezone UTC
   (`ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime`), root password locked (`passwd -l root`),
   empty `/etc/machine-id` (truncate, keep the file), `systemctl enable NetworkManager`,
   mask `systemd-networkd-wait-online.service` and `NetworkManager-wait-online.service`,
   `/etc/initramfs-tools/modules` append `vfat`, `nls_cp437`, `nls_ascii`, `nls_utf8`, `exfat`,
   `usb_storage`, `uas`, `xhci_pci`, `nvme`.
6. Copy the overlay: `cp -a "$REPO/rescue/overlay/." "$ROOT/"` and `chmod 755` the files under
   `usr/local/sbin` and `usr/local/bin`.
7. `chroot "$ROOT" update-initramfs -u -k all` (live-boot hooks get included).
8. Download (inside the chroot, into `/tmp/efi-debs`, using `apt-get download`) the packages
   `shim-signed shim-helpers-amd64-signed grub-efi-amd64-signed ovmf` and extract each with
   `dpkg-deb -x` inside the chroot to `/tmp/efi-x`. Copy out to `$OUT/efi/`:
   `shimx64.efi.signed`, `mmx64.efi.signed`, `grubx64.efi.signed`, `gcdx64.efi.signed`
   (from `/usr/lib/shim/` and `/usr/lib/grub/x86_64-efi-signed/`) and every `/usr/share/OVMF/OVMF*_4M*.fd`
   file into `$OUT/ovmf/`. Remove `/tmp/efi-debs` and `/tmp/efi-x` from the rootfs.
9. Clean: `apt-get clean`, remove `/var/lib/apt/lists/*`, `/var/cache/apt/*.bin`, `/tmp/*`,
   `/var/log/*.log`, policy-rc.d; then `chroot_umount`.
10. Output: `$OUT/live/vmlinuz` (copy of `$ROOT/boot/vmlinuz-*`, exactly one expected),
   `$OUT/live/initrd.img` (`$ROOT/boot/initrd.img-*`), `$OUT/live/filesystem.squashfs` via
   `mksquashfs "$ROOT" "$OUT/live/filesystem.squashfs.tmp" -noappend -comp zstd -Xcompression-level 15 -b 1M -wildcards -e 'proc/*' 'sys/*' 'dev/*' 'run/*' 'tmp/*'`
   then rename. Write `$OUT/live/VERSION` (date, kernel version, package count). Print sizes.
11. Unless `--keep-rootfs`, remove ROOT (safety rules). chown OUT to the invoking user.

Log everything to `$WORK/build.log` as well as the terminal (`exec > >(tee -a ...) 2>&1`).
Must pass `shellcheck -S warning`.
