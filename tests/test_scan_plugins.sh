#!/usr/bin/env bash
# shellcheck disable=SC2031 # T_TMP is set per test by the harness, in the test's own subshell
# shellcheck source=harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/scan/plugins.sh
source "$ROOT/lib/scan/plugins.sh"

# mkplugin DIR JSON : plugin folder with a manifest
mkplugin() { mkdir -p "$1" && printf '%s\n' "$2" >"$1/manifest.json"; }

# mkclone DIR URL : turn DIR into a git checkout with an origin remote and one commit
mkclone() {
  git -C "$1" init -q
  git -C "$1" remote add origin "$2"
  git -C "$1" add -A
  git -C "$1" -c user.name=t -c user.email=t@t commit -q -m init
}

# Points the scanner at fixture dirs only, never this machine's real plugins.
fixture() {
  export STARTKIN_PLUGINS_DIR=$T_TMP/plugins STARTKIN_BIN_DIR=$T_TMP/bin_home STARTKIN_SHELL_JSON=$T_TMP/shell.json
  P=$STARTKIN_PLUGINS_DIR
  mkdir -p "$P" "$STARTKIN_BIN_DIR"
}

item() { jq -c --arg id "$1" '.[] | select(.id == $id)' <<<"$2"; }

test_empty_and_missing_dir() {
  fixture
  assert_eq '[]' "$(scan_plugins)"
  rm -rf "$P"
  assert_eq '[]' "$(scan_plugins)"
}

test_git_clone() {
  fixture
  mkplugin "$P/io.x.one" '{"id":"io.x.one","name":"One","version":"1.2.3","homepage":"https://example.com/home"}'
  mkclone "$P/io.x.one" https://github.com/x/one.git
  local it
  it=$(item plugin:io.x.one "$(scan_plugins)")
  assert_json_eq '.name' '"One"' "$it"
  assert_json_eq '.kind' '"plugin"' "$it"
  assert_json_eq '.category' '"plugin"' "$it"
  assert_json_eq '.version' '"1.2.3"' "$it"
  assert_json_eq '.private' 'false' "$it"
  assert_json_eq '.install' '{"type":"plugin","plugin_id":"io.x.one","source":"https://github.com/x/one.git"}' "$it"
  assert_json_eq '.provenance.method' '"adjacent-evidence"' "$it"
  assert_json_eq '.provenance.confidence >= 0.9' 'true' "$it"
  assert_json_eq '.provenance.evidence | map(startswith("rev "))| any' 'true' "$it" "commit recorded as evidence"
}

test_credentials_stripped_from_origin() {
  fixture
  mkplugin "$P/io.x.sec" '{"id":"io.x.sec","name":"Sec","version":"1"}'
  mkclone "$P/io.x.sec" https://user:s3cret@github.com/x/sec.git
  local out
  out=$(scan_plugins)
  assert_json_eq '.[0].install.source' '"https://github.com/x/sec.git"' "$out"
  [[ $out != *s3cret* ]] || t_fail "secret leaked into output"
}

test_copy_with_homepage() {
  fixture
  mkplugin "$P/io.x.two" '{"id":"io.x.two","name":"Two","version":"0.1","homepage":"https://github.com/x/two"}'
  local it
  it=$(item plugin:io.x.two "$(scan_plugins)")
  assert_json_eq '.install' '{"type":"plugin","plugin_id":"io.x.two","source":"https://github.com/x/two"}' "$it"
  assert_json_eq '.provenance.confidence < 0.9' 'true' "$it" "homepage is weaker than origin"
}

test_copy_without_source() {
  fixture
  mkplugin "$P/io.x.three" '{"id":"io.x.three","name":"Three","version":"2"}'
  local it
  it=$(item plugin:io.x.three "$(scan_plugins)")
  assert_json_eq '.install' "{\"type\":\"copy\",\"path\":\"$P/io.x.three\"}" "$it"
}

test_symlink_to_git_checkout() {
  fixture
  mkplugin "$T_TMP/dev/repo/plugin" '{"id":"io.x.dev","name":"Dev","version":"0.0.1"}'
  mkclone "$T_TMP/dev/repo" git@github.com:x/dev.git
  ln -s "$T_TMP/dev/repo/plugin" "$P/io.x.dev"
  local it
  it=$(item plugin:io.x.dev "$(scan_plugins)")
  assert_json_eq '.install.source' '"git@github.com:x/dev.git"' "$it" "origin of the enclosing repo"
}

test_symlink_without_git() {
  fixture
  mkplugin "$T_TMP/opt/pkgplugin" '{"id":"pkg.plugin","name":"Pkg","version":"1"}'
  ln -s "$T_TMP/opt/pkgplugin" "$P/pkg-plugin"
  local it
  it=$(item plugin:pkg.plugin "$(scan_plugins)")
  assert_json_eq '.install.type' '"unknown"' "$it"
  assert_json_eq '.install.path' "\"$T_TMP/opt/pkgplugin\"" "$it"
}

