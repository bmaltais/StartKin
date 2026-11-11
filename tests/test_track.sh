#!/usr/bin/env bash
# Tests for `startkin track install` (lib/track.sh). Every installer is a stub that logs its argv: no real install runs.
# shellcheck disable=SC2031,SC2016 # T_TMP is per test; stub bodies expand when they run
# shellcheck source=harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
BIN=$ROOT/bin/startkin

setup() {
  export HOME=$T_TMP/home STARTKIN_REGISTRY_FILE=$T_TMP/reg.json STARTKIN_NO_GUM=1 STARTKIN_SRC_DIR=$T_TMP/src
  export CALLS=$T_TMP/calls
  mkdir -p "$HOME"
  : >"$CALLS"
  local t
  for t in cargo go npm uv pipx make; do stub "$t" 'echo "'"$t"' $*" >>"$CALLS"'; done
  stub git 'echo "git $*" >>"$CALLS"
if [[ $1 == clone ]]; then mkdir -p "${@: -1}"; fi
if [[ $* == *rev-parse* ]]; then echo abc1234; fi'
  stub pacman 'echo "pacman $*" >>"$CALLS"'
}

calls() { cat "$CALLS"; }
reg() { jq -c ".entries[\"$1\"]" "$STARTKIN_REGISTRY_FILE"; }

test_dry_run_shows_command_and_runs_nothing() {
  setup
  assert_status 0 "$BIN" track install cargo ripgrep --dry-run
  assert_contains "$T_OUT" "cargo install --locked ripgrep"
  assert_eq "" "$(calls)"
  [[ ! -e $STARTKIN_REGISTRY_FILE ]] || t_fail "dry run recorded"
}

test_confirmation_required_without_yes() {
  setup
  assert_status 1 "$BIN" track install cargo ripgrep <<<"n"
  assert_contains "$T_OUT$T_ERR" "cargo install --locked ripgrep"
  assert_eq "" "$(calls)"
  assert_status 1 "$BIN" track install cargo ripgrep </dev/null
  assert_eq "" "$(calls)"
  assert_status 0 "$BIN" track install cargo ripgrep <<<"y"
  assert_contains "$(calls)" "cargo install --locked ripgrep"
}

test_command_shown_before_it_runs() {
  setup
  assert_status 1 "$BIN" track install cargo ripgrep <<<"n"
  assert_contains "$T_OUT$T_ERR" "$ cargo install --locked ripgrep"
}

test_cargo_records_source_version_method_date() {
  setup
  stub cargo 'echo "cargo $*" >>"$CALLS"; [[ $1 == install && $2 == --list ]] && printf "ripgrep v14.1.0:\n    rg\n"; exit 0'
  assert_status 0 "$BIN" track install cargo ripgrep --yes
  assert_json_eq '.install' '{"type":"cargo","crate":"ripgrep","locked":true}' "$(reg cargo:ripgrep)"
  assert_json_eq '.version' '"14.1.0"' "$(reg cargo:ripgrep)"
  assert_json_eq '[.origin, (.recorded_at | test("^[0-9]{4}-"))]' '["track",true]' "$(reg cargo:ripgrep)"
}

test_go_npm_uv_pipx() {
  setup
  "$BIN" track install go github.com/o/tool/cmd/tool@v1.2.3 --yes
  assert_json_eq '[.install.module, .version]' '["github.com/o/tool/cmd/tool","v1.2.3"]' "$(reg go:tool)"
  "$BIN" track install npm @scope/pkg@2.0.0 --yes
  assert_json_eq '[.install.package, .version]' '["@scope/pkg","2.0.0"]' "$(reg npm:@scope/pkg)"
  "$BIN" track install uv ruff==0.5.0 --yes
  assert_json_eq '[.install.package, .version]' '["ruff","0.5.0"]' "$(reg uv:ruff)"
  "$BIN" track install pipx black --yes
  assert_json_eq '.install' '{"type":"pipx","package":"black"}' "$(reg pipx:black)"
  assert_eq $'go install github.com/o/tool/cmd/tool@v1.2.3\nnpm install -g @scope/pkg@2.0.0\nuv tool install ruff==0.5.0\npipx install black' "$(calls)"
}

test_git_build() {
  setup
  assert_status 0 "$BIN" track install git-build https://github.com/o/thing --ref v2 --build 'make' --yes
  assert_contains "$(calls)" "git clone https://github.com/o/thing $T_TMP/src/thing"
  assert_contains "$(calls)" "checkout v2"
  assert_contains "$(calls)" "make"
  assert_json_eq '.install' '{"type":"git-build","url":"https://github.com/o/thing","ref":"v2","build":["make"]}' "$(reg track:git-build:thing)"
  assert_json_eq '.version' '"abc1234"' "$(reg track:git-build:thing)"
  assert_status 2 "$BIN" track install git-build https://github.com/o/thing --yes
  assert_contains "$T_ERR" "--build"
}

test_id_override_matches_a_scanner_item() {
  setup
  assert_status 0 "$BIN" track install git-build https://github.com/o/thing --build make --id repo-tool:thing --yes
  assert_json_eq '.install.type' '"git-build"' "$(reg repo-tool:thing)"
}

test_pacman_and_unknown_methods_refused() {
  setup
  assert_status 2 "$BIN" track install pacman ripgrep --yes
  assert_contains "$T_ERR" "pacman"
  assert_status 2 "$BIN" track install brew ripgrep --yes
  assert_eq "" "$(calls)"
}

test_failed_install_is_not_recorded() {
  setup
  stub cargo 'exit 7'
  assert_status 1 "$BIN" track install cargo ripgrep --yes
  [[ ! -e $STARTKIN_REGISTRY_FILE ]] || t_fail "failed install recorded"
}

test_bad_spec_rejected() {
  setup
  assert_status 2 "$BIN" track install cargo 'rip grep' --yes
  assert_status 2 "$BIN" track install cargo --yes
  assert_status 2 "$BIN" track install
  assert_status 2 "$BIN" track frob
  assert_eq "" "$(calls)"
}

run_tests
