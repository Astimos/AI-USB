#!/usr/bin/env bash
# shellcheck disable=SC2034  # rc, before, all_before are read inside the eval strings of check()
# Tests for scripts/add-win-installer.sh without root and without a real stick.
# Re-execs itself in a user + mount namespace (unshare -r -m): there EUID is 0, /run is a
# private tmpfs, and the fake AIRESCUE / AIUSB "partitions" and the fake ISO are tmpfs dirs.
# lsblk, findmnt and mount are mocked through BASH_ENV (sourced by the script's bash):
# the fake device's partitions are bind-mounted instead of really mounted. Nothing outside
# the namespace is touched; the real disks cannot even be opened by this user.
set -uo pipefail

repo="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
script="${AIUSB_TEST_SCRIPT:-$repo/scripts/add-win-installer.sh}"
grubcfg="$repo/rescue/grub/grub.cfg"

pass=0
fail=0

ok()   { pass=$((pass + 1)); echo "ok   - $1"; }
bad()  { fail=$((fail + 1)); echo "FAIL - $1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/       /' | tail -n 15; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${out:-}"; fi; }

# A block device path for the -b test only: the mocks answer every query about it and
# every mount of its fake partitions; this user cannot open the real device anyway.
export FAKE_DEV=/dev/nvme0n1
[[ -b "$FAKE_DEV" ]] || FAKE_DEV="$(lsblk -d -n -p -o NAME | head -n 1)"
export FAKE_P1="/dev/FAKEUSB1" FAKE_P2="/dev/FAKEUSB2"
export FAKE_SERIAL="TEST123"

write_mocks() {
cat > "$1" <<'EOF'
lsblk() {
    local cols="" target="" a
    for a in "$@"; do
        case "$a" in
            -o) ;;
            -*) ;;
            *) if [[ -z "$cols" && "$a" =~ ^[A-Z,]+$ ]]; then cols="$a"; else target="$a"; fi ;;
        esac
    done
    case "$target" in
        "$FAKE_DEV")
            case "$cols" in
                TYPE) echo "${FAKE_TYPE:-disk}" ;;
                TRAN) echo "${FAKE_TRAN:-usb}" ;;
                RM) echo "1" ;;
                SERIAL) echo "$FAKE_SERIAL" ;;
                VENDOR) echo "Kingston" ;;
                MODEL) echo "DataTraveler 3.0" ;;
                NAME) echo "$FAKE_DEV"; echo "$FAKE_P1"; echo "$FAKE_P2"; [[ -z "${FAKE_P3:-}" ]] || echo "$FAKE_P3" ;;
                NAME,TYPE) echo "$FAKE_DEV disk"; echo "$FAKE_P1 part"; echo "$FAKE_P2 part"; [[ -z "${FAKE_P3:-}" ]] || echo "$FAKE_P3 part" ;;
                *) echo "" ;;
            esac ;;
        "$FAKE_P1") case "$cols" in FSTYPE) echo "${FAKE_P1_FS:-exfat}" ;; LABEL) echo "${FAKE_P1_LABEL:-AIUSB}" ;; *) echo "" ;; esac ;;
        "$FAKE_P2") case "$cols" in FSTYPE) echo "vfat" ;; LABEL) echo "AIRESCUE" ;; *) echo "" ;; esac ;;
        *) command lsblk "$@" ;;
    esac
}
findmnt() {
    local a prev="" src=""
    for a in "$@"; do [[ "$prev" == "--source" ]] && src="$a"; prev="$a"; done
    if [[ -n "$src" ]]; then
        case "$src" in
            "$FAKE_P1") [[ -n "${FAKE_P1_MNT:-}" ]] && { echo "$FAKE_P1_MNT"; return 0; }; return 1 ;;
            "$FAKE_P2") [[ -n "${FAKE_P2_MNT:-}" ]] && { echo "$FAKE_P2_MNT"; return 0; }; return 1 ;;
            "$FAKE_DEV") return 1 ;;
        esac
    fi
    command findmnt "$@"
}
mount() {
    local args=("$@") n=$# src dst ro="no" a
    src="${args[$((n - 2))]}"; dst="${args[$((n - 1))]}"
    for a in "$@"; do [[ "$a" == ro || "$a" == *loop* ]] && ro="yes"; done
    case "$src" in
        "$FAKE_P1") src="$FAKE_P1_DIR" ;;
        "$FAKE_P2") src="$FAKE_P2_DIR" ;;
        *.iso) src="$FAKE_ISO_DIR" ;;
        *) command mount "$@"; return ;;
    esac
    command mount --bind "$src" "$dst" || return 1
    if [[ "$ro" == "yes" ]]; then command mount -o remount,bind,ro "$dst"; fi
}
if [[ -n "${FAKE_CMP_FAIL:-}" ]]; then
    cmp() { if [[ "${*: -1}" == *"$FAKE_CMP_FAIL" ]]; then return 1; fi; command cmp "$@"; }
