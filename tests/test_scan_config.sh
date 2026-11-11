#!/usr/bin/env bash
# shellcheck disable=SC2031 # T_TMP is set per test by the harness, in the test's own subshell
# shellcheck source=harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/secrets.sh
source "$ROOT/lib/secrets.sh"
# shellcheck source=../lib/scan/config.sh
source "$ROOT/lib/scan/config.sh"

# put FILE CONTENT : create FILE (and parents) holding CONTENT
put() { mkdir -p "$(dirname "$1")" && printf '%s\n' "$2" >"$1"; }

# Fixture: fake skel, fake omarchy dir and a fake home. Never the real machine.
setup() {
  export HOME=$T_TMP/home STARTKIN_SKEL_DIR=$T_TMP/skel STARTKIN_OMARCHY_DIR=$T_TMP/omarchy
  S=$STARTKIN_SKEL_DIR/.config H=$HOME/.config
  mkdir -p "$H"
  put "$S/hypr/looknfeel.lua" 'gaps = 5'
  put "$S/hypr/input.lua" 'kb_layout = us'
  put "$S/hypr/hyprland.lua" 'require("input")'
  put "$S/alacritty/alacritty.toml" 'font = 9'
  put "$S/omarchy/branding/about.txt" 'about'
  put "$STARTKIN_OMARCHY_DIR/config/btop/btop.conf" 'theme = x'
  put "$STARTKIN_OMARCHY_DIR/themes/tokyo/colors.toml" 'bg = 1'
  # user state: identical files, one changed, one added
  cp -r "$S/." "$H/"
  cp -r "$STARTKIN_OMARCHY_DIR/config/btop" "$H/"
  put "$H/hypr/looknfeel.lua" 'gaps = 12'
  put "$H/hypr/extra.lua" 'extra'
}

items() { scan_config 2>/dev/null; }
ids() { items | jq -c '[.[].id] | sort'; }

test_unchanged_files_are_excluded_changed_and_added_reported() {
  setup
  assert_eq '["config:hypr/extra.lua","config:hypr/looknfeel.lua"]' "$(ids)"
  assert_json_eq '.[] | select(.id=="config:hypr/looknfeel.lua") | .provenance.evidence | index("status: modified") != null' true "$(items)"
  assert_json_eq '.[] | select(.id=="config:hypr/extra.lua") | .provenance.evidence | index("status: added") != null' true "$(items)"
}

test_item_shape_and_category_tag() {
  setup
  assert_json_eq '.[] | select(.id=="config:hypr/looknfeel.lua") | [.name,.kind,.category,.risk,.private,.version,.install.type,.install.path,.install.dest,.provenance.method,(.provenance.evidence|index("category: hypr") != null)]' \
    "[\"hypr/looknfeel.lua\",\"config\",\"config\",\"low\",false,null,\"copy\",\"$H/hypr/looknfeel.lua\",\"~/.config/hypr/looknfeel.lua\",\"adjacent-evidence\",true]" "$(items)"
}

test_matching_either_baseline_counts_as_shipped() {
  setup
  put "$H/btop/btop.conf" 'theme = changed'
  assert_json_eq '[.[].id] | index("config:btop/btop.conf") != null' true "$(items)"
  put "$H/btop/btop.conf" 'theme = x'
  assert_json_eq '[.[].id] | index("config:btop/btop.conf")' null "$(items)"
}

test_added_directory_is_one_item() {
  setup
  put "$H/zathura/zathurarc" 'set font x'
  put "$H/zathura/extra/more" 'x'
  assert_json_eq '[.[] | select(.id=="config:zathura")] | length' 1 "$(items)"
  assert_json_eq '[.[].id | select(startswith("config:zathura"))]' '["config:zathura"]' "$(items)"
  assert_json_eq '.[] | select(.id=="config:zathura") | [.install.path,.private,.risk]' "[\"$H/zathura\",false,\"low\"]" "$(items)"
}

test_user_theme_is_one_item_shipped_theme_is_not() {
  setup
  put "$H/omarchy/themes/tokyo/colors.toml" 'bg = 1'
  put "$H/omarchy/themes/mine/colors.toml" 'bg = 2'
  put "$H/omarchy/themes/mine/backgrounds/a.png" 'png'
  put "$H/omarchy/themes/tokyo2/colors.toml" 'bg = 3'
  assert_eq '["config:hypr/extra.lua","config:hypr/looknfeel.lua","config:omarchy/themes/mine","config:omarchy/themes/tokyo2"]' "$(ids)"
  assert_json_eq '.[] | select(.id=="config:omarchy/themes/mine") | .provenance.evidence | index("category: themes") != null' true "$(items)"
  put "$H/omarchy/themes/tokyo/colors.toml" 'bg = 99'
  assert_json_eq '.[] | select(.id=="config:omarchy/themes/tokyo") | .provenance.evidence | index("status: modified") != null' true "$(items)"
}

test_categories() {
  assert_eq hypr "$(config_category hypr/bindings.lua)"
  assert_eq terminal "$(config_category kitty/kitty.conf)"
  assert_eq editor "$(config_category nvim/init.lua)"
  assert_eq themes "$(config_category omarchy/themes/x)"
  assert_eq omarchy "$(config_category omarchy/hooks/a)"
  assert_eq app "$(config_category whatever/x)"
}

