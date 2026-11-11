#!/usr/bin/env bash
# shellcheck disable=SC2031 # T_TMP is set per test by the harness, in the test's own subshell
# shellcheck source=harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/scan/launchers.sh
source "$ROOT/lib/scan/launchers.sh"

setup() {
  export STARTKIN_OMARCHY_DIR=$T_TMP/omarchy HOME=$T_TMP/home
  mkdir -p "$STARTKIN_OMARCHY_DIR/applications" "$HOME/.local/share/applications"
  local d=$HOME/.local/share/applications
  # shipped by Omarchy: baseline
  printf '[Desktop Entry]\nName=Discord\nExec=omarchy-launch-webapp https://discord.com\n' >"$STARTKIN_OMARCHY_DIR/applications/Discord.desktop"
  cp "$STARTKIN_OMARCHY_DIR/applications/Discord.desktop" "$d/"
  # user webapp with a space in the file name and a localized name
  printf '[Desktop Entry]\nName[fr]=Cartes\nName=My Maps\nExec=omarchy-launch-webapp https://maps.example\nIcon=x\n[Desktop Action New]\nName=Other\nExec=foo\n' >"$d/My Maps.desktop"
  printf '[Desktop Entry]\nName=Htop\nExec=omarchy-launch-tui htop\nTerminal=false\n' >"$d/htop-tui.desktop"
  printf '[Desktop Entry]\nName=Tool\nExec=/opt/tool/bin/tool\n' >"$d/tool.desktop"
  printf '[Desktop Entry]\nName=Gone\nHidden=true\nExec=x\n' >"$d/gone.desktop"
  printf 'cache\n' >"$d/mimeinfo.cache"
}

test_baseline_and_non_desktop_excluded() {
  setup
  assert_json_eq '[.[].id] | sort' '["launcher:My_Maps.desktop","launcher:htop-tui.desktop","launcher:tool.desktop"]' "$(scan_launchers)"
}

test_item_shape() {
  setup
  local out; out=$(scan_launchers)
  assert_json_eq '.[] | select(.id=="launcher:My_Maps.desktop") | [.name,.kind,.category,.risk,.version,.private,.install.type,.provenance.method]' \
    '["My Maps","launcher","launcher","low",null,false,"copy","adjacent-evidence"]' "$out"
  assert_json_eq '.[] | select(.id=="launcher:My_Maps.desktop") | .install.path' "\"~/.local/share/applications/My Maps.desktop\"" "$out"
}

test_webapp_and_tui_are_tagged_in_evidence() {
  setup
  local out; out=$(scan_launchers)
  assert_json_eq '.[] | select(.id=="launcher:My_Maps.desktop") | .provenance.evidence | any(. == "omarchy webapp")' true "$out"
  assert_json_eq '.[] | select(.id=="launcher:htop-tui.desktop") | .provenance.evidence | any(. == "omarchy tui")' true "$out"
  assert_json_eq '.[] | select(.id=="launcher:tool.desktop") | .provenance.evidence | any(startswith("omarchy"))' false "$out"
}

test_output_validates() {
  setup
  jq -n --argjson items "$(scan_launchers)" '{schema_version:"1.0",machine:{hostname:"h",omarchy_version:"1",arch:"x86_64",gpu:[],form_factor:"desktop"},items:$items}' >"$T_TMP/m.json"
  assert_status 0 "$ROOT/scripts/validate-manifest" "$T_TMP/m.json"
}

test_missing_dir_is_empty() {
  setup
  rm -rf "$HOME/.local/share/applications"
  assert_eq '[]' "$(scan_launchers | jq -c .)"
}

run_tests
