#!/usr/bin/env bash
# Tailscale peer discovery and manifest fetch over SSH (Tailscale SSH). See docs/engine.md "Peers".
# Without STARTKIN_REMOTE_CMD a peer is also tried at $HOME/.local/bin/startkin. STARTKIN_TAILSCALE / STARTKIN_SSH override the binaries and STARTKIN_REMOTE_CMD the remote engine command (tests).
# Exit codes: 10 tailscale unavailable, 11 unknown peer, 12 peer offline, 13 SSH auth/connection failed,
# 14 startkin not installed on the peer or failed, 15 version mismatch or invalid manifest.
# shellcheck shell=bash

PEERS_MANIFEST_SCHEMA_MAJOR=1

PEERS_ERR_KEEP=15  # lines of a failed remote's stderr shown in an error; the full text goes to a file
PEERS_HOST_OPTS=() # extra ssh options for the target chosen by peers_target
PEERS_VERBOSE=0

# peers_ssh TARGET CMD : run CMD on TARGET, non-interactive. Sets PEERS_OUT and PEERS_ERR; returns ssh's status.
peers_ssh() {
  local efile rc
  efile=$(mktemp) || return 1
  PEERS_OUT=$("${STARTKIN_SSH:-ssh}" -o BatchMode=yes -o ConnectTimeout=10 "${PEERS_HOST_OPTS[@]}" -- "$1" "$2" 2>"$efile")
  rc=$?
  PEERS_ERR=$(<"$efile")
  rm -f "$efile"
  return "$rc"
}

# peers_target HOST SHORT : choose what to ssh to; sets PEERS_HOST and PEERS_HOST_OPTS. The short host name (SHORT, empty
# when Tailscale lists it twice) is what known_hosts usually holds, so it wins when it resolves. Otherwise the MagicDNS
# name (HOST) is used with accept-new: the tailnet has already authenticated the peer, and BatchMode cannot ask.
peers_target() {
  PEERS_HOST_OPTS=()
  if [[ -n $2 ]] && getent hosts "$2" >/dev/null 2>&1; then
    PEERS_HOST=$2
  else
    PEERS_HOST=$1
    PEERS_HOST_OPTS=(-o StrictHostKeyChecking=accept-new)
  fi
}

# peers_scp_opts HOST : the option peers_target adds for the FQDN or IP (anything with a dot or colon), for scp
peers_scp_opts() { [[ $1 == *[.:]* ]] && printf '%s' '-oStrictHostKeyChecking=accept-new'; return 0; }

