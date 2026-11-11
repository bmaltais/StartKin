#!/usr/bin/env bash
# peers: Tailscale peer discovery and manifest fetch, with fake `tailscale` and `ssh` on PATH (no network).
# shellcheck disable=SC2031 # T_TMP/T_BIN are set per test by the harness, in the test's own subshell
# shellcheck source=harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
BIN=$ROOT/bin/startkin

STATUS='{"Self":{"HostName":"me","DNSName":"me.tail.ts.net.","Online":true,"OS":"linux"},"Peer":{
 "k1":{"HostName":"box","DNSName":"box.tail.ts.net.","Online":true,"OS":"linux","TailscaleIPs":["100.1.1.1"]},
 "k2":{"HostName":"off","DNSName":"off.tail.ts.net.","Online":false,"OS":"linux","TailscaleIPs":["100.1.1.2"]},
 "k3":{"HostName":"phone","DNSName":"phone.tail.ts.net.","Online":true,"OS":"android","TailscaleIPs":["100.1.1.3"]},
 "k4":{"HostName":"bare","DNSName":"bare.tail.ts.net.","Online":true,"OS":"linux","TailscaleIPs":["100.1.1.4"]},
 "k5":{"HostName":"other","DNSName":"other.tail.ts.net.","Online":true,"OS":"linux","TailscaleIPs":["100.1.1.5"]}}}'

# fake_tailscale : `tailscale status --json` prints $STATUS
fake_tailscale() {
  printf '%s' "$STATUS" >"$T_TMP/status.json"
  stub tailscale "[[ \$1 == status && \$2 == --json ]] || exit 64; cat '$T_TMP/status.json'"
}

# fake_ssh : answers by target (second to last arg) and remote command (last arg).
#   box: startkin (BOX_VERSION, default the local version) with manifest BOX_MANIFEST;
#   bare: no startkin installed; any other: auth failure.
fake_ssh() {
  local v manifest
  v=$(<"$ROOT/VERSION")
  v=${v//[$'\n ']/}
  manifest='{"schema_version":"1.0","generated_at":"2026-01-01T00:00:00Z","machine":{"hostname":"box"},"items":[{"id":"pkg:x"}]}'
  printf '%s' "${BOX_MANIFEST:-$manifest}" >"$T_TMP/manifest.json"
  stub ssh "
t=\${@: -2:1}; c=\${@: -1}
echo \"\$t \$c\" >>'$T_TMP/ssh.log'
case \$t in
  box.tail.ts.net)
    case \$c in
      *--version*) echo 'startkin ${BOX_VERSION:-$v}' ;;
      *scan*) cat '$T_TMP/manifest.json' ;;
    esac ;;
  bare.tail.ts.net) echo 'bash: line 1: startkin: command not found' >&2; exit 127 ;;
  *) echo 'tailscale: access denied' >&2; exit 255 ;;
esac"
}

test_list_json_only_linux_peers_with_state() {
  fake_tailscale; fake_ssh
  assert_status 0 "$BIN" peers --json
  assert_json_eq '[.[].name]' '["bare","box","off","other"]' "$T_OUT" "android peer and self excluded"
  assert_json_eq '.[] | select(.name=="off") | .online' 'false' "$T_OUT"
  assert_json_eq ".[] | select(.name==\"box\") | .startkin == \"startkin $(<"$ROOT/VERSION")\"" 'true' "$T_OUT"
  assert_json_eq '.[] | select(.name=="bare") | .startkin' 'null' "$T_OUT" "no startkin on peer"
  assert_json_eq '.[] | select(.name=="off") | .startkin' 'null' "$T_OUT"
  assert_contains "$(<"$T_TMP/ssh.log")" "box.tail.ts.net"
  [[ $(<"$T_TMP/ssh.log") != *off.tail.ts.net* ]] || t_fail "offline peer must not be contacted"
}

test_list_text() {
  fake_tailscale; fake_ssh
  assert_status 0 "$BIN" peers
  assert_contains "$T_OUT" "box"
  assert_contains "$T_OUT" "offline"
}

test_list_no_probe_skips_ssh() {
  fake_tailscale; fake_ssh
  assert_status 0 "$BIN" peers --json --no-probe
  [[ ! -e $T_TMP/ssh.log ]] || t_fail "ssh was called"
  assert_json_eq '.[] | select(.name=="box") | .startkin' 'null' "$T_OUT"
}

test_list_tailscale_missing() {
  assert_status 10 env PATH="$T_BIN:/usr/bin:/bin" STARTKIN_TAILSCALE=nonexistent-ts "$BIN" peers
  assert_contains "$T_ERR" "tailscale"
}

test_list_tailscale_stopped() {
  stub tailscale 'echo "Tailscale is stopped." >&2; exit 1'
  assert_status 10 "$BIN" peers
  assert_contains "$T_ERR" "Tailscale is stopped"
}

test_fetch_prints_manifest() {
  fake_tailscale; fake_ssh
  assert_status 0 "$BIN" peers fetch box
  assert_json_eq '.items[0].id' '"pkg:x"' "$T_OUT"
}

test_fetch_unknown_peer() {
  fake_tailscale; fake_ssh
  assert_status 11 "$BIN" peers fetch nope
  assert_contains "$T_ERR" "unknown peer: nope"
}

test_fetch_offline_peer() {
  fake_tailscale; fake_ssh
  assert_status 12 "$BIN" peers fetch off
  assert_contains "$T_ERR" "offline"
  [[ ! -e $T_TMP/ssh.log ]] || t_fail "ssh was called for an offline peer"
}

test_fetch_auth_failure() {
  fake_tailscale; fake_ssh
  assert_status 13 "$BIN" peers fetch other
  assert_contains "$T_ERR" "authentication failed"
  assert_contains "$T_ERR" "access denied"
}

test_fetch_startkin_missing() {
  fake_tailscale; fake_ssh
  assert_status 14 "$BIN" peers fetch bare
  assert_contains "$T_ERR" "not installed"
}

test_fetch_engine_major_mismatch() {
  fake_tailscale; BOX_VERSION=9.0.0 fake_ssh
  assert_status 15 "$BIN" peers fetch box
  assert_contains "$T_ERR" "version mismatch"
}

test_fetch_minor_difference_warns() {
  fake_tailscale; BOX_VERSION=0.99.0 fake_ssh
  assert_status 0 "$BIN" peers fetch box
  assert_contains "$T_ERR" "differs"
  assert_json_eq '.items | length' '1' "$T_OUT"
}

test_fetch_schema_major_mismatch() {
  fake_tailscale; BOX_MANIFEST='{"schema_version":"2.0","items":[]}' fake_ssh
  assert_status 15 "$BIN" peers fetch box
  assert_contains "$T_ERR" "schema"
}

test_fetch_invalid_manifest() {
  fake_tailscale; BOX_MANIFEST='not json' fake_ssh
  assert_status 15 "$BIN" peers fetch box
  assert_contains "$T_ERR" "not a valid manifest"
}

test_fetch_requires_host() {
  assert_status 2 "$BIN" peers fetch
  assert_contains "$T_ERR" "usage"
}

run_tests
