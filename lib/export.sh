#!/usr/bin/env bash
# `startkin export` (#11): the manifest to stdout or a private file; --from re-exports a saved snapshot. Contract: docs/engine.md.
# shellcheck shell=bash

# export_gate_snapshot TEXT : the pre-export secrets gate (docs/secrets-policy.md) over a manifest read from disk.
# Prints kind and JSON location of each finding to stderr, never the matched text. Returns 0 clean, 4 on findings.
# (scan_manifest runs the same check over live output; a snapshot did not come through that path.)
export_gate_snapshot() {
  local findings fc=0 n kind loc
  findings=$(secrets_check_manifest <(printf '%s\n' "$1")) || fc=$?
  ((fc)) || return 0
  n=$(grep -c . <<<"$findings")
  printf 'startkin: error: snapshot withheld: %d secret finding(s) (docs/secrets-policy.md)\n' "$n" >&2
  while IFS=$'\t' read -r kind loc; do
    [[ -n $kind ]] && printf 'startkin:   %s at %s\n' "$kind" "$loc" >&2
  done <<<"$findings"
  return 4
}

# export_read_snapshot FILE : print a saved manifest after checking it is one and passes the secrets gate.
export_read_snapshot() {
  local text
  [[ -f $1 && -r $1 ]] || { warn "export: cannot read snapshot: $1"; return 1; }
  text=$(<"$1")
  if ! jq -e 'type == "object" and has("schema_version") and (.items | type == "array")' <<<"$text" >/dev/null 2>&1; then
    warn "export: $1 is not a StartKin manifest (needs schema_version and items)"
    return 1
  fi
  export_gate_snapshot "$text" || return $?
  printf '%s\n' "$text"
}

# export_write FILE TEXT : replace FILE atomically with TEXT, mode 600 (a snapshot describes the whole machine).
export_write() {
  local tmp
  tmp=$(mktemp "$1.XXXXXX") || return 1
  if ! { printf '%s\n' "$2" >"$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$1"; }; then
    rm -f "$tmp"
    warn "export: cannot write $1"
    return 1
  fi
}

cmd_export() {
  local out="" from="" manifest rc=0
  while (($#)); do
    case $1 in
      --out | --from)
        (($# >= 2)) || die -c 2 "export: $1 needs a file"
        if [[ $1 == --out ]]; then out=$2; else from=$2; fi
        shift 2 ;;
      *) die -c 2 "export: unknown option: $1" ;;
    esac
  done
  require_cmd jq
  if [[ -n $from ]]; then
    manifest=$(export_read_snapshot "$from") || return $?
  else
    manifest=$(scan_manifest) || rc=$?
    # 3 = a scanner failed (manifest still complete for the rest); anything else printed nothing.
    ((rc == 0 || rc == 3)) || return "$rc"
  fi
  if [[ -n $out ]]; then
    export_write "$out" "$manifest" || return 1
  else
    printf '%s\n' "$manifest"
  fi
  return "$rc"
}
