#!/usr/bin/env bash
# shellcheck disable=SC2031 # T_TMP is set per test by the harness, in the test's own subshell
# `startkin export` (#11): live manifest to stdout or a file, and saved snapshots (docs/design.md, docs/engine.md).
# shellcheck source=harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
BIN=$ROOT/bin/startkin

# scanner NAME JSON : a one-scanner directory $T_TMP/s
scanner() { mkdir -p "$T_TMP/s"; echo "scan_$1() { echo '$2'; }" >"$T_TMP/s/$1.sh"; }
# fake_token : a GitHub-token-shaped string assembled at run time (never a literal in the repo)
fake_token() { printf 'ghp_%s' "$(printf 'Ab1Cd2%.0s' {1..6})"; }

test_export_prints_live_manifest() {
  scanner t '[{"id":"pacman:foo"}]'
  STARTKIN_SCAN_DIR=$T_TMP/s assert_status 0 "$BIN" export
  assert_json_eq '[.items[].id]' '["pacman:foo"]' "$T_OUT"
  assert_json_eq '.schema_version' '"1.0"' "$T_OUT"
}

test_export_out_writes_private_file() {
  scanner t '[{"id":"pacman:foo"}]'
  STARTKIN_SCAN_DIR=$T_TMP/s assert_status 0 "$BIN" export --out "$T_TMP/snap.json"
  assert_eq "" "$T_OUT" "nothing on stdout"
  assert_json_eq '[.items[].id]' '["pacman:foo"]' "$(<"$T_TMP/snap.json")"
  assert_eq "600" "$(stat -c %a "$T_TMP/snap.json")"
}

test_export_withholds_a_manifest_with_a_secret() {
  scanner t "[{\"id\":\"t\",\"provenance\":{\"method\":\"none\",\"confidence\":0,\"evidence\":[\"seen $(fake_token)\"]}}]"
  STARTKIN_SCAN_DIR=$T_TMP/s assert_status 4 "$BIN" export --out "$T_TMP/snap.json"
  assert_eq "" "$T_OUT"
  assert_contains "$T_ERR" "github-token"
  [[ ! -e $T_TMP/snap.json ]] || t_fail "snapshot written despite a secret"
}

test_export_out_keeps_existing_file_on_failure() {
  scanner t "[{\"id\":\"t\",\"provenance\":{\"evidence\":[\"seen $(fake_token)\"]}}]"
  echo old >"$T_TMP/snap.json"
  STARTKIN_SCAN_DIR=$T_TMP/s assert_status 4 "$BIN" export --out "$T_TMP/snap.json"
  assert_eq "old" "$(<"$T_TMP/snap.json")"
}

test_export_out_with_failed_scanner_exits_3_but_writes() {
  scanner ok '[{"id":"x"}]'
  echo 'scan_bad() { echo nope; }' >"$T_TMP/s/bad.sh"
  STARTKIN_SCAN_DIR=$T_TMP/s assert_status 3 "$BIN" export --out "$T_TMP/snap.json"
  assert_json_eq '[.items[].id]' '["x"]' "$(<"$T_TMP/snap.json")"
}

test_export_from_snapshot_reemits_it() {
  scanner t '[{"id":"pacman:foo"}]'
  STARTKIN_SCAN_DIR=$T_TMP/s "$BIN" export --out "$T_TMP/snap.json" 2>/dev/null
  # no scanners at all: the snapshot is the only source
  STARTKIN_SCAN_DIR=$T_TMP/nonexistent assert_status 0 "$BIN" export --from "$T_TMP/snap.json"
  assert_json_eq '[.items[].id]' '["pacman:foo"]' "$T_OUT"
}

test_export_from_snapshot_runs_the_secrets_gate() {
  jq -n --arg t "seen $(fake_token)" '{schema_version:"1.0",items:[{id:"t",provenance:{evidence:[$t]}}]}' >"$T_TMP/snap.json"
  assert_status 4 "$BIN" export --from "$T_TMP/snap.json"
  assert_eq "" "$T_OUT"
  assert_contains "$T_ERR" "items[0].provenance.evidence[0]"
}

test_export_from_rejects_non_manifests() {
  echo '{"hello":1}' >"$T_TMP/snap.json"
  assert_status 1 "$BIN" export --from "$T_TMP/snap.json"
  assert_contains "$T_ERR" "not a StartKin manifest"
  assert_status 1 "$BIN" export --from "$T_TMP/missing.json"
  assert_eq "" "$T_OUT"
}

test_export_rejects_bad_options() {
  assert_status 2 "$BIN" export --frobnicate
  assert_status 2 "$BIN" export --out
}

test_export_snapshot_can_be_written_from_a_snapshot() {
  jq -n '{schema_version:"1.0",items:[{id:"a"}]}' >"$T_TMP/in.json"
  assert_status 0 "$BIN" export --from "$T_TMP/in.json" --out "$T_TMP/out.json"
  assert_json_eq '[.items[].id]' '["a"]' "$(<"$T_TMP/out.json")"
}

run_tests
