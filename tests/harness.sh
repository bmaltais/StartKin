#!/usr/bin/env bash
# Shared per-file harness: sources the assert helper and provides run_tests, which runs every test_* function
# in a subshell with a fresh temp dir ($T_TMP) and a stub dir ($T_BIN) first on PATH.
# shellcheck shell=bash

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export ROOT
# shellcheck source=assert.sh
source "$ROOT/tests/assert.sh"

# stub NAME BODY : create an executable $T_BIN/NAME running BODY
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"$T_BIN/$1"; chmod +x "$T_BIN/$1"; }

run_tests() {
  local fn rc=0
  for fn in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do
    (
      T_TMP=$(mktemp -d) && T_BIN=$T_TMP/bin && mkdir -p "$T_BIN"
      trap 'rm -rf "$T_TMP"' EXIT
      export T_TMP T_BIN
      PATH=$T_BIN:$PATH
      "$fn"
      if ((T_FAILS)); then printf '  not ok  %s\n' "$fn" >&2; exit 1; fi
      printf '  ok      %s\n' "$fn"
    ) || rc=1
  done
  return $rc
}