fi
EOF
}

run() { out="$(bash "$script" "$@" 2>&1)"; rc=$?; }
base=(--device "$FAKE_DEV" --serial "$FAKE_SERIAL")

if [[ "${AIUSB_TEST_NS:-}" != "1" ]]; then
    # Outside the namespace (real non-root user): only the argument and device checks run.
    O="$(mktemp -d)"
    write_mocks "$O/mocks.sh"
    printf 'x' > "$O/win.iso"
    export BASH_ENV="$O/mocks.sh"
    run "${base[@]}" --iso "$O/win.iso" --dry-run
    check "non-root dry run checks the device only" '[[ $rc -eq 0 && "$out" == *"Dry run without root"* ]]'
    run "${base[@]}" --iso "$O/win.iso"
    check "non-root real run refused" '[[ $rc -ne 0 && "$out" == *"must run as root"* ]]'
    run --device "$FAKE_DEV" --serial WRONG --iso "$O/win.iso" --dry-run
    check "non-root dry run still checks the serial" '[[ $rc -ne 0 && "$out" == *"Serial number mismatch"* ]]'
    unset BASH_ENV
    rm -r "$O"
    env AIUSB_TEST_NS=1 unshare -r -m --propagation private bash "$0" "$@"
    inner=$?
    echo "outer: passed $pass, failed $fail"
    [[ $fail -eq 0 && $inner -eq 0 ]]
    exit
fi

T="$(mktemp -d)"
mount -t tmpfs tmpfs "$T"
mount -t tmpfs tmpfs /run
write_mocks "$T/mocks.sh"
export BASH_ENV="$T/mocks.sh"

rnd() { head -c "$2" /dev/urandom > "$1"; }

# Fake ISO tree (lowercase, like the real UDF layer) + a dummy .iso file for --sha256.
make_iso() {
    local d="$1" v="$2"
    mkdir -p "$d"/{efi/boot,efi/microsoft/boot/fonts,efi/microsoft/boot/resources,boot/fonts,sources/en-gb,sources/sxs,support}
    rnd "$d/efi/boot/bootx64.efi" 2000
    rnd "$d/efi/microsoft/boot/bcd" 3000
    for f in cdboot.efi cdboot_noprompt.efi efisys.bin efisys_noprompt.bin bootmgfw.efi memtest.efi boot.stl; do
        rnd "$d/efi/microsoft/boot/$f" 1000
    done
    rnd "$d/efi/microsoft/boot/fonts/segoe_slboot.ttf" 1500
    rnd "$d/efi/microsoft/boot/resources/bootres.dll" 1500
    rnd "$d/boot/boot.sdi" 3000
    rnd "$d/boot/bcd" 3000
    rnd "$d/sources/boot.wim" 3000000
    rnd "$d/sources/install.wim" 5000000
    rnd "$d/sources/setup.exe" 4000
    rnd "$d/sources/en-gb/setup.exe.mui" 1000
    rnd "$d/sources/sxs/pkg.cab" 2000
    printf '%s\n' "$v" > "$d/sources/version.txt"
    rnd "$d/setup.exe" 1000
    rnd "$d/support/x.dll" 1000
    printf '[autorun]\n' > "$d/autorun.inf"
}

