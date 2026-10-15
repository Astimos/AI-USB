#!/usr/bin/env bash
# Test stand-in for Windows' tar.exe (bsdtar built WITHOUT regex support).
# Accepts only the options that `tar.exe --help` lists on Windows 10/11 and fails on anything
# else the way the real one does (e.g. "-s is not supported by this version of bsdtar"),
# then runs the real bsdtar. Used by tests/test-launcher-ps1.ps1 as $script:TAREXE.
set -uo pipefail

readonly SHORT_OK="crtuxbfvwzjJCkmOp"    # mode letters and the short options of tar.exe --help
readonly SHORT_VALUE="bfC"                # short options that take a value
want_value=0
for arg in "$@"; do
  if [[ "$want_value" -eq 1 ]]; then
    want_value=0
    continue
  fi
  case "$arg" in
    --exclude|--format)
      want_value=1
      ;;
    --exclude=*|--format=*|--lzma)
      ;;
    --*)
      printf 'tar.exe: Option %s is not supported\n' "${arg%%=*}" >&2
      exit 1
      ;;
    -?*)
      flags="${arg#-}"
      for (( i = 0; i < ${#flags}; i++ )); do
        c="${flags:i:1}"
        if [[ "$SHORT_OK" != *"$c"* ]]; then
          printf 'tar.exe: -%s is not supported by this version of bsdtar\n' "$c" >&2
          exit 1
        fi
        if [[ "$SHORT_VALUE" == *"$c"* ]]; then
          want_value=1
        fi
      done
      ;;
  esac
done
exec bsdtar "$@"
