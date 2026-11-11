#!/usr/bin/env bash
# shellcheck disable=SC2031 # T_TMP is set per test by the harness, in the test's own subshell
# shellcheck source=harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
# shellcheck source=../lib/plugin_links.sh
source "$ROOT/lib/plugin_links.sh"

# Fixture: plugins/{alpha (real dir), beta (symlink to a checkout, manifest id differs), .add.tmp.1}, bin dir with assorted links.
fixture() {
  P=$T_TMP/plugins B=$T_TMP/bin_home CK=$T_TMP/checkout
  mkdir -p "$P/alpha/bin" "$CK/bin" "$B" "$T_TMP/elsewhere" "$P/.add.tmp.1/bin"
  echo '{"id":"io.x.alpha"}' >"$P/alpha/manifest.json"
  echo '{"id":"beta.id"}' >"$CK/manifest.json"
  ln -s "$CK" "$P/beta"
  touch "$P/alpha/bin/alpha-tool" "$CK/bin/beta-tool" "$T_TMP/elsewhere/other" "$B/regular"
  echo '{"id":"io.x.staged"}' >"$P/.add.tmp.1/manifest.json"
  ln -s "$P/alpha/bin/alpha-tool" "$B/alpha-tool"
  ln -s alpha-tool "$B/alpha-alias"
  ln -s "$CK/bin/beta-tool" "$B/beta-tool"
  ln -s "$T_TMP/elsewhere/other" "$B/other"
  ln -s "$P/alpha/bin/gone" "$B/dangling"
}

test_links_into_plugins() {
  fixture
  local j
  j=$(plugin_bin_links "$P" "$B")
  assert_json_eq 'map(.name) | sort' '["alpha-alias","alpha-tool","beta-tool","dangling"]' "$j"
  assert_json_eq 'map(select(.name=="alpha-tool"))[0].plugin_id' '"io.x.alpha"' "$j"
  assert_json_eq 'map(select(.name=="alpha-alias"))[0].plugin_id' '"io.x.alpha"' "$j" "chained relative link"
  assert_json_eq 'map(select(.name=="beta-tool"))[0].plugin_id' '"beta.id"' "$j" "symlinked plugin dir, manifest id"
  assert_json_eq 'map(select(.name=="alpha-tool"))[0].path' "\"$B/alpha-tool\"" "$j"
  assert_json_eq 'map(select(.name=="alpha-tool"))[0].target' "\"$P/alpha/bin/alpha-tool\"" "$j"
}

test_ignores_dot_dirs() {
  fixture
  ln -s "$P/.add.tmp.1/bin" "$B/staged"
  assert_json_eq 'map(.name) | index("staged")' 'null' "$(plugin_bin_links "$P" "$B")"
}

test_missing_dirs_give_empty_array() {
  assert_eq '[]' "$(plugin_bin_links "$T_TMP/nope" "$T_TMP/nope2")"
  fixture
  assert_eq '[]' "$(plugin_bin_links "$T_TMP/nope" "$B")"
  assert_eq '[]' "$(plugin_bin_links "$P" "$T_TMP/nope")"
}

test_default_dirs_from_env() {
  fixture
  assert_json_eq 'length' '4' "$(STARTKIN_PLUGINS_DIR=$P STARTKIN_BIN_DIR=$B plugin_bin_links)"
}

run_tests
