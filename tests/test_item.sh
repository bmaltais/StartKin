#!/usr/bin/env bash
# shellcheck source=harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

test_item_json_full_shape() {
  local out
  out=$(item_json "x:1" "One" cli registry-tool low '{"type":"npm","package":"one"}' "1.2" registry 0.95 false "ev a" "ev b")
  assert_json_eq '.' '{"id":"x:1","name":"One","kind":"cli","category":"registry-tool","risk":"low","install":{"type":"npm","package":"one"},"version":"1.2","provenance":{"method":"registry","confidence":0.95,"evidence":["ev a","ev b"]},"private":false}' "$out"
}

test_item_json_empty_version_is_null_and_no_evidence_is_empty_array() {
  local out
  out=$(item_json "x:2" "Two" other app high '{"type":"copy","path":"~/a"}' "" fallback 0.3 true)
  assert_json_eq '[.version, .provenance.evidence, .private]' '[null,[],true]' "$out"
}

test_evidence_that_looks_like_a_jq_option_is_data() {
  local out
  out=$(item_json "x:3" "Three" cli app low '{"type":"unknown"}' "" fallback 0.3 false "--help names a url" "-n")
  assert_json_eq '.provenance.evidence' '["--help names a url","-n"]' "$out"
  assert_eq '["--help"]' "$(json_strings --help)"
}

test_items_join() {
  assert_eq '[]' "$(items_join)"
  assert_json_eq 'map(.a)' '[1,2]' "$(items_join '{"a":1}' '{"a":2}')"
}

test_json_strings() {
  assert_eq '["a b","c"]' "$(json_strings "a b" c)"
  assert_eq '[]' "$(json_strings)"
}

test_omarchy_dir() {
  assert_eq /usr/share/omarchy "$(unset STARTKIN_OMARCHY_DIR; omarchy_dir)"
  assert_eq /x "$(STARTKIN_OMARCHY_DIR=/x omarchy_dir)"
}

run_tests