# Fake stick: AIRESCUE (ESP) and AIUSB (data) as size-limited tmpfs mounts.
make_stick() {
    local esp_size="${1:-200m}"
    for m in "$T/esp" "$T/data"; do
        mountpoint -q "$m" && umount "$m"
        mkdir -p "$m"
    done
    mount -t tmpfs -o "size=$esp_size" tmpfs "$T/esp"
    mount -t tmpfs -o size=400m tmpfs "$T/data"
    mkdir -p "$T/esp"/{EFI/BOOT,EFI/debian,boot/grub,live,.disk}
    rnd "$T/esp/EFI/BOOT/BOOTX64.EFI" 1000
    rnd "$T/esp/EFI/BOOT/grubx64.efi" 1000
    printf 'stub\n' > "$T/esp/EFI/debian/grub.cfg"
    printf 'old menu\n' > "$T/esp/boot/grub/grub.cfg"
    rnd "$T/esp/live/vmlinuz" 5000
    mkdir -p "$T/data/aiusb/vault" "$T/data/aiusb/launcher"
    rnd "$T/data/aiusb/vault/home.tar.age" 20000
    printf 'readme\n' > "$T/data/README.txt"
    printf 'cmd\n' > "$T/data/Start AI Agent.cmd"
    export FAKE_P2_DIR="$T/esp" FAKE_P1_DIR="$T/data"
}

# Checksums of everything that is NOT installer content (must never change).
snap() {
    (cd "$T/esp" && find . -type f ! -path './EFI/WinSetup/*' ! -path './EFI/Microsoft/*' \
        ! -path './sources/*' ! -path './boot/boot.sdi' ! -path './boot/grub/grub.cfg*' -print0 | sort -z | xargs -0 sha256sum)
    (cd "$T/data" && find . -type f ! -path './sources/*' -print0 | sort -z | xargs -0 sha256sum)
}
snapall() { (cd "$T" && find esp data -type f -print0 | sort -z | xargs -0 sha256sum); }

make_iso "$T/iso1" one
make_iso "$T/iso2" two
rnd "$T/win.iso" 4096
iso_sha="$(sha256sum "$T/win.iso" | awk '{ print $1 }')"
export FAKE_ISO_DIR="$T/iso1"
make_stick

# ---------------------------------------------------------------- arguments
run;                                               check "no arguments refused"            '[[ $rc -ne 0 && "$out" == *"Missing --device"* ]]'
run "${base[@]}";                                  check "missing --iso/--remove refused"  '[[ $rc -ne 0 && "$out" == *"Missing --iso or --remove"* ]]'
run "${base[@]}" --iso "$T/win.iso" --remove;      check "--iso with --remove refused"     '[[ $rc -ne 0 && "$out" == *"not both"* ]]'
run "${base[@]}" --iso "$T/win.iso" --sha256 abc;  check "bad --sha256 refused"            '[[ $rc -ne 0 && "$out" == *"64 hex"* ]]'
run "${base[@]}" --iso "$T/nope.iso";              check "missing ISO refused"             '[[ $rc -ne 0 && "$out" == *"Cannot read the ISO"* ]]'
printf 'no entry\n' > "$T/plain.cfg"
run "${base[@]}" --iso "$T/win.iso" --grub-cfg "$T/plain.cfg"
check "grub.cfg without the entry refused" '[[ $rc -ne 0 && "$out" == *"no Windows installer entry"* ]]'

# ---------------------------------------------------------------- device checks
run --device "$FAKE_DEV" --serial WRONG --iso "$T/win.iso"
check "wrong serial refused" '[[ $rc -ne 0 && "$out" == *"Serial number mismatch"* ]]'
FAKE_TRAN=sata run "${base[@]}" --iso "$T/win.iso"
check "non-USB disk refused" '[[ $rc -ne 0 && "$out" == *"not a USB device"* ]]'
FAKE_P3=/dev/FAKEUSB3 run "${base[@]}" --iso "$T/win.iso"
check "three partitions refused" '[[ $rc -ne 0 && "$out" == *"has 3 partitions"* ]]'
FAKE_P1_LABEL=DATA run "${base[@]}" --iso "$T/win.iso"
check "wrong data label refused" '[[ $rc -ne 0 && "$out" == *"not an AI-USB stick"* ]]'
run --device "$FAKE_P1" --serial X --iso "$T/win.iso"
check "non-block device refused" '[[ $rc -ne 0 && "$out" == *"not a block device"* ]]'

