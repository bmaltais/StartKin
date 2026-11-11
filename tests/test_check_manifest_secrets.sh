#!/usr/bin/env bash
# shellcheck disable=SC2031 # T_TMP is set per test by the harness, in the test's own subshell
# Tests for scripts/check-manifest-secrets, plus the gate that the repo's own valid example manifests stay clean.
# shellcheck source=harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
CHECK=$ROOT/scripts/check-manifest-secrets

# manifest_with EVIDENCE_JSON_ARRAY [INSTALL_JSON] : write a one-item manifest to $T_TMP/m.json
manifest_with() {
  local install=${2:-'{"type":"pacman","package":"ripgrep"}'}
  jq -n --argjson ev "$1" --argjson inst "$install" '{
    schema_version: "1.0",
    machine: {hostname: "box", omarchy_version: "3.4.1", arch: "x86_64", gpu: [], form_factor: "desktop"},
    items: [{id: "pacman:ripgrep", name: "ripgrep", kind: "cli", category: "package", risk: "low",
             install: $inst, version: "14.0", private: false,
             provenance: {method: "package-manager", confidence: 1, evidence: $ev}}]}' >"$T_TMP/m.json"
}

test_repo_valid_examples_are_clean() {
  local f
  for f in "$ROOT"/schema/examples/valid-*.json; do
    assert_status 0 "$CHECK" "$f"
  done
}

test_clean_manifest_passes() {
  manifest_with '["pacman -Qe"]'
  assert_status 0 "$CHECK" "$T_TMP/m.json"
}

test_secret_in_evidence_fails_without_echo() {
  local tok
  tok="ghp_$(printf 'Ab1Cd2%.0s' {1..6})"
  manifest_with "[\"seen in env: $tok\"]"
  assert_status 1 "$CHECK" "$T_TMP/m.json"
  assert_contains "$T_ERR" "github-token"
  assert_contains "$T_ERR" "m.json"
  [[ $T_ERR$T_OUT != *"${tok:4:12}"* ]] || t_fail "token leaked"
}

test_secret_anywhere_fails() {
  manifest_with '[]'
  jq '.machine.hostname = "password=plainvalue"' "$T_TMP/m.json" >"$T_TMP/n.json"
  assert_status 1 "$CHECK" "$T_TMP/n.json"
  assert_contains "$T_ERR" "secret-assignment"
}

test_copy_item_of_denied_path_fails() {
  manifest_with '[]' '{"type":"copy","path":"~/.ssh/id_ed25519"}'
  assert_status 1 "$CHECK" "$T_TMP/m.json"
  assert_contains "$T_ERR" "ssh-key"
}

test_copy_item_of_ordinary_path_passes() {
  manifest_with '[]' '{"type":"copy","path":"~/.config/foo/foo.conf","dest":"~/.config/foo/foo.conf"}'
  assert_status 0 "$CHECK" "$T_TMP/m.json"
}

# Config items for files with long hashed names (Grok Bot, VS Code, sunshine state) must not trip high-entropy on
# their identifier and path fields, which carry no content.
test_identifier_and_path_fields_are_not_entropy_flagged() {
  local rel="Grok Bot/sand-client-persistence/MFRGGZDFMZTWQ2LKNNWG23TPOBYXE43UOV3HO6DZPJ2Q7K4.blob"
  jq -n --arg rel "$rel" '{schema_version: "1.0", machine: {hostname: "box"},
    items: [{id: ("config:" + ($rel | gsub(" "; "_"))), name: $rel, kind: "config", category: "config", risk: "low",
             install: {type: "copy", path: ("~/.config/" + $rel), dest: ("~/.config/" + $rel)},
             provenance: {method: "adjacent-evidence", confidence: 0.9, evidence: []}}]}' >"$T_TMP/m.json"
  assert_status 0 "$CHECK" "$T_TMP/m.json"
}

test_entropy_still_flags_content_fields() {
  manifest_with '["blob = q8Zx3Lm9Kp2Wv7Rt4Yh1Jb6Qz5Nc"]'
  assert_status 1 "$CHECK" "$T_TMP/m.json"
  assert_contains "$T_ERR" "high-entropy"
}

test_identifier_fields_still_get_pattern_checks() {
  local tok
  tok="ghp_$(printf 'Ab1Cd2%.0s' {1..6})"
  jq -n --arg t "config:$tok" '{schema_version: "1.0", machine: {hostname: "box"},
    items: [{id: $t, name: "x", kind: "config", category: "config", risk: "low",
             install: {type: "copy", path: "~/.config/x", dest: "~/.config/x"},
             provenance: {method: "adjacent-evidence", confidence: 0.9, evidence: []}}]}' >"$T_TMP/m.json"
  assert_status 1 "$CHECK" "$T_TMP/m.json"
  assert_contains "$T_ERR" "github-token"
}

test_usage_and_missing_file() {
  assert_status 2 "$CHECK"
  assert_status 2 "$CHECK" "$T_TMP/nope.json"
  assert_status 2 "$CHECK" a b
}

run_tests
