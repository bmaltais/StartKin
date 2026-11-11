#!/usr/bin/env bash
# Scanner plugin discovery and manifest assembly. Contract: docs/engine.md.
# STARTKIN_SCAN_DIR overrides lib/scan (tests).
# shellcheck shell=bash

# scan_dir : directory holding scanner files
scan_dir() { echo "${STARTKIN_SCAN_DIR:-$STARTKIN_ROOT/lib/scan}"; }

# scan_run_one FILE : run one scanner in a subshell; print its JSON array on stdout. Non-zero on any contract violation.
scan_run_one() {
  local file=$1 name fn out
  name=$(basename "$file" .sh)
  fn=scan_${name//-/_}
  out=$(
    # shellcheck disable=SC1090
    source "$file" || exit 1
    declare -F "$fn" >/dev/null || { echo "startkin: scanner '$name': $file does not define $fn" >&2; exit 1; }
    "$fn"
  ) || { warn "scanner '$name' failed"; return 1; }
  if ! jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    warn "scanner '$name' did not print a JSON array"
    return 1
  fi
  printf '%s\n' "$out"
}

# scan_collect : print the merged JSON array of all scanners' items; returns 3 if any scanner failed.
scan_collect() {
  local dir f out rc=0 parts=()
  dir=$(scan_dir)
  shopt -s nullglob
  for f in "$dir"/*.sh; do
    if out=$(scan_run_one "$f"); then parts+=("$out"); else rc=3; fi
  done
  shopt -u nullglob
  if ((${#parts[@]})); then printf '%s\n' "${parts[@]}" | jq -s 'add'; else echo '[]'; fi
  return $rc
}

# scan_manifest : the full manifest on stdout; returns 3 if any scanner failed (manifest still complete for the rest).
scan_manifest() {
  local items rc=0
  items=$(scan_collect) || rc=$?
  jq -n \
    --arg at "$(now_utc)" \
    --argjson machine "$(machine_json)" \
    --argjson items "$items" \
    '{schema_version: "1.0",
      generated_at: $at,
      machine: $machine,
      items: $items}'
  return $rc
}
