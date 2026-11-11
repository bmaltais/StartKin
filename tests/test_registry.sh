#!/usr/bin/env bash
# Tests for lib/registry.sh: the user-confirmed provenance file and the scan overlay. Fixture HOME only.
# shellcheck disable=SC2031 # T_TMP is set per test by the harness
# shellcheck source=harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/registry.sh
source "$ROOT/lib/registry.sh"

setup() {
  export HOME=$T_TMP/home STARTKIN_REGISTRY_FILE=$T_TMP/reg/registry.json
  unset XDG_CONFIG_HOME
}

GIT='{"type":"git-build","url":"https://github.com/o/r"}'

test_default_path_and_override() {
  setup
  assert_eq "$T_TMP/reg/registry.json" "$(registry_file)"
  unset STARTKIN_REGISTRY_FILE
  assert_eq "$HOME/.config/startkin/registry.json" "$(registry_file)"
}

test_missing_file_is_empty() {
  setup
  assert_json_eq '.entries' '{}' "$(registry_read)"
}

test_put_get_roundtrip() {
  setup
  registry_put "repo-tool:foo" "$GIT" "1.2" adopt
  assert_json_eq '.install.url' '"https://github.com/o/r"' "$(registry_get repo-tool:foo)"
  assert_json_eq '.version' '"1.2"' "$(registry_get repo-tool:foo)"
  assert_json_eq '.origin' '"adopt"' "$(registry_get repo-tool:foo)"
  assert_json_eq '.recorded_at | test("^[0-9]{4}-")' 'true' "$(registry_get repo-tool:foo)"
  assert_json_eq '.schema_version' '"1.0"' "$(registry_read)"
  registry_put "repo-tool:foo" "$GIT" "" adopt
  assert_json_eq '.version' 'null' "$(registry_get repo-tool:foo)" "empty version is null; put replaces"
  assert_status 1 registry_get nope
}

test_put_rejects_secrets() {
  setup
  local tok
  tok="ghp_$(printf 'a1B2%.0s' {1..10})"
  assert_status 1 registry_put x "{\"type\":\"git-build\",\"url\":\"https://x/o/r\",\"build\":[\"curl -H $tok\"]}" "" adopt
  assert_contains "$T_ERR" "github-token"
  [[ $T_ERR != *"$tok"* ]] || t_fail "secret leaked into the message"
  [[ ! -e $STARTKIN_REGISTRY_FILE ]] || t_fail "registry written despite secret"
}

test_put_rejects_denied_copy_path() {
  setup
  assert_status 1 registry_put x '{"type":"copy","path":"/home/u/.ssh/id_ed25519"}' "" adopt
  assert_contains "$T_ERR" "ssh-key"
}

test_put_strips_url_credentials() {
  setup
  registry_put x '{"type":"git-build","url":"https://user:pw@github.com/o/r"}' "" adopt
  assert_json_eq '.install.url' '"https://github.com/o/r"' "$(registry_get x)"
}

test_corrupt_file_is_not_overwritten() {
  setup
  mkdir -p "$T_TMP/reg"
  echo 'not json' >"$STARTKIN_REGISTRY_FILE"
  assert_status 1 registry_put x "$GIT" "" adopt
  assert_eq 'not json' "$(<"$STARTKIN_REGISTRY_FILE")"
}

test_overlay_replaces_provenance() {
  setup
  registry_put "repo-tool:foo" "$GIT" "3.0" adopt
  local items='[{"id":"repo-tool:foo","version":null,"install":{"type":"unknown","path":"/x"},"provenance":{"method":"none","confidence":0,"evidence":["found"]}},{"id":"other","provenance":{"method":"none","confidence":0,"evidence":[]}}]'
  local out
  out=$(registry_overlay <<<"$items")
  assert_json_eq '.[0].install.type' '"git-build"' "$out"
  assert_json_eq '.[0].version' '"3.0"' "$out"
  assert_json_eq '.[0].provenance.method' '"user"' "$out"
  assert_json_eq '.[0].provenance.confidence' '1' "$out"
  assert_json_eq '.[1].provenance.method' '"none"' "$out" "unlisted items untouched"
}

test_overlay_keeps_scanned_version_when_entry_has_none() {
  setup
  registry_put "a" "$GIT" "" adopt
  local out
  out=$(registry_overlay <<<'[{"id":"a","version":"9","provenance":{"method":"none","confidence":0,"evidence":[]}}]')
  assert_json_eq '.[0].version' '"9"' "$out"
}

test_overlay_without_registry_is_identity() {
  setup
  assert_eq '[{"id":"a"}]' "$(registry_overlay <<<'[{"id":"a"}]')"
}

test_overlay_with_corrupt_registry_passes_through() {
  setup
  mkdir -p "$T_TMP/reg"
  echo 'not json' >"$STARTKIN_REGISTRY_FILE"
  assert_status 0 registry_overlay <<<'[{"id":"a"}]'
  assert_eq '[{"id":"a"}]' "$T_OUT"
  assert_contains "$T_ERR" "registry"
}

run_tests