# ---------------------------------------------------------------- dry run (root)
before="$(snapall)"
run "${base[@]}" --iso "$T/win.iso" --grub-cfg "$grubcfg" --dry-run
check "dry run succeeds" '[[ $rc -eq 0 && "$out" == *"Nothing was changed"* ]]'
check "dry run plans boot.wim and bootx64.efi" '[[ "$out" == *"sources/boot.wim -> "* && "$out" == *"EFI/WinSetup/bootx64.efi (last)"* ]]'
check "dry run changed nothing" '[[ "$(snapall)" == "$before" ]]'
check "dry run left no mounts in /run" '! findmnt -n -l -o TARGET | grep -q "^/run/aiusb-wininst"'

# ---------------------------------------------------------------- full add (script mounts)
before="$(snap)"
run "${base[@]}" --iso "$T/win.iso" --sha256 "${iso_sha^^}" --grub-cfg "$grubcfg"
check "add succeeds" '[[ $rc -eq 0 && "$out" == *"All "*" files verified"* && "$out" == *"Done."* ]]'
check "boot manager at EFI/WinSetup" 'cmp -s "$T/iso1/efi/boot/bootx64.efi" "$T/esp/EFI/WinSetup/bootx64.efi"'
check "BCD at EFI/Microsoft/Boot" 'cmp -s "$T/iso1/efi/microsoft/boot/bcd" "$T/esp/EFI/Microsoft/Boot/bcd"'
check "fonts and resources copied" '[[ -f "$T/esp/EFI/Microsoft/Boot/fonts/segoe_slboot.ttf" && -f "$T/esp/EFI/Microsoft/Boot/resources/bootres.dll" ]]'
check "CD-only files and bootmgfw.efi left out" '[[ -z "$(find "$T/esp/EFI/Microsoft" -iname "cdboot*" -o -iname "efisys*" -o -iname bootmgfw.efi)" ]]'
check "no bootmgfw.efi anywhere on AIRESCUE" '[[ -z "$(find "$T/esp" -iname bootmgfw.efi)" ]]'
check "boot.sdi and boot.wim on AIRESCUE" 'cmp -s "$T/iso1/boot/boot.sdi" "$T/esp/boot/boot.sdi" && cmp -s "$T/iso1/sources/boot.wim" "$T/esp/sources/boot.wim"'
check "AIRESCUE sources holds only boot.wim" '[[ "$(ls "$T/esp/sources")" == "boot.wim" ]]'
check "AIUSB sources identical to ISO sources" 'diff -r "$T/iso1/sources" "$T/data/sources" >/dev/null'
check "nothing else from the ISO on AIUSB" '[[ ! -e "$T/data/setup.exe" && ! -e "$T/data/autorun.inf" && ! -e "$T/data/efi" ]]'
check "marker complete with checksum" 'grep -q "^Status: complete" "$T/esp/EFI/WinSetup/INSTALLER.TXT" && grep -q "SHA-256: $iso_sha" "$T/esp/EFI/WinSetup/INSTALLER.TXT"'
check "grub.cfg installed, old kept as .bak" 'cmp -s "$grubcfg" "$T/esp/boot/grub/grub.cfg" && grep -q "old menu" "$T/esp/boot/grub/grub.cfg.bak"'
check "vault, launchers and rescue untouched" '[[ "$(snap)" == "$before" ]]'
check "script unmounted what it mounted" '! findmnt -n -l -o TARGET | grep -q "^/run/aiusb-wininst"'
check "temp dirs removed" '! compgen -G "/run/aiusb-wininst*" >/dev/null'

# ---------------------------------------------------------------- rerun: replace, reuse mounts
mkdir -p /run/media/AIUSB /run/media/AIRESCUE
mount --bind "$T/data" /run/media/AIUSB
mount --bind "$T/esp" /run/media/AIRESCUE
printf 'stale\n' > "$T/data/sources/stale-from-old-version.txt"
before="$(snap)"
FAKE_ISO_DIR="$T/iso2" FAKE_P1_MNT=/run/media/AIUSB FAKE_P2_MNT=/run/media/AIRESCUE run "${base[@]}" --iso "$T/win.iso"
check "replace succeeds with desktop mounts" '[[ $rc -eq 0 && "$out" == *"already mounted at /run/media/AIUSB"* ]]'
check "new version copied" 'diff -r "$T/iso2/sources" "$T/data/sources" >/dev/null && grep -q two "$T/data/sources/version.txt"'
check "stale file from old version gone" '[[ ! -e "$T/data/sources/stale-from-old-version.txt" ]]'
check "marker says checksum not checked" 'grep -q "SHA-256: not checked" "$T/esp/EFI/WinSetup/INSTALLER.TXT"'
check "desktop mounts left mounted" 'mountpoint -q /run/media/AIUSB && mountpoint -q /run/media/AIRESCUE'
check "grub.cfg kept (no --grub-cfg)" 'cmp -s "$grubcfg" "$T/esp/boot/grub/grub.cfg"'
check "rest untouched on replace" '[[ "$(snap)" == "$before" ]]'
umount /run/media/AIUSB /run/media/AIRESCUE

