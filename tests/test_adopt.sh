#!/usr/bin/env bash
# Tests for `startkin adopt` (lib/adopt.sh). A fixture scanner stands in for the real ones; nothing touches the real HOME.
# shellcheck disable=SC2031,SC2016 # T_TMP is per test; the fixture scanner is single-quoted on purpose
# shellcheck source=harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
BIN=$ROOT/bin/startkin

# setup : a fixture scanner with an unknown, a heuristic and an exact item, and a private registry file
setup() {
  export HOME=$T_TMP/home STARTKIN_REGISTRY_FILE=$T_TMP/reg.json STARTKIN_NO_GUM=1
  mkdir -p "$T_TMP/s" "$HOME"
  cat >"$T_TMP/s/fx.sh" <<'EOF'
scan_fx() {
  cat <<'JSON'
[{"id":"repo-tool:mystery","name":"mystery","version":null,"install":{"type":"unknown","path":"/home/u/.local/bin/mystery"},"provenance":{"method":"none","confidence":0,"evidence":[]}},
 {"id":"repo-tool:guess","name":"guess","version":"1.0","install":{"type":"git-build","url":"https://github.com/o/guess"},"provenance":{"method":"name-search","confidence":0.45,"evidence":["needs confirmation"]}},
 {"id":"repo-tool:sure","name":"sure","version":null,"install":{"type":"go","module":"example.com/sure"},"provenance":{"method":"build-metadata","confidence":0.95,"evidence":[]}},
 {"id":"aur:somepkg","name":"somepkg","version":"1","install":{"type":"aur","package":"somepkg"},"provenance":{"method":"package-manager","confidence":0.8,"evidence":["pacman -Qe"]}}]
JSON
}
EOF
  export STARTKIN_SCAN_DIR=$T_TMP/s
}

test_list_json_has_only_unconfirmed() {
  setup
  assert_status 0 "$BIN" adopt --list --json
  assert_json_eq '[.[].id]' '["repo-tool:mystery","repo-tool:guess"]' "$T_OUT"
}

test_list_hides_package_manager_items_unless_all() {
  setup
  assert_status 0 "$BIN" adopt --list --json
  assert_json_eq 'map(select(.id == "aur:somepkg")) | length' '0' "$T_OUT" "AUR item at 0.8 is not noise worth asking about"
  assert_status 0 "$BIN" adopt --list --json --all
  assert_json_eq '[.[].id]' '["repo-tool:mystery","repo-tool:guess","aur:somepkg"]' "$T_OUT"
  assert_status 0 "$BIN" adopt --list --all
  assert_contains "$T_OUT" "aur:somepkg"
}

test_all_needs_list_or_walk_not_a_source() {
  setup
  assert_status 2 "$BIN" adopt repo-tool:mystery --all --confirm
}

test_list_plain_is_readable() {
  setup
  assert_status 0 "$BIN" adopt --list
  assert_contains "$T_OUT" "repo-tool:mystery"
  assert_contains "$T_OUT" "repo-tool:guess"
  [[ $T_OUT != *"repo-tool:sure"* ]] || t_fail "exact item listed"
}

test_adopted_item_leaves_the_list() {
  setup
  assert_status 0 "$BIN" adopt repo-tool:mystery --git https://github.com/o/mystery --ref v1 --build 'make' --build 'make install'
  assert_status 0 "$BIN" adopt --list --json
  assert_json_eq '[.[].id]' '["repo-tool:guess"]' "$T_OUT"
}

test_git_flags_recorded() {
  setup
  assert_status 0 "$BIN" adopt repo-tool:mystery --git https://u:p@github.com/o/mystery --ref v1 --build 'make' --build 'make install'
  e=$(jq -c '.entries["repo-tool:mystery"]' "$STARTKIN_REGISTRY_FILE")
  assert_json_eq '.install' '{"type":"git-build","url":"https://github.com/o/mystery","ref":"v1","build":["make","make install"]}' "$e"
  assert_json_eq '.origin' '"adopt"' "$e"
}