test_cloned_builtin() {
  fixture
  mkplugin "$P/me.clock" '{"id":"me.clock","name":"Clock","version":"1","omarchy":{"clonedFrom":"omarchy.clock"}}'
  local it
  it=$(item plugin:me.clock "$(scan_plugins)")
  assert_json_eq '.install.type' '"unknown"' "$it"
  assert_contains "$(jq -r .install.hint <<<"$it")" "omarchy.clock"
}

test_missing_version_and_name() {
  fixture
  mkplugin "$P/bare" '{"id":"bare.id"}'
  local it
  it=$(item plugin:bare.id "$(scan_plugins)")
  assert_json_eq '.version' 'null' "$it"
  assert_json_eq '.name' '"bare.id"' "$it"
}

test_skips_dot_dirs_and_bad_manifests() {
  fixture
  mkplugin "$P/.add.tmp.9" '{"id":"io.x.staged","name":"S","version":"1"}'
  mkplugin "$P/.old.bak.1" '{"id":"io.x.bak","name":"B","version":"1"}'
  mkdir -p "$P/nomanifest"
  mkdir -p "$P/broken" && echo '{not json' >"$P/broken/manifest.json"
  mkplugin "$P/good" '{"id":"io.x.good","name":"G","version":"1"}'
  assert_status 0 scan_plugins
  assert_json_eq 'map(.id)' '["plugin:io.x.good"]' "$T_OUT"
  assert_contains "$T_ERR" "broken"
}

test_enabled_state_from_shell_json() {
  fixture
  mkplugin "$P/a" '{"id":"io.x.a","name":"A","version":"1"}'
  mkplugin "$P/b" '{"id":"io.x.b","name":"B","version":"1"}'
  mkplugin "$P/c" '{"id":"io.x.c","name":"C","version":"1"}'
  echo '{"plugins":[{"id":"io.x.a","pins":["x"]}],"bar":{"id":null,"layout":{"left":[{"id":"io.x.b"}],"right":["omarchy.tray"]}}}' >"$STARTKIN_SHELL_JSON"
  local out
  out=$(scan_plugins)
  assert_json_eq '.[] | select(.id=="plugin:io.x.a") | .provenance.evidence | index("enabled in shell.json") != null' 'true' "$out"
  assert_json_eq '.[] | select(.id=="plugin:io.x.b") | .provenance.evidence | index("enabled in shell.json") != null' 'true' "$out" "bar layout counts"
  assert_json_eq '.[] | select(.id=="plugin:io.x.c") | .provenance.evidence | index("disabled in shell.json") != null' 'true' "$out"
  [[ $out != *pins* ]] || t_fail "shell.json settings must not leak"
}

test_no_shell_json_adds_no_state() {
  fixture
  mkplugin "$P/a" '{"id":"io.x.a","name":"A","version":"1"}'
  assert_json_eq '.[0].provenance.evidence | map(test("shell.json")) | any' 'false' "$(scan_plugins)"
}

test_bin_links_exposed_in_evidence() {
  fixture
  mkplugin "$P/io.x.tool" '{"id":"io.x.tool","name":"Tool","version":"1"}'
  mkdir -p "$P/io.x.tool/bin" && touch "$P/io.x.tool/bin/tool"
  ln -s "$P/io.x.tool/bin/tool" "$STARTKIN_BIN_DIR/tool"
  ln -s /usr/bin/true "$STARTKIN_BIN_DIR/unrelated"
  local it
  it=$(item plugin:io.x.tool "$(scan_plugins)")
  assert_json_eq '.provenance.evidence | index("bin link: tool") != null' 'true' "$it"
  assert_json_eq '.provenance.evidence | map(test("unrelated")) | any' 'false' "$it"
}

test_output_validates_against_schema() {
  fixture
  mkplugin "$P/io.x.one" '{"id":"io.x.one","name":"One","version":"1"}'
  mkclone "$P/io.x.one" https://github.com/x/one.git
  mkplugin "$P/io.x.two" '{"id":"io.x.two","name":"Two","version":"1","homepage":"https://github.com/x/two"}'
  mkplugin "$P/io.x.three" '{"id":"io.x.three","name":"Three"}'
  mkplugin "$T_TMP/opt/p" '{"id":"p.p","name":"P","version":"1"}'
  ln -s "$T_TMP/opt/p" "$P/p-p"
  echo '{"plugins":[{"id":"io.x.one"}]}' >"$STARTKIN_SHELL_JSON"
  jq -n --argjson items "$(scan_plugins)" \
    '{schema_version:"1.0", machine:{hostname:"h", omarchy_version:"1", arch:"x86_64", gpu:[], form_factor:"other"}, items:$items}' \
    >"$T_TMP/m.json"
  "$ROOT/scripts/validate-manifest" "$T_TMP/m.json" >"$T_TMP/v.out" 2>&1
  case $? in
    0) ;;
    2) printf '    (validator unavailable, skipped)\n' >&2 ;;
    *) t_fail "manifest does not validate: $(<"$T_TMP/v.out")" ;;
  esac
}

run_tests
