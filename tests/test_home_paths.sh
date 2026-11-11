#!/usr/bin/env bash
# The manifest and the warnings are portable: no literal home directory (and so no user name) in either.
# One fixture HOME touches every scanner and the registry overlay; the real scanners run through the dispatcher.
# shellcheck disable=SC2031,SC2016 # T_TMP is per-test; stub bodies expand when they run
# shellcheck source=harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
BIN=$ROOT/bin/startkin

# fixture_home : a HOME with something for each scanner to report
fixture_home() {
  export HOME=$T_TMP/home
  mkdir -p "$HOME/.config/hypr" "$HOME/.config/app" "$HOME/.config/omarchy/plugins/p1" \
    "$HOME/.local/share/applications" "$HOME/.local/bin" "$HOME/.config/systemd/user" "$HOME/go/bin" \
    "$T_TMP/omarchy" "$T_TMP/skel/.config/hypr" "$T_TMP/reg"
  printf 'bind = SUPER, T, exec, foot\n' >"$HOME/.config/hypr/bindings.lua"
  # a flagged file (warning names the path) and a file that mentions the home dir
  printf 'password = Zk3jQ9xLm2Vb8Nc4Rt7\n' >"$HOME/.config/app/login.conf"
  printf 'path = %s/stuff\n' "$HOME" >"$HOME/.config/app/paths.conf"
  printf '[Desktop Entry]\nName=Foo\nExec=foo\n' >"$HOME/.local/share/applications/foo.desktop"
  printf '{"name":"P1","version":"1"}\n' >"$HOME/.config/omarchy/plugins/p1/manifest.json"
  printf 'ELF fake\n' >"$HOME/.local/bin/mytool"
  chmod +x "$HOME/.local/bin/mytool"
  printf 'ELF go\n' >"$HOME/go/bin/gotool"
  chmod +x "$HOME/go/bin/gotool"
  printf '[Unit]\n' >"$HOME/.config/systemd/user/mine.service"
  jq -n --arg p "$HOME/.local/share/applications/foo.desktop" \
    '{schema_version: "1.0", entries: {"launcher:foo.desktop": {origin: "adopt", install: {type: "copy", path: $p}, version: null, recorded_at: "2026-01-01T00:00:00Z"}}}' \
    >"$T_TMP/reg/registry.json"
  stub pacman 'exit 1'
  for t in cargo uv pipx npm mise; do stub "$t" 'exit 1'; done
  stub go 'printf "\tpath\texample.com/me/gotool\n\tmod\texample.com/me/gotool\tv1.0.0\n"'
  stub systemctl '
case "$*" in
  *list-unit-files*) [[ $1 == --user ]] && echo "mine.service enabled disabled" ;;
  *"show -p FragmentPath"*) echo "'"$HOME"'/.config/systemd/user/mine.service" ;;
esac
exit 0'
  export STARTKIN_OMARCHY_DIR=$T_TMP/omarchy STARTKIN_SKEL_DIR=$T_TMP/skel STARTKIN_REGISTRY_FILE=$T_TMP/reg/registry.json
  export STARTKIN_BIN_DIRS=$HOME/.local/bin STARTKIN_APP_DIRS=$HOME/.local/share/zz STARTKIN_GIT_ROOTS=$HOME/src
  export STARTKIN_HISTORY_FILES=$HOME/.history
}

test_manifest_and_warnings_hold_no_home_directory() {
  fixture_home
  "$BIN" scan --json >"$T_TMP/out.json" 2>"$T_TMP/err"
  assert_eq 0 "$?" "scan exit status"
  assert_eq 0 "$(grep -cF -- "$HOME" "$T_TMP/out.json")" "literal home dir in the manifest"
  assert_eq 0 "$(grep -cF -- "$HOME" "$T_TMP/err")" "literal home dir in the warnings"
  assert_eq 0 "$(grep -cF -- "$(basename "$T_TMP")" "$T_TMP/out.json")" "fixture dir in the manifest"
  # every scanner contributed, so the check above is not vacuous
  local ids
  ids=$(jq -c '[.items[].id | split(":")[0]] | unique' "$T_TMP/out.json")
  for c in config launcher plugin repo-tool service go; do assert_contains "$ids" "\"$c\"" "no $c item"; done
}

test_paths_are_tilde_relative() {
  fixture_home
  "$BIN" scan --json >"$T_TMP/out.json" 2>/dev/null
  local m
  m=$(<"$T_TMP/out.json")
  assert_json_eq '.items[] | select(.id == "config:hypr/bindings.lua") | .install' \
    '{"type":"copy","path":"~/.config/hypr/bindings.lua","dest":"~/.config/hypr/bindings.lua"}' "$m"
  assert_json_eq '.items[] | select(.id == "service:user:mine.service") | .install.path' '"~/.config/systemd/user/mine.service"' "$m"
  assert_json_eq '.items[] | select(.id == "launcher:foo.desktop") | .install.path' '"~/.local/share/applications/foo.desktop"' "$m" "registry overlay"
  assert_json_eq '.items[] | select(.id == "repo-tool:mytool") | .install.path' '"~/.local/bin/mytool"' "$m"
}

run_tests
