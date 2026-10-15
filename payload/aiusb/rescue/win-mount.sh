#!/usr/bin/env bash
# win-mount.sh - detect / unlock (BitLocker) / mount Windows volumes.
# Implements docs/ARCHITECTURE.md section 8. Runs as root in the AI-USB
# rescue system (Debian 13). Recovery keys are never logged or echoed.

set -uo pipefail

readonly LOG_DIR=/mnt/aiusb/aiusb/logs
readonly LOG_FILE="$LOG_DIR/rescue-actions.log"
readonly STATE_FILE=/run/aiusb-winmount.state
readonly WIN_MNT=/mnt/win
readonly ESP_MNT=/mnt/win-esp
readonly WINDOWS_LINK=/mnt/windows
readonly EFI_PARTTYPE=c12a7328-f81f-11d2-ba4b-00a0c93ec93b

usage() {
  cat <<'EOF'
win-mount.sh - detect, unlock and mount Windows volumes (AI-USB rescue)

Usage:
  win-mount.sh --scan               list Windows-related block devices
  win-mount.sh --mount-all [--ro]   unlock BitLocker and mount all volumes
  win-mount.sh --status             show what is mounted where
  win-mount.sh --umount-all         unmount everything this script opened

--ro mounts everything read-only.

NTFS volumes are mounted under /mnt/win/<name>, EFI partitions under
/mnt/win-esp/<name>. The NTFS volume holding Windows/System32/config/SYSTEM
is linked at /mnt/windows. The AI-USB stick itself is never touched.
EOF
}

log_action() {
  # One non-secret line per action; the log dir exists only with the stick.
  local msg="$1"
  [[ -d "$LOG_DIR" ]] || return 0
  printf '%s win-mount %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

state_add() {
  printf '%s\n' "$1" >> "$STATE_FILE" 2>/dev/null || true
}

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    printf 'win-mount.sh must run as root.\n' >&2
    exit 1
  fi
}

need_tools() {
  local t=""
  for t in lsblk jq findmnt; do
    if ! command -v "$t" >/dev/null 2>&1; then
      printf 'win-mount.sh: missing required tool: %s\n' "$t" >&2
      exit 1
    fi
  done
}

