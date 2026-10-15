#!/usr/bin/env bash
#
# AI-USB: build the Debian 13 (trixie) rescue live system.
# Contract: docs/ARCHITECTURE.md sections 2.1 and 4.
#
# Runs as root on the Arch/CachyOS developer machine (pkexec or sudo).
#
# Usage: build-rescue-rootfs.sh [--repo DIR] [--keep-rootfs]
#
# Outputs:
#   <repo>/build/rescue/live/{vmlinuz,initrd.img,filesystem.squashfs,VERSION}
#   <repo>/build/rescue/efi/{shim,mm,grub,gcd}x64.efi.signed
#   <repo>/build/rescue/ovmf/*.fd

set -euo pipefail
umask 022

readonly SCRIPT_NAME="${0##*/}"

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [--repo DIR] [--keep-rootfs]

Build the Debian 13 rescue live system into <repo>/build/rescue/.

Options:
  --repo DIR     Repository root (default: parent of this script's directory).
  --keep-rootfs  Keep <repo>/build/rescue-work/rootfs after the build.
  -h, --help     Show this help.

Must run as root:  sudo ./${SCRIPT_NAME}   or   pkexec ./${SCRIPT_NAME}
EOF
}

log_step() {
  printf '\n=== %s ===\n' "$1"
}

require_file() {
  if [[ ! -f "$1" ]]; then
    echo "ERROR: required file not found: $1" >&2
    exit 1
  fi
}

require_dir() {
  if [[ ! -d "$1" ]]; then
    echo "ERROR: required directory not found: $1" >&2
    exit 1
  fi
}

# --------------------------------------------------------------------------
# Chroot mount tracking (safety-critical)
# --------------------------------------------------------------------------

declare -a MOUNTS=()

chroot_mount() {
  # Bind /dev, /dev/pts, /proc, /sys into the rootfs and give it a fresh
  # tmpfs /run (never the host's). Every mount is recorded in MOUNTS.
  # Each bind is made a slave right away: with systemd's shared propagation a
  # mount or umount below the chroot would otherwise propagate back to the
  # host (e.g. the chroot's dev/pts stacking onto the host's /dev).
  local src
  mkdir -p "$ROOT/dev" "$ROOT/dev/pts" "$ROOT/proc" "$ROOT/sys" "$ROOT/run"
  for src in /dev /dev/pts /proc /sys; do
    if ! mountpoint -q "$ROOT$src"; then
      mount --bind "$src" "$ROOT$src"
      MOUNTS+=("$ROOT$src")
      mount --make-rslave "$ROOT$src"
    fi
  done
  if ! mountpoint -q "$ROOT/run"; then
    mount -t tmpfs tmpfs "$ROOT/run"
    MOUNTS+=("$ROOT/run")
  fi
  echo "Chroot mounts active: ${#MOUNTS[@]}"
}

