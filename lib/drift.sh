#!/usr/bin/env bash
# Omarchy version drift between a source manifest and a target machine (docs/engine.md "Version drift").
# Reusable comparison helpers: apply (#13/#14) and target-awareness (#15) call these. Needs jq for the *_machines/_manifest ones.
# shellcheck shell=bash

# drift_compare_versions SOURCE TARGET : prints same | source-older | source-newer | unknown
# "unknown" when either side is empty or "unknown" (Omarchy not a package there). Ordering is `sort -V`.
drift_compare_versions() {
  local s=$1 t=$2
  if [[ -z $s || $s == unknown || -z $t || $t == unknown ]]; then echo unknown; return 0; fi
  if [[ $s == "$t" ]]; then echo same; return 0; fi
  if [[ $(printf '%s\n%s\n' "$s" "$t" | sort -V | head -n1) == "$s" ]]; then echo source-older; else echo source-newer; fi
}

# drift_compare_machines SOURCE_MACHINE_JSON TARGET_MACHINE_JSON : drift_compare_versions on the two omarchy_version fields
drift_compare_machines() {
  drift_compare_versions "$(jq -r '.omarchy_version // "unknown"' <<<"$1")" "$(jq -r '.omarchy_version // "unknown"' <<<"$2")"
}

# drift_warn SOURCE_VERSION TARGET_VERSION : warn on stderr unless the versions are the same; always returns 0
drift_warn() {
  local s=$1 t=$2
  case $(drift_compare_versions "$s" "$t") in
    same) ;;
    unknown) warn "Omarchy version unknown (source: ${s:-unknown}, target: ${t:-unknown}); cannot tell whether defaults differ" ;;
    source-older) warn "manifest is from Omarchy $s, this machine runs $t: items may have become part of Omarchy defaults; packages already installed here are reported as present" ;;
    source-newer) warn "manifest is from Omarchy $s, newer than this machine's $t: items may need things this version lacks" ;;
  esac
  return 0
}

# drift_check_manifest MANIFEST_FILE [TARGET_VERSION] : drift_warn for the manifest's machine.omarchy_version against
# TARGET_VERSION (default: this machine's, from machine.sh)
drift_check_manifest() {
  local src tgt=${2-}
  src=$(jq -r '.machine.omarchy_version // "unknown"' "$1") || return 1
  if (($# < 2)); then tgt=$(machine_omarchy_version); fi
  drift_warn "$src" "$tgt"
}
