#!/usr/bin/env bash
# shellcheck disable=SC2031 # T_TMP is set per test by the harness, in the test's own subshell
# shellcheck source=harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/drift.sh
source "$ROOT/lib/drift.sh"

test_compare_same() { assert_eq same "$(drift_compare_versions 3.4.1-1 3.4.1-1)"; }
test_compare_source_older() { assert_eq source-older "$(drift_compare_versions 3.4.1-1 3.10.0-1)"; }
test_compare_source_newer() { assert_eq source-newer "$(drift_compare_versions 3.10.0-1 3.4.1-1)"; }
test_compare_unknown_source() { assert_eq unknown "$(drift_compare_versions unknown 3.4.1-1)"; }
test_compare_unknown_target() { assert_eq unknown "$(drift_compare_versions 3.4.1-1 "")"; }

test_compare_machines_reads_omarchy_version() {
  local s='{"omarchy_version":"3.3.0-1","arch":"x86_64"}' t='{"omarchy_version":"3.4.0-1"}'
  assert_eq source-older "$(drift_compare_machines "$s" "$t")"
}

test_warn_silent_when_same() {
  assert_eq "" "$(drift_warn 3.4.1-1 3.4.1-1 2>&1)"
}

test_warn_on_older_source() {
  local out
  out=$(drift_warn 3.3.0-1 3.4.0-1 2>&1)
  assert_contains "$out" "3.3.0-1"
  assert_contains "$out" "3.4.0-1"
  assert_contains "$out" "Omarchy defaults"
}

test_warn_on_newer_source() {
  assert_contains "$(drift_warn 3.5.0-1 3.4.0-1 2>&1)" "newer"
}

test_warn_unknown() {
  assert_contains "$(drift_warn unknown 3.4.0-1 2>&1)" "unknown"
}

test_check_manifest_file() {
  printf '%s' '{"machine":{"omarchy_version":"3.3.0-1"}}' >"$T_TMP/m.json"
  assert_contains "$(drift_check_manifest "$T_TMP/m.json" 3.4.0-1 2>&1)" "3.3.0-1"
}

run_tests