# ---------------------------------------------------------------- read-only desktop mount
mkdir -p /run/media/RO
mount --bind "$T/data" /run/media/RO
mount -o remount,bind,ro /run/media/RO
FAKE_P1_MNT=/run/media/RO run "${base[@]}" --iso "$T/win.iso"
check "read-only existing mount refused" '[[ $rc -ne 0 && "$out" == *"mounted read-only"* ]]'
umount /run/media/RO

# ---------------------------------------------------------------- wrong checksum
before="$(snapall)"
run "${base[@]}" --iso "$T/win.iso" --sha256 "$(printf '0%.0s' {1..64})"
check "wrong checksum refused" '[[ $rc -ne 0 && "$out" == *"checksum does not match"* ]]'
check "nothing changed after wrong checksum" '[[ "$(snapall)" == "$before" ]]'

# ---------------------------------------------------------------- warning without menu entry
printf 'old menu\n' > "$T/esp/boot/grub/grub.cfg"
run "${base[@]}" --iso "$T/win.iso"
check "warns when the stick menu has no entry" '[[ $rc -eq 0 && "$out" == *"has no Windows entry yet"* ]]'

# ---------------------------------------------------------------- interrupted run (verify fails)
FAKE_CMP_FAIL="sources/boot.wim" run "${base[@]}" --iso "$T/win.iso"
check "verify failure stops the run" '[[ $rc -ne 0 && "$out" == *"Verify failed"* ]]'
check "no menu entry after failed run" '[[ ! -e "$T/esp/EFI/WinSetup/bootx64.efi" ]]'
check "marker says incomplete" 'grep -q "incomplete" "$T/esp/EFI/WinSetup/INSTALLER.TXT"'
run "${base[@]}" --iso "$T/win.iso" --grub-cfg "$grubcfg"
check "rerun after failure succeeds" '[[ $rc -eq 0 && -f "$T/esp/EFI/WinSetup/bootx64.efi" ]]'

# ---------------------------------------------------------------- not enough space
make_stick 66m
before="$(snapall)"
run "${base[@]}" --iso "$T/win.iso"
check "too little space on AIRESCUE refused" '[[ $rc -ne 0 && "$out" == *"AIRESCUE needs"*"more free space"* ]]'
check "nothing changed when short of space" '[[ "$(snapall)" == "$before" ]]'
make_stick

# ---------------------------------------------------------------- foreign sources folder
mkdir -p "$T/data/sources"
printf 'my notes\n' > "$T/data/sources/notes.txt"
before="$(snapall)"
run "${base[@]}" --iso "$T/win.iso"
check "foreign AIUSB sources folder protected" '[[ $rc -ne 0 && "$out" == *"not a Windows installer"* ]]'
check "foreign folder untouched" '[[ "$(snapall)" == "$before" ]]'
run "${base[@]}" --remove
check "remove also protects a foreign folder" '[[ $rc -ne 0 && -f "$T/data/sources/notes.txt" ]]'
rm -r "$T/data/sources"

# ---------------------------------------------------------------- bad ISO
make_iso "$T/iso3" three
rm "$T/iso3/sources/setup.exe" "$T/iso3/sources/install.wim"
before="$(snapall)"
FAKE_ISO_DIR="$T/iso3" run "${base[@]}" --iso "$T/win.iso"
check "non-Windows ISO refused" '[[ $rc -ne 0 && "$out" == *"Missing: sources/setup.exe sources/install.wim|esd|swm"* ]]'
check "nothing changed for a bad ISO" '[[ "$(snapall)" == "$before" ]]'