test_other_sources() {
  setup
  "$BIN" adopt repo-tool:mystery --go example.com/m/cmd
  assert_json_eq '.entries["repo-tool:mystery"].install' '{"type":"go","module":"example.com/m/cmd"}' "$(<"$STARTKIN_REGISTRY_FILE")"
  "$BIN" adopt repo-tool:mystery --cargo mycrate
  assert_json_eq '.entries["repo-tool:mystery"].install' '{"type":"cargo","crate":"mycrate"}' "$(<"$STARTKIN_REGISTRY_FILE")"
  "$BIN" adopt repo-tool:mystery --release https://example.com/m.tar.gz --sha256 abc123
  assert_json_eq '.entries["repo-tool:mystery"].install' '{"type":"release-binary","url":"https://example.com/m.tar.gz","sha256":"abc123"}' "$(<"$STARTKIN_REGISTRY_FILE")"
  "$BIN" adopt repo-tool:mystery --script https://example.com/i.sh
  assert_json_eq '.entries["repo-tool:mystery"].install' '{"type":"script","url":"https://example.com/i.sh"}' "$(<"$STARTKIN_REGISTRY_FILE")"
  "$BIN" adopt repo-tool:mystery --copy
  assert_json_eq '.entries["repo-tool:mystery"].install' '{"type":"copy","path":"/home/u/.local/bin/mystery"}' "$(<"$STARTKIN_REGISTRY_FILE")"
}

test_confirm_accepts_the_guess() {
  setup
  assert_status 0 "$BIN" adopt repo-tool:guess --confirm
  assert_json_eq '.entries["repo-tool:guess"] | [.install.url, .version]' '["https://github.com/o/guess","1.0"]' "$(<"$STARTKIN_REGISTRY_FILE")"
  assert_status 1 "$BIN" adopt repo-tool:mystery --confirm
  assert_contains "$T_ERR" "nothing to confirm"
}

test_bad_input_rejected() {
  setup
  assert_status 1 "$BIN" adopt repo-tool:nope --git https://github.com/o/r
  assert_contains "$T_ERR" "no such item"
  assert_status 2 "$BIN" adopt repo-tool:mystery
  assert_status 2 "$BIN" adopt repo-tool:mystery --git https://github.com/o/r --go x/y
  assert_status 2 "$BIN" adopt repo-tool:mystery --bogus
  assert_status 2 "$BIN" adopt repo-tool:mystery --git 'not a url'
  assert_status 2 "$BIN" adopt repo-tool:mystery --release 'ftp://x/y'
  [[ ! -e $STARTKIN_REGISTRY_FILE ]] || t_fail "registry written for bad input"
}

test_secret_in_build_refused() {
  setup
  assert_status 1 "$BIN" adopt repo-tool:mystery --git https://github.com/o/r --build "TOKEN=ghp_$(printf 'a1B2%.0s' {1..10}) make"
  assert_contains "$T_ERR" "github-token"
  [[ ! -e $STARTKIN_REGISTRY_FILE ]] || t_fail "registry written despite secret"
}

test_interactive_plain_read() {
  setup
  # mystery: git, url, ref, one build command then blank; guess: confirm; end of input stops the loop
  assert_status 0 "$BIN" adopt <<<$'git\nhttps://github.com/o/mystery\nmain\nmake\n\nconfirm\n'
  local reg
  reg=$(<"$STARTKIN_REGISTRY_FILE")
  assert_json_eq '.entries["repo-tool:mystery"].install' '{"type":"git-build","url":"https://github.com/o/mystery","ref":"main","build":["make"]}' "$reg"
  assert_json_eq '.entries["repo-tool:guess"].origin' '"adopt"' "$reg"
}

test_interactive_skip_and_numbers() {
  setup
  assert_status 0 "$BIN" adopt <<<$'skip\n3\nmycrate\n'
  local reg
  reg=$(<"$STARTKIN_REGISTRY_FILE")
  assert_json_eq '.entries | keys' '["repo-tool:guess"]' "$reg"
  assert_json_eq '.entries["repo-tool:guess"].install' '{"type":"cargo","crate":"mycrate"}' "$reg"
}

test_interactive_nothing_to_do() {
  setup
  "$BIN" adopt repo-tool:mystery --copy
  "$BIN" adopt repo-tool:guess --confirm
  assert_status 0 "$BIN" adopt </dev/null
  assert_contains "$T_OUT$T_ERR" "nothing to adopt"
}

test_interactive_uses_gum_when_available() {
  setup
  unset STARTKIN_NO_GUM
  # shellcheck source=../lib/common.sh
  source "$ROOT/lib/common.sh"
  # shellcheck source=../lib/ui.sh
  source "$ROOT/lib/ui.sh"
  ui_gum_ok() { true; }
  stub gum 'case $1 in choose) echo "git" ;; input) echo "from-gum" ;; confirm) exit 0 ;; esac'
  assert_eq "git" "$(ui_choose "pick" git go)"
  assert_eq "from-gum" "$(ui_input "url")"
  assert_status 0 ui_confirm "ok?"
}

run_tests