# peers_table : peers as a JSON array [{name, host, short, online}], Linux peers only, sorted by name. Omarchy itself is not
# detected (Tailscale does not know it): a peer counts as usable when `startkin --version` answers over SSH.
# host is the MagicDNS name without the trailing dot, else the first Tailscale IP. short is the HostName, null when
# another peer has the same one.
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
  jq -c '[(.Peer // {}) | to_entries[] | .value | select(.OS == "linux")] as $p
         | [$p[] | (.HostName // "") as $h
            | {name: .HostName, host: ((.DNSName // "" | rtrimstr(".")) | if . == "" then null else . end) // .TailscaleIPs[0],
               short: (if $h != "" and ([$p[] | select((.HostName // "" | ascii_downcase) == ($h | ascii_downcase))] | length) == 1 then $h else null end),
               online: (.Online // false)}] | sort_by(.name)' <<<"$out" || die -c 10 "tailscale status: unreadable output"
}

# peers_version TARGET : run `--version` on the peer. Sets PEERS_REMOTE_CMD to the command that worked. Without
# STARTKIN_REMOTE_CMD, a peer whose non-interactive PATH lacks startkin (exit 127) is retried at ~/.local/bin/startkin.
peers_version() {
  local rc
  PEERS_REMOTE_CMD=${STARTKIN_REMOTE_CMD:-startkin}
  peers_ssh "$1" "$PEERS_REMOTE_CMD --version"
  rc=$?
  if ((rc == 127)) && [[ -z ${STARTKIN_REMOTE_CMD:-} ]]; then
    PEERS_REMOTE_CMD="\$HOME/.local/bin/startkin" # expanded by the peer's shell
    peers_ssh "$1" "$PEERS_REMOTE_CMD --version"
    rc=$?
    ((rc == 0)) || PEERS_REMOTE_CMD=startkin
  fi
  return "$rc"
}

# peers_probe TARGET : print the peer's `startkin --version` line, or fail (no startkin, unreachable).
peers_probe() {
  peers_version "$1" && [[ $PEERS_OUT == startkin\ * ]] && printf '%s\n' "$PEERS_OUT"
}

# peers_list [--json] [--no-probe]
peers_list() {
  local json=0 probe=1 a table rows="" name host online ver short
  for a in "$@"; do
    case $a in
      --json) json=1 ;;
      --no-probe) probe=0 ;;
      *) die -c 2 "peers: unknown option: $a" ;;
    esac
  done
  table=$(peers_table) || exit $?
  while IFS=$'\t' read -r name host online short; do
    [[ -n $name ]] || continue
    ver=""
    if [[ $online == true ]] && ((probe)); then
      peers_target "$host" "$short"
      ver=$(peers_probe "$PEERS_HOST") || ver=""
    fi
    rows+=$(jq -nc --arg n "$name" --arg h "$host" --argjson o "$online" --arg v "$ver" \
      '{name: $n, host: $h, online: $o, startkin: (if $v == "" then null else $v end)}')$'\n'
  done < <(jq -r '.[] | [.name, .host, .online, (.short // "")] | @tsv' <<<"$table")
  rows=$(jq -sc '.' <<<"$rows")
  if ((json)); then printf '%s\n' "$rows"; return 0; fi
  jq -r '.[] | [.name, (if .online then "online" else "offline" end), (.startkin // "-")] | @tsv' <<<"$rows" |
    column -t -s $'\t'
}

# peers_err_text NAME : PEERS_ERR capped to its last PEERS_ERR_KEEP lines (all of it with --verbose). The full text is
# saved to $STARTKIN_STATE_DIR/peers-NAME.err (default ~/.local/state/startkin) and the note says where.
peers_err_text() {
  local n keep=$PEERS_ERR_KEEP dir file
  [[ -n $PEERS_ERR ]] || { printf 'no details'; return 0; }
  n=$(grep -c '' <<<"$PEERS_ERR")
  if ((PEERS_VERBOSE || n <= keep)); then printf '%s' "$PEERS_ERR"; return 0; fi
  dir=${STARTKIN_STATE_DIR:-$HOME/.local/state/startkin}
  file=$dir/peers-${1//[^A-Za-z0-9._-]/_}.err
  if mkdir -p "$dir" 2>/dev/null && printf '%s\n' "$PEERS_ERR" >"$file" 2>/dev/null; then
    printf '[%d more lines, full text in %s or use --verbose]\n' "$((n - keep))" "$file"
  else
    printf '[%d more lines, use --verbose for all]\n' "$((n - keep))"
  fi
  tail -n "$keep" <<<"$PEERS_ERR"
}

# peers_classify NAME RC : die with a clear message for a failed ssh run (uses PEERS_ERR)
peers_classify() {
  local err
  err=$(peers_err_text "$1")
  case $2 in
    255)
      if [[ $PEERS_ERR == *"Host key verification failed"* || $PEERS_ERR == *"REMOTE HOST IDENTIFICATION HAS CHANGED"* ]]; then
        die -c 13 "$1: SSH host key verification failed (the peer's key is not in known_hosts, or it changed). Run \`ssh ${PEERS_HOST:-$1}\` once to check and accept it: $err"
      fi
      die -c 13 "$1: SSH authentication failed or connection refused (is Tailscale SSH allowed by the tailnet policy?): $err"
      ;;
    127) die -c 14 "$1: startkin is not installed on the peer or not on its non-interactive PATH (tried startkin and \$HOME/.local/bin/startkin; set STARTKIN_REMOTE_CMD to the full path): $err" ;;
    *) die -c 14 "$1: remote startkin failed (exit $2): $err" ;;
  esac
}

# peers_fetch NAME [--verbose] : print the peer's manifest (scan --json) on stdout
peers_fetch() {
  local name="" table row host short online rc local_v remote_v manifest sv a
  for a in "$@"; do
    case $a in
      --verbose) PEERS_VERBOSE=1 ;;
      -*) die -c 2 "peers fetch: unknown option: $a" ;;
      *)
        [[ -z $name ]] || die -c 2 "usage: startkin peers fetch <peer> [--verbose]"
        name=$a
        ;;
    esac
  done
  [[ -n $name ]] || die -c 2 "usage: startkin peers fetch <peer> [--verbose]"
  table=$(peers_table) || exit $?
  row=$(jq -c --arg n "$name" 'map(select((.name | ascii_downcase) == ($n | ascii_downcase))) | first // empty' <<<"$table")
  [[ -n $row ]] || die -c 11 "unknown peer: $name (see: startkin peers)"
  host=$(jq -r .host <<<"$row")
  short=$(jq -r '.short // ""' <<<"$row")
  online=$(jq -r .online <<<"$row")
  [[ $online == true ]] || die -c 12 "$name is offline"

  peers_target "$host" "$short"
  host=$PEERS_HOST
  peers_version "$host"
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

  peers_ssh "$host" "$PEERS_REMOTE_CMD scan --json"
  rc=$?
  manifest=$PEERS_OUT
  if ((rc == 3)); then
    warn "$name: some scanners failed on the peer: $(peers_err_text "$name")"
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
