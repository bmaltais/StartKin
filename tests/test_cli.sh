#!/usr/bin/env bash
# shellcheck disable=SC2031 # T_TMP is set per test by the harness, in the test's own subshell
# shellcheck source=harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
BIN=$ROOT/bin/startkin

test_version() {
  assert_status 0 "$BIN" --version
  assert_eq "startkin $(<"$ROOT/VERSION")" "$T_OUT"
}

test_help_lists_subcommands() {
  assert_status 0 "$BIN" --help
  for c in scan export apply peers; do assert_contains "$T_OUT" "$c"; done
}

test_no_args_prints_usage_exit_2() {
  assert_status 2 "$BIN"
  assert_contains "$T_ERR$T_OUT" "Usage"
}

test_unknown_command() {
  assert_status 2 "$BIN" frobnicate
  assert_contains "$T_ERR" "unknown command"
}

test_stubs_not_implemented() {
  local c
  for c in export apply peers scan; do
    assert_status 2 "$BIN" "$c"
    assert_contains "$T_ERR" "not implemented"
  done
}

test_scan_json_skeleton() {
  mkdir "$T_TMP/empty"
  STARTKIN_SCAN_DIR=$T_TMP/empty assert_status 0 "$BIN" scan --json
  assert_json_eq '.items' '[]' "$T_OUT"
  assert_json_eq '.schema_version' '"1.0"' "$T_OUT"
  assert_json_eq '.machine | keys' '["arch","form_factor","gpu","hostname","omarchy_version"]' "$T_OUT"
  assert_json_eq '.machine.gpu | type' '"array"' "$T_OUT"
  assert_json_eq '.generated_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")' 'true' "$T_OUT"
}

test_scan_discovers_plugins() {
  mkdir "$T_TMP/s"
  echo "scan_alpha() { echo '[{\"id\":\"a1\"},{\"id\":\"a2\"}]'; }" >"$T_TMP/s/alpha.sh"
  echo "scan_beta_two() { echo '[{\"id\":\"b1\"}]'; }" >"$T_TMP/s/beta-two.sh"
  STARTKIN_SCAN_DIR=$T_TMP/s assert_status 0 "$BIN" scan --json
  assert_json_eq '[.items[].id]' '["a1","a2","b1"]' "$T_OUT"
}

test_scan_failing_plugin_reported() {
  mkdir "$T_TMP/s"
  echo 'scan_bad() { echo "not json"; }' >"$T_TMP/s/bad.sh"
  echo "scan_ok() { echo '[{\"id\":\"x\"}]'; }" >"$T_TMP/s/ok.sh"
  STARTKIN_SCAN_DIR=$T_TMP/s assert_status 3 "$BIN" scan --json
  assert_contains "$T_ERR" "bad"
  assert_json_eq '[.items[].id]' '["x"]' "$T_OUT" "good scanner still emitted"
}

test_scan_missing_function() {
  mkdir "$T_TMP/s"
  echo '# nothing here' >"$T_TMP/s/empty.sh"
  STARTKIN_SCAN_DIR=$T_TMP/s assert_status 3 "$BIN" scan --json
  assert_contains "$T_ERR" "scan_empty"
}


test_scan_overlays_registry() {
  mkdir "$T_TMP/s"
  echo "scan_t() { echo '[{\"id\":\"repo-tool:foo\",\"install\":{\"type\":\"unknown\",\"path\":\"/x\"},\"provenance\":{\"method\":\"none\",\"confidence\":0,\"evidence\":[]}},{\"id\":\"repo-tool:bar\",\"provenance\":{\"method\":\"none\",\"confidence\":0,\"evidence\":[]}}]'; }" >"$T_TMP/s/t.sh"
  export STARTKIN_REGISTRY_FILE=$T_TMP/reg.json
  STARTKIN_SCAN_DIR=$T_TMP/s assert_status 0 "$BIN" adopt repo-tool:foo --git https://github.com/o/r
  STARTKIN_SCAN_DIR=$T_TMP/s assert_status 0 "$BIN" scan --json
  assert_json_eq '.items[0].provenance | [.method, .confidence]' '["user",1]' "$T_OUT"
  assert_json_eq '.items[0].install.url' '"https://github.com/o/r"' "$T_OUT"
  assert_json_eq '.items[1].provenance.method' '"none"' "$T_OUT"
}

# 1500 items of ~800 bytes: well over 1 MB, far past the per-argument and total argv limits.
test_scan_json_survives_huge_item_list() {
  mkdir "$T_TMP/s"
  # shellcheck disable=SC2016 # the scanner body expands when it runs
  echo 'scan_big() { jq -nc "[range(1500) | {id: (\"big:\" + tostring), name: (\"x\" * 800)}]"; }' >"$T_TMP/s/big.sh"
  # Not assert_status: it would put >1 MB into $T_OUT, which is exported and would break every later exec.
  STARTKIN_SCAN_DIR=$T_TMP/s "$BIN" scan --json >"$T_TMP/out.json" 2>"$T_TMP/err"
  assert_eq 0 "$?" "exit status"
  assert_eq 1500 "$(jq '.items | length' "$T_TMP/out.json")"
  (($(stat -c %s "$T_TMP/out.json") > 1000000)) || t_fail "output under 1 MB"
}

test_scan_json_fails_loudly_when_assembly_fails() {
  mkdir "$T_TMP/s"
  echo "scan_t() { echo '[{\"id\":\"t\"}]'; }" >"$T_TMP/s/t.sh"
  local real
  real=$(command -v jq)
  # a jq that dies only while building the final manifest
  # shellcheck disable=SC2016 # the stub body expands when it runs
  stub jq 'for a in "$@"; do [[ $a == *schema_version* ]] && { echo "jq: boom" >&2; exit 5; }; done; exec '"$real"' "$@"'
  STARTKIN_SCAN_DIR=$T_TMP/s assert_status 1 "$BIN" scan --json
  assert_eq "" "$T_OUT"
}

test_scan_json_validates_against_schema() {
  mkdir "$T_TMP/empty"
  STARTKIN_SCAN_DIR=$T_TMP/empty "$BIN" scan --json >"$T_TMP/m.json"
  assert_status 0 "$ROOT/scripts/validate-manifest" "$T_TMP/m.json"
}

run_tests