list_devices() {
  # One TSV line per candidate volume: path, size, fstype, label, kind.
  # Excludes the AI-USB stick (the disk holding the AIUSB/AIRESCUE labels and
  # all of its partitions) plus loop/rom/zram/crypt devices.
  local json=""
  json="$(lsblk -J -o PATH,PKNAME,TYPE,FSTYPE,LABEL,SIZE,PARTTYPE 2>/dev/null)" || {
    printf 'win-mount.sh: lsblk failed\n' >&2
    return 1
  }
  printf '%s' "$json" | jq -r --arg efi "$EFI_PARTTYPE" '
    def flat: ., ((.children // [])[] | flat);
    (.blockdevices // []) as $root
    | ([ $root[] | flat ]) as $bd
    | ( [ $bd[] | select(.label == "AIUSB" or .label == "AIRESCUE")
                   | (.pkname // empty) ] | unique ) as $stick
    | $bd[]
    | select(.type != "loop" and .type != "rom" and .type != "zram" and .type != "crypt")
    | select(((.path // "") | ltrimstr("/dev/")) as $k | ($stick | index($k)) == null)
    | select((.pkname // "") as $pk | ($stick | index($pk)) == null)
    | select(.type == "part" or (.type == "disk" and .fstype != null))
    | (.fstype // "") as $fst
    | ((.parttype // "") | ascii_downcase) as $pt
    | (if $fst == "BitLocker" then "bitlocker"
       elif $fst == "ntfs" then "ntfs"
       elif $pt == $efi then "efi"
       else "other" end) as $kind
    # Every field is non-empty ("-" if unknown): bash read treats a run of tabs as one.
    | [ .path, (.size // "-"), (if $fst == "" then "-" else $fst end),
        (if (.label // "") == "" then "-" else .label end), $kind ]
    | @tsv
  ' || {
    printf 'win-mount.sh: jq failed\n' >&2
    return 1
  }
}

mounted_at() {
  findmnt -rn "$1" >/dev/null 2>&1
}

source_mounted() {
  findmnt -rn -S "$1" >/dev/null 2>&1
}

mounted_where() {
  local w=""
  w="$(findmnt -rn -S "$1" -o TARGET 2>/dev/null)"
  printf '%s' "$w"
}

bitlk_opened_via() {
  # Echoes cryptsetup, dislocker or nothing for a kernel device name.
  local kname="$1"
  if [[ -e "/dev/mapper/bitlk-$kname" ]]; then
    printf 'cryptsetup\n'
  elif [[ -e "/run/dislocker/$kname/dislocker-file" ]]; then
    printf 'dislocker\n'
  fi
  return 0
}

unmount_path() {
  local mp="$1"
  umount "$mp" 2>/dev/null && return 0
  fusermount -u "$mp" 2>/dev/null && return 0
  return 1
}

ntfs_mount() {
  # ntfs_mount <device> <mountpoint> <rw|ro> <yes|no: needs a loop device>
  local dev="$1" mp="$2" mode="$3" loop="$4"
  if [[ "$loop" == "yes" ]]; then
    if [[ "$mode" == "rw" ]]; then
      mount -t ntfs-3g -o loop,windows_names "$dev" "$mp"
    else
      mount -t ntfs-3g -o loop,ro "$dev" "$mp"
    fi
  else
    if [[ "$mode" == "rw" ]]; then
      ntfs-3g -o windows_names "$dev" "$mp"
    else
      ntfs-3g -o ro "$dev" "$mp"
    fi
  fi
}

ntfs_mount_hiberfile_removed() {
  local dev="$1" mp="$2" loop="$3"
  if [[ "$loop" == "yes" ]]; then
    mount -t ntfs-3g -o loop,remove_hiberfile,windows_names "$dev" "$mp"
  else
    ntfs-3g -o remove_hiberfile,windows_names "$dev" "$mp"
  fi
}

link_windows_if_system() {
  # The first mounted NTFS volume with the Windows registry gets /mnt/windows.
  local mp="$1"
  if [[ -e "$mp/Windows/System32/config/SYSTEM" || -e "$mp/windows/system32/config/system" ]]; then
    if [[ -e "$WINDOWS_LINK" ]]; then
      return 0
    fi
    if ln -sfn "$mp" "$WINDOWS_LINK" 2>/dev/null; then
      log_action "symlink /mnt/windows -> $mp"
      printf '  Windows system volume: %s (also at /mnt/windows)\n' "$mp"
    else
      printf '  Could not create the /mnt/windows link\n'
    fi
  fi
}

unlock_bitlocker() {
  local dev="$1" label="$2"
  local kname="" mapper="" ddir="" via="" ans=""
  kname="$(basename "$dev")"
  mapper="bitlk-$kname"
  ddir="/run/dislocker/$kname"

  via="$(bitlk_opened_via "$kname")"
  if [[ -n "$via" ]]; then
    printf '  %s: already unlocked (%s)\n' "$kname" "$via"
    return 0
  fi

  printf '\n%s%s is encrypted with BitLocker.\n' "$dev" "${label:+ ($label)}"
  printf 'To unlock it you need its 48-digit BitLocker recovery key.\n'
  printf 'Where to find it:\n'
  printf '  - https://aka.ms/myrecoverykey (sign in with the Microsoft account of this PC),\n'
  printf '  - a printout or saved copy made when BitLocker was turned on,\n'
  printf '  - the helpdesk / IT administrator of this PC.\n'
  printf 'Type the key at the next prompt. Press Enter on an empty prompt to skip.\n'

  if cryptsetup open --type bitlk "$dev" "$mapper"; then
    state_add "bitlk $mapper $dev"
    log_action "bitlk-open $mapper"
    printf '  %s: unlocked as /dev/mapper/%s\n' "$kname" "$mapper"
    return 0
  fi

  printf '  Unlock failed (wrong key or skipped).\n'
  read -r -p '  Try once more with dislocker? [y/N] ' ans
  if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
    mkdir -p "$ddir"
    if dislocker -V "$dev" -p -- "$ddir"; then
      state_add "dislocker $ddir $dev"
      log_action "dislocker-open $ddir"
      printf '  %s: unlocked with dislocker in %s\n' "$kname" "$ddir"
      return 0
    fi
    printf '  dislocker could not unlock it either.\n'
    rmdir "$ddir" 2>/dev/null || true
  fi
  printf '  %s stays locked. Run win-mount.sh --mount-all again to retry.\n' "$kname"
  return 1
}

mount_ntfs_volume() {
  local dev="$1" name="$2" mode="$3" loop="$4"
  local mp="$WIN_MNT/$name"
  local note="-" ans="" ok=0 mounted=""

  if mounted_at "$mp"; then
    printf '  %s: already mounted at %s\n' "$name" "$mp"
    link_windows_if_system "$mp"
    return 0
  fi
  if [[ "$loop" == "no" ]] && source_mounted "$dev"; then
    printf '  %s: %s is already mounted at %s - skipped\n' "$name" "$dev" "$(mounted_where "$dev")"
    return 0
  fi

  mkdir -p "$mp" || return 1

  if [[ "$mode" == "ro" ]]; then
    ntfs_mount "$dev" "$mp" ro "$loop" && { ok=1; mounted=ro; }
  elif ntfs_mount "$dev" "$mp" rw "$loop"; then
    ok=1
    mounted=rw
  else
    printf '  %s: read-write mount failed (Windows hibernated, Fast Startup or unclean volume).\n' "$name"
    if ntfs_mount "$dev" "$mp" ro "$loop"; then
      ok=1
      mounted=ro
      note=hibernated-or-unclean
      printf '  %s: mounted READ-ONLY so the disk stays safe.\n' "$name"
      printf '  Manual fix: ntfs-3g -o remove_hiberfile,windows_names %s %s\n' "$dev" "$mp"
      printf '  It discards the saved hibernated Windows session (unsaved work is lost).\n'
      read -r -p '  Discard the session and mount read-write now? [y/N] ' ans
      if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
        if unmount_path "$mp"; then
          if ntfs_mount_hiberfile_removed "$dev" "$mp" "$loop"; then
            mounted=rw
            note=hiberfile-removed
            printf '  %s: hibernated session discarded, mounted read-write.\n' "$name"
          else
            printf '  %s: discarding failed - mounting read-only again.\n' "$name"
            ntfs_mount "$dev" "$mp" ro "$loop" || true
            mounted=ro
          fi
        else
          printf '  %s: could not unmount the read-only mount - keeping it read-only.\n' "$name"
        fi
      fi
    fi
  fi

  if [[ "$ok" != "1" ]]; then
    printf '  %s: could NOT be mounted (%s)\n' "$name" "$dev"
    rmdir "$mp" 2>/dev/null || true
    return 1
  fi

  state_add "mount $mp $dev $mounted $note"
  log_action "mount $mp $mounted note=$note"
  if [[ "$note" == "-" ]]; then
    printf '  %s: mounted %s at %s\n' "$name" "$mounted" "$mp"
  else
    printf '  %s: mounted %s at %s (%s)\n' "$name" "$mounted" "$mp" "$note"
  fi
  link_windows_if_system "$mp"
  return 0
}

mount_efi_volume() {
  local dev="$1" name="$2" mode="$3"
  local mp="$ESP_MNT/$name"

  if mounted_at "$mp"; then
    printf '  %s: already mounted at %s\n' "$name" "$mp"
    return 0
  fi
  if source_mounted "$dev"; then
    printf '  %s: %s is already mounted at %s - skipped\n' "$name" "$dev" "$(mounted_where "$dev")"
    return 0
  fi

  mkdir -p "$mp" || return 1
  if [[ "$mode" == "ro" ]]; then
    mount -t vfat -o ro "$dev" "$mp" || {
      printf '  %s: mount FAILED\n' "$name"
      rmdir "$mp" 2>/dev/null || true
      return 1
    }
  else
    mount -t vfat "$dev" "$mp" || {
      printf '  %s: mount FAILED\n' "$name"
      rmdir "$mp" 2>/dev/null || true
      return 1
    }
  fi
  state_add "mount $mp $dev $mode -"
  log_action "mount $mp $mode"
  printf '  %s: EFI partition mounted %s at %s\n' "$name" "$mode" "$mp"
  return 0
}

cmd_scan() {
  local rows_text="" row="" path="" size="" fstype="" label="" kind=""
  rows_text="$(list_devices)" || return 1
  if [[ -z "$rows_text" ]]; then
    printf 'No Windows volumes found (the AI-USB stick is excluded).\n'
    return 0
  fi
  printf '%-17s %-8s %-11s %-16s %s\n' DEVICE SIZE FSTYPE LABEL KIND
  while IFS= read -r row; do
    IFS=$'\t' read -r path size fstype label kind <<< "$row"
    printf '%-17s %-8s %-11s %-16s %s\n' "$path" "$size" "$fstype" "$label" "$kind"
  done <<< "$rows_text"
  printf 'kind: bitlocker = encrypted, ntfs = Windows data, efi = EFI system, other = rest\n'
}

cmd_mount_all() {
  local mode="$1"
  local rows_text="" row="" path="" label="" kind="" kname="" via=""
  local dev="" name="" loop="" failures=0

  rows_text="$(list_devices)" || return 1
  if [[ -z "$rows_text" ]]; then
    printf 'No Windows volumes found on this PC.\n'
    return 0
  fi
  local -a rows=()
  mapfile -t rows <<< "$rows_text"

  mkdir -p "$WIN_MNT" "$ESP_MNT"
  log_action "mount-all mode=$mode"

  printf 'BitLocker volumes:\n'
  local shown=0
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r path _ _ label kind <<< "$row"
    if [[ "$kind" != "bitlocker" ]]; then
      continue
    fi
    shown=1
    [[ "$label" != "-" ]] || label=""
    unlock_bitlocker "$path" "$label" || true
  done
  if [[ "$shown" -eq 0 ]]; then
    printf '  (none)\n'
  fi

  printf 'Mounting NTFS volumes:\n'
  shown=0
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r path _ _ _ kind <<< "$row"
    kname="$(basename "$path")"
    dev=""
    name=""
    loop=no
    if [[ "$kind" == "ntfs" ]]; then
      dev="$path"
      name="$kname"
      loop=no
    elif [[ "$kind" == "bitlocker" ]]; then
      via="$(bitlk_opened_via "$kname")"
      if [[ "$via" == "cryptsetup" ]]; then
        dev="/dev/mapper/bitlk-$kname"
        name="bitlk-$kname"
        loop=no
      elif [[ "$via" == "dislocker" ]]; then
        dev="/run/dislocker/$kname/dislocker-file"
        name="bitlk-$kname"
        loop=yes
      else
        printf '  %s: locked (no key given) - not mounted\n' "$kname"
        continue
      fi
    else
      continue
    fi
    shown=1
    mount_ntfs_volume "$dev" "$name" "$mode" "$loop" || failures=$((failures + 1))
  done
  if [[ "$shown" -eq 0 ]]; then
    printf '  (no NTFS volumes)\n'
  fi

  printf 'Mounting EFI partitions:\n'
  shown=0
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r path _ _ _ kind <<< "$row"
    if [[ "$kind" != "efi" ]]; then
      continue
    fi
    shown=1
    mount_efi_volume "$path" "$(basename "$path")" "$mode" || failures=$((failures + 1))
  done
  if [[ "$shown" -eq 0 ]]; then
    printf '  (none)\n'
  fi

  printf 'Done. Run win-mount.sh --status for a summary.\n'
  if [[ "$failures" -ne 0 ]]; then
    return 1
  fi
  return 0
}

cmd_status() {
  local line="" tag="" f1="" f2="" f3="" f4="" mounts=0
  local rows_text="" row="" path="" kind="" kname="" via="" locked=""

  if [[ -f "$STATE_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] || continue
      read -r tag f1 f2 f3 f4 <<< "$line"
      case "$tag" in
        mount)
          if mounted_at "$f1"; then
            if [[ -n "$f4" && "$f4" != "-" ]]; then
              printf '  %-28s %-2s %-36s %s\n' "$f1" "$f3" "$f2" "$f4"
            else
              printf '  %-28s %-2s %-36s\n' "$f1" "$f3" "$f2"
            fi
          else
            printf '  %-28s %-2s %-36s (no longer mounted)\n' "$f1" "$f3" "$f2"
          fi
          mounts=$((mounts + 1))
          ;;
        bitlk)
          if [[ -e "/dev/mapper/$f1" ]]; then
            printf '  bitlk open: %s (%s)\n' "$f1" "$f2"
          fi
          ;;
        dislocker)
          if [[ -e "$f1/dislocker-file" ]]; then
            printf '  bitlk open: %s via dislocker (%s)\n' "$(basename "$f1")" "$f2"
          fi
          ;;
      esac
    done < "$STATE_FILE"
  fi
  if [[ "$mounts" -eq 0 ]]; then
    printf '  (no volumes mounted by win-mount)\n'
  fi

  rows_text="$(list_devices)" || return 1
  while IFS= read -r row; do
    IFS=$'\t' read -r path _ _ _ kind <<< "$row"
    if [[ "$kind" == "bitlocker" ]]; then
      kname="$(basename "$path")"
      via="$(bitlk_opened_via "$kname")"
      if [[ -z "$via" ]]; then
        locked="$locked $path"
      fi
    fi
  done <<< "$rows_text"
  if [[ -n "$locked" ]]; then
    printf 'BitLocker still locked:%s\n' "$locked"
  fi

  if [[ -L "$WINDOWS_LINK" ]]; then
    printf '/mnt/windows -> %s\n' "$(readlink "$WINDOWS_LINK")"
  else
    printf '/mnt/windows: not set\n'
  fi
}

cmd_umount_all() {
  local -a lines=()
  local i=0 n=0 line="" tag="" f1="" f2="" failed=0

  if [[ ! -f "$STATE_FILE" ]]; then
    if [[ -e "$WINDOWS_LINK" || -L "$WINDOWS_LINK" ]]; then
      rm -f "$WINDOWS_LINK"
      log_action "remove-symlink /mnt/windows"
    fi
    printf 'Nothing to unmount.\n'
    return 0
  fi

  mapfile -t lines < "$STATE_FILE"
  n=${#lines[@]}
  if [[ "$n" -eq 0 ]]; then
    rm -f "$STATE_FILE"
    printf 'Nothing to unmount.\n'
    return 0
  fi
  for (( i = n - 1; i >= 0; i-- )); do
    line="${lines[$i]}"
    [[ -n "$line" ]] || continue
    read -r tag f1 f2 _ <<< "$line"
    case "$tag" in
      mount)
        if ! mounted_at "$f1"; then
          rmdir "$f1" 2>/dev/null || true
        elif unmount_path "$f1"; then
          log_action "umount $f1"
          rmdir "$f1" 2>/dev/null || true
        elif umount -l "$f1" 2>/dev/null; then
          printf '  %s was busy - detached lazily\n' "$f1"
          log_action "umount-lazy $f1"
        else
          printf '  Could not unmount %s - close programs using it and run --umount-all again.\n' "$f1"
          failed=1
        fi
        ;;
      bitlk)
        if [[ ! -e "/dev/mapper/$f1" ]]; then
          continue
        fi
        if cryptsetup close "$f1" 2>/dev/null; then
          log_action "bitlk-close $f1"
        else
          printf '  Could not close %s (still in use).\n' "$f1"
          failed=1
        fi
        ;;
      dislocker)
        if mounted_at "$f1"; then
          if unmount_path "$f1"; then
            log_action "dislocker-close $f1"
          else
            printf '  Could not unmount %s.\n' "$f1"
            failed=1
          fi
        fi
        # Only remove the (now empty) mount dir; never recurse into a live FUSE mount.
        if ! mounted_at "$f1"; then
          rmdir -- "$f1" 2>/dev/null || true
        fi
        ;;
    esac
  done

  rm -f "$STATE_FILE"
  if [[ -e "$WINDOWS_LINK" || -L "$WINDOWS_LINK" ]]; then
    rm -f "$WINDOWS_LINK"
    log_action "remove-symlink /mnt/windows"
  fi

  if [[ "$failed" -eq 0 ]]; then
    printf 'All Windows volumes unmounted.\n'
    return 0
  fi
  printf 'Some volumes are still mounted - see the messages above.\n'
  return 1
}

main() {
  local cmd="${1:-}"
  local mode=""

  case "$cmd" in
    -h|--help)
      usage
      return 0
      ;;
  esac
  case "$cmd" in
    --scan|--status|--mount-all|--umount-all) ;;
    *)
      usage >&2
      return 1
      ;;
  esac

  require_root
  need_tools

  case "$cmd" in
    --scan)
      cmd_scan
      ;;
    --mount-all)
      mode=rw
      if [[ "${2:-}" == "--ro" ]]; then
        mode=ro
      elif [[ -n "${2:-}" ]]; then
        usage >&2
        return 1
      fi
      if [[ -n "${3:-}" ]]; then
        usage >&2
        return 1
      fi
      cmd_mount_all "$mode"
      ;;
    --status)
      cmd_status
      ;;
    --umount-all)
      cmd_umount_all
      ;;
  esac
}

main "$@"