chroot_umount() {
  # Unmount everything MOUNTS recorded, in reverse order.
  # Recursive umount first, lazy umount as a last resort.
  local i mount_point
  for (( i = ${#MOUNTS[@]} - 1; i >= 0; i-- )); do
    mount_point="${MOUNTS[$i]}"
    if mountpoint -q "$mount_point"; then
      umount -R "$mount_point" 2>/dev/null \
        || umount -l "$mount_point" 2>/dev/null \
        || echo "WARNING: could not unmount $mount_point" >&2
    fi
  done
  MOUNTS=()
}

verify_rootfs_unmounted() {
  # Refuse to continue if anything is still mounted at or below ROOT.
  local found=""
  found="$(findmnt -rn -R "$ROOT" 2>/dev/null || true)"
  if [[ -z "$found" ]]; then
    # Belt and braces: read the kernel mount table directly.
    found="$(awk -v p="$ROOT" 'index($2, p) == 1 { print $2 }' /proc/self/mounts 2>/dev/null || true)"
  fi
  if [[ -n "$found" ]]; then
    echo "ERROR: filesystems are still mounted at or below $ROOT:" >&2
    printf '%s\n' "$found" >&2
    echo "Refusing to delete. Unmount them by hand, then re-run." >&2
    return 1
  fi
  return 0
}

safe_remove_rootfs() {
  # The ONLY place allowed to run rm -rf on ROOT.
  if [[ "$ROOT" != */build/rescue-work/rootfs ]]; then
    echo "ERROR: refusing to remove unexpected ROOT path: $ROOT" >&2
    exit 1
  fi
  if [[ -e "$ROOT" ]]; then
    chroot_umount
    verify_rootfs_unmounted
    rm -rf -- "$ROOT"
  fi
}

run_in_root() {
  # Run a command inside the rootfs with a clean, minimal environment.
  chroot "$ROOT" /usr/bin/env -i \
    HOME=/root \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    TERM="${TERM:-dumb}" \
    LANG=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive \
    "$@"
}

on_exit() {
  local rc=$?
  chroot_umount
  exit "$rc"
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

REPO=""
KEEP_ROOTFS="0"

while (( $# > 0 )); do
  case "$1" in
    --repo)
      if (( $# < 2 )); then
        echo "ERROR: --repo needs a directory argument" >&2
        exit 1
      fi
      REPO="$2"
      shift 2
      ;;
    --repo=*)
      REPO="${1#*=}"
      shift
      ;;
    --keep-rootfs)
      KEEP_ROOTFS="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ${EUID} -ne 0 ]]; then
  echo "ERROR: this script must run as root (pkexec or sudo)." >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -z "$REPO" ]]; then
  REPO="$(dirname -- "$SCRIPT_DIR")"
fi
if [[ ! -d "$REPO" || "$REPO" == "/" ]]; then
  echo "ERROR: repository directory not found: $REPO" >&2
  exit 1
fi
REPO="$(cd -- "$REPO" && pwd -P)"

readonly REPO
readonly WORK="$REPO/build/rescue-work"
readonly ROOT="$WORK/rootfs"
readonly OUT="$REPO/build/rescue"
readonly PACKAGES_FILE="$REPO/rescue/packages.txt"
readonly OVERLAY_DIR="$REPO/rescue/overlay"

# The user who started the build (pkexec sets PKEXEC_UID, sudo sets SUDO_USER).
# The output tree is chowned to them at the end.
INVOKING_UID=""
if [[ -n "${PKEXEC_UID:-}" ]] && [[ "${PKEXEC_UID}" =~ ^[0-9]+$ ]]; then
  INVOKING_UID="${PKEXEC_UID}"
elif [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
  INVOKING_UID="$(id -u "${SUDO_USER}")"
fi
readonly INVOKING_UID

# Step 1: check the host tools.
missing_tools=()
for tool in debootstrap mksquashfs chroot findmnt; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    missing_tools+=("$tool")
  fi
done
if (( ${#missing_tools[@]} > 0 )); then
  printf 'ERROR: missing tools: %s\n' "${missing_tools[*]}" >&2
  echo 'Install them on Arch/CachyOS with:' >&2
  echo '  pacman -S --needed debootstrap debian-archive-keyring squashfs-tools' >&2
  exit 1
fi
if [[ ! -f /usr/share/keyrings/debian-archive-keyring.gpg ]]; then
  echo 'ERROR: /usr/share/keyrings/debian-archive-keyring.gpg not found.' >&2
  echo 'Install it with:' >&2
  echo '  pacman -S --needed debootstrap debian-archive-keyring squashfs-tools' >&2
  exit 1
fi

require_file "$PACKAGES_FILE"
require_dir "$OVERLAY_DIR"

mkdir -p "$WORK" "$OUT"

# Log everything to the terminal and to $WORK/build.log.
exec > >(tee -a "$WORK/build.log") 2>&1

trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

echo "AI-USB rescue rootfs build"
echo "  started: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "  repo:    $REPO"
echo "  work:    $WORK"
echo "  rootfs:  $ROOT"
echo "  output:  $OUT"
if [[ "$KEEP_ROOTFS" == "1" ]]; then
  echo "  keep-rootfs: yes"
fi

# Step 2: fresh rootfs, then debootstrap trixie.
log_step "Step 2: fresh rootfs and debootstrap"
safe_remove_rootfs
mkdir -p "$ROOT"
debootstrap \
  --arch=amd64 \
  --variant=minbase \
  --components=main,contrib,non-free,non-free-firmware \
  --keyring=/usr/share/keyrings/debian-archive-keyring.gpg \
  trixie "$ROOT" http://deb.debian.org/debian

# Step 3: apt sources, hostname, hosts.
log_step "Step 3: apt sources, hostname, hosts"
cat > "$ROOT/etc/apt/sources.list" <<'SOURCES'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
SOURCES

printf 'aiusb-rescue\n' > "$ROOT/etc/hostname"
cat > "$ROOT/etc/hosts" <<'HOSTS'
127.0.0.1       localhost
127.0.1.1       aiusb-rescue
::1             localhost ip6-localhost ip6-loopback
HOSTS

# Remove first: if the target were a symlink, cp would write through it,
# possibly onto a host path. The copy is deleted again in step 9.
rm -f -- "$ROOT/etc/resolv.conf"
cp -L /etc/resolv.conf "$ROOT/etc/resolv.conf"

# Step 4: mount, update, install packages.
log_step "Step 4: mount chroot and install packages"
chroot_mount

# Block service starts inside the chroot while packages install.
mkdir -p "$ROOT/usr/sbin"
printf '#!/bin/sh\n# AI-USB build: never start services inside the chroot.\nexit 101\n' \
  > "$ROOT/usr/sbin/policy-rc.d"
chmod 755 "$ROOT/usr/sbin/policy-rc.d"

# Preseed the keyboard and console questions so nothing prompts (layout us).
printf '%s\n' \
  'keyboard-configuration keyboard-configuration/layoutcode string us' \
  'keyboard-configuration keyboard-configuration/variantcode string' \
  'console-setup console-setup/codeset string Lat15' \
  'console-setup console-setup/charmap select UTF-8' \
  'console-setup console-setup/fontface select Fixed' \
  'console-setup console-setup/fontsize-fb string 8x16' \
  | run_in_root debconf-set-selections

run_in_root apt-get update

packages=()
package_line=""
while IFS= read -r package_line || [[ -n "$package_line" ]]; do
  package_line="${package_line%%#*}"
  package_line="${package_line#"${package_line%%[![:space:]]*}"}"
  package_line="${package_line%"${package_line##*[![:space:]]}"}"
  if [[ -n "$package_line" ]]; then
    packages+=("$package_line")
  fi
done < "$PACKAGES_FILE"
if (( ${#packages[@]} == 0 )); then
  echo "ERROR: no packages listed in $PACKAGES_FILE" >&2
  exit 1
fi

echo "Installing ${#packages[@]} packages (no recommends)..."
run_in_root apt-get install -y --no-install-recommends "${packages[@]}"

echo "Installing firefox-esr (with recommends)..."
run_in_root apt-get install -y firefox-esr

# Step 5: locale, timezone, machine-id, network, initramfs modules.
log_step "Step 5: base configuration"
mkdir -p "$ROOT/etc/default"
printf 'LANG=C.UTF-8\n' > "$ROOT/etc/default/locale"
ln -sf /usr/share/zoneinfo/Etc/UTC "$ROOT/etc/localtime"
printf 'Etc/UTC\n' > "$ROOT/etc/timezone"

run_in_root passwd -l root

# Empty machine-id (keep the file): systemd generates a fresh one per boot.
: > "$ROOT/etc/machine-id"

run_in_root systemctl enable NetworkManager
run_in_root systemctl mask systemd-networkd-wait-online.service NetworkManager-wait-online.service
# The signature updater would pull ~300 MB into RAM on every boot and lock out a
# manual freshclam; the agents run freshclam when they need it.
run_in_root systemctl disable clamav-freshclam.service || true

touch "$ROOT/etc/initramfs-tools/modules"
cat >> "$ROOT/etc/initramfs-tools/modules" <<'MODULES'
# AI-USB: modules needed to find and mount the USB stick at boot.
vfat
nls_cp437
nls_ascii
nls_utf8
exfat
usb_storage
uas
xhci_pci
nvme
MODULES

# Step 6: copy the rescue overlay.
log_step "Step 6: copy the rescue overlay"
# install(1) per file: root-owned files, and existing directories such as
# /root keep their modes (cp -a would copy the repo's uid and dir modes).
while IFS= read -r -d '' overlay_file; do
  install -D -o root -g root -m 0644 "$OVERLAY_DIR/$overlay_file" "$ROOT/$overlay_file"
done < <(cd "$OVERLAY_DIR" && find . -type f -printf '%P\0')
if [[ -d "$ROOT/usr/local/sbin" ]]; then
  find "$ROOT/usr/local/sbin" -type f -exec chmod 755 {} +
fi
if [[ -d "$ROOT/usr/local/bin" ]]; then
  find "$ROOT/usr/local/bin" -type f -exec chmod 755 {} +
fi

# Step 7: regenerate the initramfs so live-boot hooks are included.
log_step "Step 7: update-initramfs"
run_in_root update-initramfs -u -k all

# Step 8: fetch the signed EFI binaries and OVMF test firmware.
log_step "Step 8: fetch signed EFI files and OVMF firmware"
mkdir -p "$ROOT/tmp/efi-debs" "$ROOT/tmp/efi-x"
run_in_root sh -c 'cd /tmp/efi-debs && apt-get download shim-signed shim-helpers-amd64-signed grub-efi-amd64-signed ovmf'
for deb_path in "$ROOT"/tmp/efi-debs/*.deb; do
  if [[ ! -f "$deb_path" ]]; then
    continue
  fi
  run_in_root dpkg-deb -x "/tmp/efi-debs/${deb_path##*/}" /tmp/efi-x
done

mkdir -p "$OUT/efi" "$OUT/ovmf"
require_file "$ROOT/tmp/efi-x/usr/lib/shim/shimx64.efi.signed"
require_file "$ROOT/tmp/efi-x/usr/lib/shim/mmx64.efi.signed"
require_file "$ROOT/tmp/efi-x/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed"
require_file "$ROOT/tmp/efi-x/usr/lib/grub/x86_64-efi-signed/gcdx64.efi.signed"
cp "$ROOT/tmp/efi-x/usr/lib/shim/shimx64.efi.signed" "$OUT/efi/"
cp "$ROOT/tmp/efi-x/usr/lib/shim/mmx64.efi.signed" "$OUT/efi/"
cp "$ROOT/tmp/efi-x/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed" "$OUT/efi/"
cp "$ROOT/tmp/efi-x/usr/lib/grub/x86_64-efi-signed/gcdx64.efi.signed" "$OUT/efi/"

ovmf_found="0"
for ovmf_file in "$ROOT"/tmp/efi-x/usr/share/OVMF/OVMF*_4M*.fd; do
  if [[ -f "$ovmf_file" ]]; then
    cp "$ovmf_file" "$OUT/ovmf/"
    ovmf_found="1"
  fi
done
if [[ "$ovmf_found" != "1" ]]; then
  echo "ERROR: no OVMF *_4M*.fd firmware files were found." >&2
  exit 1
fi

rm -rf -- "$ROOT/tmp/efi-debs" "$ROOT/tmp/efi-x"

# Step 9: clean the rootfs, then unmount.
log_step "Step 9: clean the rootfs and unmount"
run_in_root apt-get clean
rm -rf -- "$ROOT"/var/lib/apt/lists/*
rm -f -- "$ROOT"/var/cache/apt/*.bin
find "$ROOT/tmp" -mindepth 1 -delete
rm -f -- "$ROOT"/var/log/*.log
rm -f -- "$ROOT/usr/sbin/policy-rc.d"
rm -f -- "$ROOT/etc/resolv.conf"   # NetworkManager writes it at boot
chroot_umount

# Step 10: kernel, initrd, squashfs, VERSION.
log_step "Step 10: build the live output"
mkdir -p "$OUT/live"

vmlinuz_count="0"
vmlinuz_path=""
for boot_file in "$ROOT"/boot/vmlinuz-*; do
  if [[ -f "$boot_file" ]]; then
    vmlinuz_count="$((vmlinuz_count + 1))"
    vmlinuz_path="$boot_file"
  fi
done
if [[ "$vmlinuz_count" != "1" ]]; then
  echo "ERROR: expected exactly one kernel in $ROOT/boot, found $vmlinuz_count." >&2
  exit 1
fi
kernel_version="${vmlinuz_path##*/vmlinuz-}"
initrd_path="$ROOT/boot/initrd.img-$kernel_version"
require_file "$initrd_path"

cp "$vmlinuz_path" "$OUT/live/vmlinuz"
cp "$initrd_path" "$OUT/live/initrd.img"

mksquashfs "$ROOT" "$OUT/live/filesystem.squashfs.tmp" \
  -noappend -comp zstd -Xcompression-level 15 -b 1M \
  -wildcards -e 'proc/*' 'sys/*' 'dev/*' 'run/*' 'tmp/*'
mv -f "$OUT/live/filesystem.squashfs.tmp" "$OUT/live/filesystem.squashfs"

package_count="$(grep -c '^Package:' "$ROOT/var/lib/dpkg/status" || true)"
{
  printf 'AI-USB rescue image\n'
  printf 'built=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'kernel=%s\n' "$kernel_version"
  printf 'packages=%s\n' "$package_count"
} > "$OUT/live/VERSION"

echo "Output sizes:"
du -h "$OUT/live/vmlinuz" "$OUT/live/initrd.img" "$OUT/live/filesystem.squashfs"
du -sh "$OUT/efi" "$OUT/ovmf"

# Step 11: cleanup and hand the output to the invoking user.
log_step "Step 11: finish"
if [[ "$KEEP_ROOTFS" == "1" ]]; then
  echo "Keeping the rootfs at $ROOT (--keep-rootfs)."
else
  safe_remove_rootfs
fi
if [[ -n "$INVOKING_UID" ]]; then
  chown -R "$INVOKING_UID" "$OUT"
fi

echo "Build finished: $OUT"