test_denied_paths_are_not_emitted_and_dir_is_split() {
  setup
  put "$H/gh/config.yml" 'git_protocol: ssh'
  put "$H/gh/hosts.yml" 'oauth: x'
  put "$H/rclone/rclone.conf" 'pass = x'
  put "$H/chromium/Default/Preferences" '{}'
  put "$H/BraveSoftware/Brave/Local State" '{}'
  local out; out=$(items)
  assert_json_eq '[.[].id | select(startswith("config:gh"))]' '["config:gh/config.yml"]' "$out"
  assert_json_eq '[.[].id | select(test("rclone|chromium|Brave"))]' '[]' "$out"
  assert_eq 0 "$(jq -r '[.[].install.path | select(test("hosts.yml|rclone.conf"))] | length' <<<"$out")"
}

test_secret_content_marks_private_and_never_leaks() {
  setup
  local tok; tok="ghp_$(printf 'a1B2%.0s' {1..10})"
  put "$H/hypr/secretive.lua" "api_token = \"$tok\""
  local out; out=$(items)
  assert_json_eq '.[] | select(.id=="config:hypr/secretive.lua") | [.private,.risk,(.provenance.evidence | any(startswith("possible secret: github-token")))]' '[true,"high",true]' "$out"
  case $out in *"$tok"*) t_fail "secret leaked into the manifest" ;; esac
}

test_added_dir_with_secret_file_is_split_and_flagged() {
  setup
  put "$H/tool/ok.conf" 'a = 1'
  put "$H/tool/bad.conf" "password = $(printf 'Zq9%.0s' {1..4})Hunter"
  local out; out=$(items)
  assert_json_eq '[.[].id | select(startswith("config:tool"))] | sort' '["config:tool/bad.conf","config:tool/ok.conf"]' "$out"
  assert_json_eq '.[] | select(.id=="config:tool/bad.conf") | .private' true "$out"
  assert_json_eq '.[] | select(.id=="config:tool/ok.conf") | .private' false "$out"
}

test_machine_specific_files_are_high_and_private() {
  setup
  put "$H/hypr/monitors.lua" 'monitor = "eDP-1"'
  put "$H/hypr/gpu.lua" 'env = "AQ_DRM_DEVICES", "/dev/dri/card1"'
  put "$H/hypr/paths.lua" "exec = \"$HOME/bin/thing\""
  put "$H/hypr/names.lua" 'workspace = "DP-3"'
  put "$H/hypr/fine.lua" 'gaps = 1'
  local out; out=$(items)
  local id
  for id in monitors gpu paths names; do
    assert_json_eq ".[] | select(.id==\"config:hypr/$id.lua\") | [.risk,.private,(.provenance.evidence | any(startswith(\"machine-specific\")))]" '["high",true,true]' "$out"
  done
  assert_json_eq '.[] | select(.id=="config:hypr/fine.lua") | [.risk,.private]' '["low",false]' "$out"
}

test_file_contents_are_not_in_the_output() {
  setup
  put "$H/hypr/marker.lua" 'UNIQUE_CONTENT_MARKER_1234 = true'
  case $(items) in *UNIQUE_CONTENT_MARKER*) t_fail "file content in manifest" ;; esac
}

test_backups_and_plugins_are_ignored() {
  setup
  put "$H/hypr/looknfeel.lua.bak.20260101" 'old'
  put "$H/hypr/x.lua~" 'old'
  put "$H/omarchy/plugins/p1/plugin.json" '{}'
  assert_eq '["config:hypr/extra.lua","config:hypr/looknfeel.lua"]' "$(ids)"
}

test_executable_and_hook_files_are_medium_risk() {
  setup
  put "$H/omarchy/hooks/post-update.d/10-x" 'echo hi'
  put "$H/hypr/run.sh" 'echo hi'
  put "$H/hypr/plain.lua" 'x'
  chmod +x "$H/hypr/plain.lua"
  assert_json_eq '[.[] | select(.id=="config:omarchy/hooks" or (.id|test("hooks|run.sh|plain"))) | .risk] | unique' '["medium"]' "$(items)"
}

test_oversized_unshipped_dir_is_skipped() {
  setup
  local i
  for i in 1 2 3 4; do put "$H/bigstate/f$i" "$i"; done
  export STARTKIN_CONFIG_MAX_FILES=3
  assert_json_eq '[.[].id | select(startswith("config:bigstate"))]' '[]' "$(items)"
  unset STARTKIN_CONFIG_MAX_FILES
  assert_json_eq '[.[].id | select(startswith("config:bigstate"))]' '["config:bigstate"]' "$(items)"
}

test_symlinks_are_reported_not_followed() {
  setup
  ln -s /nonexistent/target "$H/hypr/link.lua"
  assert_json_eq '.[] | select(.id=="config:hypr/link.lua") | .provenance.evidence | index("symlink") != null' true "$(items)"
}

test_output_validates_and_passes_secret_check() {
  setup
  put "$H/hypr/monitors.lua" 'monitor = "eDP-1"'
  jq -n --argjson items "$(items)" '{schema_version:"1.0",machine:{hostname:"h",omarchy_version:"1",arch:"x86_64",gpu:[],form_factor:"desktop"},items:$items}' >"$T_TMP/m.json"
  assert_status 0 "$ROOT/scripts/validate-manifest" "$T_TMP/m.json"
  assert_status 0 "$ROOT/scripts/check-manifest-secrets" "$T_TMP/m.json"
}

test_missing_config_dir_is_empty() {
  setup
  rm -rf "$H"
  assert_eq '[]' "$(items | jq -c .)"
}

run_tests
