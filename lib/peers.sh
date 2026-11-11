#!/usr/bin/env bash
# Tailscale peer discovery and manifest fetch over SSH (Tailscale SSH). See docs/engine.md "Peers".
# STARTKIN_TAILSCALE / STARTKIN_SSH override the binaries and STARTKIN_REMOTE_CMD the remote engine command (tests).
# Exit codes: 10 tailscale unavailable, 11 unknown peer, 12 peer offline, 13 SSH auth/connection failed,
# 14 startkin not installed on the peer or failed, 15 version mismatch or invalid manifest.
# shellcheck shell=bash

PEERS_MANIFEST_SCHEMA_MAJOR=1

# peers_ssh TARGET CMD : run CMD on TARGET, non-interactive. Sets PEERS_OUT and PEERS_ERR; returns ssh's status.
peers_ssh() {
  local efile rc
  efile=$(mktemp) || return 1
  PEERS_OUT=$("${STARTKIN_SSH:-ssh}" -o BatchMode=yes -o ConnectTimeout=10 -- "$1" "$2" 2>"$efile")
  rc=$?
  PEERS_ERR=$(<"$efile")
  rm -f "$efile"
  return "$rc"
}

# peers_table : peers as a JSON array [{name, host, online}], Linux peers only, sorted by name. Omarchy itself is not
# detected (Tailscale does not know it): a peer counts as usable when `startkin --version` answers over SSH.
# host is the MagicDNS name without the trailing dot, else the first Tailscale IP.
peers_table() {
  local ts=${STARTKIN_TAILSCALE:-tailscale} out efile
  command -v "$ts" >/dev/null 2>&1 || die -c 10 "tailscale not found: install and log in to Tailscale first"
  efile=$(mktemp)
  if ! out=$("$ts" status --json 2>"$efile"); then
    local msg
    msg=$(<"$efile")
    rm -f "$efile"
    die -c 10 "tailscale status failed: ${msg:-no output}"
  fi
  rm -f "$efile"
  jq -c '[(.Peer // {}) | to_entries[] | .value | select(.OS == "linux")
          | {name: .HostName, host: ((.DNSName // "" | rtrimstr(".")) | if . == "" then null else . end) // .TailscaleIPs[0],
             online: (.Online // false)}] | sort_by(.name)' <<<"$out" || die -c 10 "tailscale status: unreadable output"
}

# peers_probe HOST : print the peer's `startkin --version` line, or fail (no startkin, unreachable).
peers_probe() {
  peers_ssh "$1" "${STARTKIN_REMOTE_CMD:-startkin} --version" && [[ $PEERS_OUT == startkin\ * ]] && printf '%s\n' "$PEERS_OUT"
}

# peers_list [--json] [--no-probe]
peers_list() {
  local json=0 probe=1 a table rows="" name host online ver
  for a in "$@"; do
    case $a in
      --json) json=1 ;;
      --no-probe) probe=0 ;;
      *) die -c 2 "peers: unknown option: $a" ;;
    esac
  done
  table=$(peers_table) || exit $?
  while IFS=$'\t' read -r name host online; do
    [[ -n $name ]] || continue
    ver=""
    if [[ $online == true ]] && ((probe)); then ver=$(peers_probe "$host") || ver=""; fi
    rows+=$(jq -nc --arg n "$name" --arg h "$host" --argjson o "$online" --arg v "$ver" \
      '{name: $n, host: $h, online: $o, startkin: (if $v == "" then null else $v end)}')$'\n'
  done < <(jq -r '.[] | [.name, .host, .online] | @tsv' <<<"$table")
  rows=$(jq -sc '.' <<<"$rows")
  if ((json)); then printf '%s\n' "$rows"; return 0; fi
  jq -r '.[] | [.name, (if .online then "online" else "offline" end), (.startkin // "-")] | @tsv' <<<"$rows" |
    column -t -s $'\t'
}

# peers_classify NAME RC : die with a clear message for a failed ssh run (uses PEERS_ERR)
peers_classify() {
  case $2 in
    255) die -c 13 "$1: SSH authentication failed or connection refused (is Tailscale SSH allowed by the tailnet policy?): ${PEERS_ERR:-no details}" ;;
    127) die -c 14 "$1: startkin is not installed on the peer (or not on PATH): ${PEERS_ERR:-no details}" ;;
    *) die -c 14 "$1: remote startkin failed (exit $2): ${PEERS_ERR:-no details}" ;;
  esac
}

# peers_fetch NAME : print the peer's manifest (scan --json) on stdout
peers_fetch() {
  local name=${1:-} table row host online rc local_v remote_v manifest sv
  [[ -n $name ]] || die -c 2 "usage: startkin peers fetch <peer>"
  table=$(peers_table) || exit $?
  row=$(jq -c --arg n "$name" 'map(select((.name | ascii_downcase) == ($n | ascii_downcase))) | first // empty' <<<"$table")
  [[ -n $row ]] || die -c 11 "unknown peer: $name (see: startkin peers)"
  host=$(jq -r .host <<<"$row")
  online=$(jq -r .online <<<"$row")
  [[ $online == true ]] || die -c 12 "$name is offline"

  peers_ssh "$host" "${STARTKIN_REMOTE_CMD:-startkin} --version"
  rc=$?
  ((rc == 0)) || peers_classify "$name" "$rc"
  [[ $PEERS_OUT == startkin\ * ]] || die -c 14 "$name: not a startkin engine (--version printed: ${PEERS_OUT:-nothing})"
  remote_v=${PEERS_OUT#startkin }
  local_v=$(version)
  if [[ ${remote_v%%.*} != "${local_v%%.*}" ]]; then
    die -c 15 "$name: engine version mismatch (peer $remote_v, local $local_v)"
  elif [[ $remote_v != "$local_v" ]]; then
    warn "$name: engine version $remote_v differs from local $local_v"
  fi

  peers_ssh "$host" "${STARTKIN_REMOTE_CMD:-startkin} scan --json"
  rc=$?
  manifest=$PEERS_OUT
  if ((rc == 3)); then
    warn "$name: some scanners failed on the peer: ${PEERS_ERR:-no details}"
  elif ((rc != 0)); then
    peers_classify "$name" "$rc"
  fi
  sv=$(jq -r 'if type == "object" and (.items | type) == "array" then (.schema_version // "") else "" end' <<<"$manifest" 2>/dev/null)
  [[ -n $sv ]] || die -c 15 "$name: output is not a valid manifest"
  if [[ ${sv%%.*} != "$PEERS_MANIFEST_SCHEMA_MAJOR" ]]; then
    die -c 15 "$name: manifest schema $sv is not supported (this engine reads ${PEERS_MANIFEST_SCHEMA_MAJOR}.x)"
  fi
  printf '%s\n' "$manifest"
}

cmd_peers() {
  case ${1:-} in
    fetch) shift; peers_fetch "$@" ;;
    *) peers_list "$@" ;;
  esac
}
