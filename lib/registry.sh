#!/usr/bin/env bash
# User-confirmed provenance registry (docs/adopt.md). Source this; it defines functions only.
#   STARTKIN_REGISTRY_FILE  the JSON file (default ${XDG_CONFIG_HOME:-~/.config}/startkin/registry.json)
# Needs lib/common.sh (warn, now_utc), lib/secrets.sh, lib/provenance.sh (prov_clean_url) and jq.
# shellcheck shell=bash

# shellcheck source=secrets.sh
source "${STARTKIN_ROOT:?}/lib/secrets.sh"
# shellcheck source=provenance.sh
source "$STARTKIN_ROOT/lib/provenance.sh"

registry_file() { echo "${STARTKIN_REGISTRY_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/startkin/registry.json}"; }

# registry_read : the registry document on stdout (an empty one when the file is missing); 1 when it is unreadable
registry_read() {
  local f
  f=$(registry_file)
  if [[ ! -e $f ]]; then
    echo '{"schema_version":"1.0","entries":{}}'
    return 0
  fi
  jq -ce 'select(.schema_version == "1.0" and (.entries | type) == "object")' "$f" 2>/dev/null | grep . ||
    { warn "registry $f is not a valid StartKin registry"; return 1; }
}

# registry_get ID : the entry on stdout, 1 when absent
registry_get() {
  local doc
  doc=$(registry_read) || return 1
  jq -ce --arg id "$1" '.entries[$id] // empty' <<<"$doc" | grep .
}

# registry_put ID INSTALL_JSON VERSION ORIGIN : record (or replace) a confirmed entry. ORIGIN is adopt or track.
# Refuses entries that carry secret patterns or a denied copy path; URL credentials are dropped.
registry_put() {
  local id=$1 install=$2 version=$3 origin=$4 doc entry kinds cat url path f tmp
  doc=$(registry_read) || return 1
  url=$(jq -r '.url // empty' <<<"$install")
  [[ -n $url ]] && install=$(jq -c --arg u "$(prov_clean_url "$url")" '.url = $u' <<<"$install")
  path=$(jq -r 'select(.type == "copy") | .path // empty' <<<"$install")
  if [[ -n $path ]] && cat=$(secrets_path_denied "$path"); then
    warn "refusing to record a copy of a $cat path"
    return 1
  fi
  entry=$(jq -nc --arg o "$origin" --argjson i "$install" --arg v "$version" --arg t "$(now_utc)" \
    '{origin: $o, install: $i, version: (if $v == "" then null else $v end), recorded_at: $t}')
  kinds=$(secrets_scan_text <<<"$id $entry" | cut -f1 | sort -u | paste -sd, -)
  if [[ -n $kinds ]]; then
    warn "refusing to record $id: secret pattern in entry ($kinds)"
    return 1
  fi
  f=$(registry_file)
  mkdir -p "$(dirname "$f")" || return 1
  tmp=$(mktemp "$f.XXXXXX") || return 1
  if jq --arg id "$id" --argjson e "$entry" '.entries[$id] = $e' <<<"$doc" >"$tmp"; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"
    return 1
  fi
}

# registry_overlay : read a JSON array of items on stdin; items with a registry entry get its install descriptor,
# provenance {method: user, confidence: 1} and (when the entry has one) its version. Items without one pass through.
registry_overlay() {
  local items doc
  items=$(cat)
  if ! doc=$(registry_read); then
    printf '%s\n' "$items"
    return 0
  fi
  # the entries go in through a file descriptor: a big registry would exceed the argv limit
  jq -c --slurpfile reg <(jq -c .entries <<<"$doc") '
    map(. as $i | ($reg[0][$i.id // ""]) as $e
      | if $e == null then $i else
          $i + {install: $e.install,
                version: ($e.version // $i.version // null),
                provenance: {method: "user", confidence: 1,
                             evidence: ["confirmed by user (\($e.origin)) on \($e.recorded_at[:10])"]}}
        end)' <<<"$items"
}