# ---------------------------------------------------------------- mixed-case ISO, install.esd
make_iso "$T/iso4" four
mv "$T/iso4/efi/boot/bootx64.efi" "$T/iso4/efi/boot/BOOTX64.EFI"
mv "$T/iso4/efi" "$T/iso4/EFI"
mv "$T/iso4/sources/install.wim" "$T/iso4/sources/install.esd"
mv "$T/iso4/sources" "$T/iso4/Sources"
FAKE_ISO_DIR="$T/iso4" run "${base[@]}" --iso "$T/win.iso"
check "mixed-case ISO with install.esd works" '[[ $rc -eq 0 && -f "$T/data/sources/install.esd" && -f "$T/esp/EFI/WinSetup/bootx64.efi" ]]'

# ---------------------------------------------------------------- remove
run "${base[@]}" --iso "$T/win.iso" --grub-cfg "$grubcfg"
before="$(snap)"
all_before="$(snapall)"
run "${base[@]}" --remove --dry-run
check "remove dry run lists, deletes nothing" '[[ $rc -eq 0 && "$out" == *"EFI/WinSetup/bootx64.efi"* && "$(snapall)" == "$all_before" ]]'
run "${base[@]}" --remove --grub-cfg "$grubcfg"
check "remove succeeds" '[[ $rc -eq 0 && "$out" == *"was removed"* ]]'
check "all installer files gone" '[[ ! -e "$T/esp/EFI/WinSetup" && ! -e "$T/esp/EFI/Microsoft" && ! -e "$T/esp/boot/boot.sdi" && ! -e "$T/esp/sources" && ! -e "$T/data/sources" ]]'
check "rest untouched by remove" '[[ "$(snap)" == "$before" ]]'
run "${base[@]}" --remove
check "remove on a clean stick is a no-op" '[[ $rc -eq 0 ]]'

# ---------------------------------------------------------------- real ISO file names
# tests/data-win11-26h2-files.txt = every file path of Microsoft's Windows 11 26H2 ISO
# (7z l -slt). Small stand-in files with exactly those names check the copy plan.
list="$repo/tests/data-win11-26h2-files.txt"
if [[ -f "$list" ]]; then
    make_stick
    while IFS= read -r rel; do
        mkdir -p "$T/isoreal/$(dirname -- "$rel")"
        printf '%s\n' "$rel" > "$T/isoreal/$rel"
    done < "$list"
    FAKE_ISO_DIR="$T/isoreal" run "${base[@]}" --iso "$T/win.iso" --grub-cfg "$grubcfg"
    check "real ISO names: add succeeds" '[[ $rc -eq 0 ]]'
    want_esp="$(grep -i '^efi/microsoft/boot/' "$list" | grep -v -i -E '/(cdboot[^/]*\.efi|efisys[^/]*\.bin|bootmgfw\.efi)$' | sed 's|^efi/microsoft/boot/|EFI/Microsoft/Boot/|' | LC_ALL=C sort)"
    have_esp="$(cd "$T/esp" && find EFI/Microsoft -type f | LC_ALL=C sort)"
    check "real ISO names: EFI/Microsoft/Boot = ISO minus CD-only files" '[[ "$have_esp" == "$want_esp" && -n "$have_esp" ]]'
    check "real ISO names: CI policies copied" '[[ -f "$T/esp/EFI/Microsoft/Boot/cipolicies/active/{82443e1e-8a39-4b4a-96a8-f40ddc00b9f3}.cip" ]]'
    nsrc="$(grep -c '^sources/' "$list")"
    check "real ISO names: AIUSB sources = ISO sources ($nsrc files)" \
        '[[ "$(cd "$T/data/sources" && find . -type f | wc -l)" -eq "$nsrc" ]] && diff -r "$T/isoreal/sources" "$T/data/sources" >/dev/null'
    check "real ISO names: root files (bootmgfw.efi, setup.exe) not copied" \
        '[[ -z "$(find "$T/esp" "$T/data" -maxdepth 1 \( -iname bootmgfw.efi -o -iname setup.exe -o -iname autorun.inf \))" ]]'
fi

echo ""
echo "passed: $pass, failed: $fail"
[[ $fail -eq 0 ]]
