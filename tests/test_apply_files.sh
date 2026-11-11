#!/usr/bin/env bash
# Tests for `startkin apply` plugins, config and services, and `startkin rollback` (#14; lib/apply_more.sh, lib/backup.sh).
# Hermetic: HOME is a temp dir, systemctl/sudo/omarchy/scp are stubs, the "peer" is a directory of files.
# shellcheck disable=SC2031,SC2016 # T_TMP is per test; stub bodies expand when they run
# shellcheck source=apply_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/apply_lib.sh"

# plugin ID SOURCE [EVIDENCE_JSON_ARRAY] : a git-installed plugin item
plugin() {
  jq -c --argjson e "${3:-[]}" '.provenance.evidence = $e' <<<"$(it "plugin:$1" plugin plugin \
    "$(jq -nc --arg i "$1" --arg s "$2" '{type:"plugin",plugin_id:$i,source:$s}')")"
}

test_plugin_is_added_from_its_url_after_confirmation() {
  setup; answer y
  mf "$(plugin io.x.foo https://example.com/foo.git)"
  assert_status 0 run_apply "$T_TMP/m.json"
  assert_contains "$T_OUT" "omarchy plugin add https://example.com/foo.git"
  assert_contains "$T_OUT" "[runs downloaded code]"
  assert_contains "$(calls)" "omarchy plugin add https://example.com/foo.git --yes"
  assert_contains "$T_OUT" "installed plugin:io.x.foo"
}

test_plugin_install_is_never_covered_by_global_yes() {
  setup; answer ""
  mf "$(plugin io.x.foo https://example.com/foo.git)"
  assert_status 0 run_apply "$T_TMP/m.json" --yes
  assert_eq "" "$(only_calls 'plugin add')"
  assert_contains "$T_OUT" "not confirmed"
  assert_status 0 run_apply "$T_TMP/m.json" --yes --allow-plugins
  assert_contains "$(calls)" "omarchy plugin add https://example.com/foo.git"
}

test_plugin_is_pinned_before_it_is_enabled() {
  setup; answer y
  local sha=0123456789abcdef0123456789abcdef01234567 c
  mf "$(plugin io.x.foo https://example.com/foo.git "[\"rev $sha\",\"enabled in shell.json\"]")"
  assert_status 0 run_apply "$T_TMP/m.json"
  c=$(calls)
  assert_contains "$c" "omarchy plugin add https://example.com/foo.git --yes"
  assert_eq "" "$(only_calls -e '--enable')"
  assert_contains "$c" "git -C $HOME/.config/omarchy/plugins/io.x.foo checkout $sha"
  assert_contains "$c" "omarchy plugin enable io.x.foo"
  assert_eq "add checkout enable" "$(grep -oE 'plugin add|checkout|plugin enable' "$CALLS" | sed 's/plugin //' | paste -sd' ')"
}

test_plugin_is_not_enabled_when_the_pin_fails() {
  setup; answer y
  local sha=0123456789abcdef0123456789abcdef01234567
  stub git 'echo "git $*" >>"$CALLS"; exit 1'
  mf "$(plugin io.x.foo https://example.com/foo.git "[\"rev $sha\",\"enabled in shell.json\"]")"
  assert_status 1 run_apply "$T_TMP/m.json"
  assert_contains "$T_OUT" "failed    plugin:io.x.foo"
  assert_eq "" "$(only_calls 'plugin enable')"
}

test_plugin_without_enabled_evidence_is_not_enabled() {
  setup; answer y
  mf "$(plugin io.x.foo https://example.com/foo.git)"
  assert_status 0 run_apply "$T_TMP/m.json"
  assert_eq "" "$(only_calls 'plugin enable')"
}

test_plugin_copy_needs_allow_plugins_not_just_yes() {
  setup; peer_setup; answer ""
  mkdir -p "$REMOTE/.config/omarchy/plugins/cp"
  echo '{}' >"$REMOTE/.config/omarchy/plugins/cp/manifest.json"
  mf "$(it plugin:cp plugin plugin '{"type":"copy","path":"~/.config/omarchy/plugins/cp"}')"
  assert_status 0 run_apply --from-peer box --yes
  [[ ! -e $STARTKIN_PLUGINS_DIR/cp ]] || t_fail "plugin copy installed on bare --yes"
  assert_status 0 run_apply --from-peer box --yes --allow-plugins
  [[ -e $STARTKIN_PLUGINS_DIR/cp/manifest.json ]] || t_fail "plugin copy not installed with --allow-plugins"
}

test_user_unit_copy_needs_allow_units_not_just_yes() {
  setup; peer_setup; answer ""
  mkdir -p "$REMOTE/.config/systemd/user"
  echo "[Service]" >"$REMOTE/.config/systemd/user/mine.service"
  mf "$(svc user mine.service '{"type":"copy","path":"~/.config/systemd/user/mine.service"}')"
  assert_status 0 run_apply --from-peer box --yes
  [[ ! -e $HOME/.config/systemd/user/mine.service ]] || t_fail "unit file installed on bare --yes"
  assert_eq "" "$(only_calls 'enable')"
  assert_status 0 run_apply --from-peer box --yes --allow-units
  assert_contains "$(calls)" "systemctl --user enable --now mine.service"
}

test_symlinked_parent_cannot_redirect_a_write_out_of_home() {
  setup; peer_setup; answer y
  mkdir -p "$T_TMP/outside" "$HOME/.config"
  ln -s "$T_TMP/outside" "$HOME/.config/evil"
  remote evil/x.conf "pwn"
  mf "$(cfg evil/x.conf)"
  assert_status 0 run_apply --from-peer box
  [[ ! -e $T_TMP/outside/x.conf ]] || t_fail "wrote through a symlinked parent"
  assert_contains "$T_OUT" "skipped   config:evil/x.conf"
}

test_plugin_already_present_and_bad_values_skipped() {
  setup; answer y
  mkdir -p "$STARTKIN_PLUGINS_DIR/io.x.foo"
  mf "$(plugin io.x.foo https://example.com/foo.git)" "$(plugin io.x.bad 'https://e.com/x;rm -rf ~')" \
    "$(it plugin:io.x.cp plugin plugin '{"type":"unknown","path":"~/p","hint":"clone of built-in"}')"
  assert_status 0 run_apply "$T_TMP/m.json"
  assert_contains "$T_OUT" "present   plugin:io.x.foo"
  assert_contains "$T_OUT" "skipped   plugin:io.x.bad (invalid source"
  assert_contains "$T_OUT" "skipped   plugin:io.x.cp"
  assert_eq "" "$(only_calls 'plugin add')"
}

test_plugin_dry_run_executes_nothing() {
  setup; answer ""
  mf "$(plugin io.x.foo https://example.com/foo.git)"
  assert_status 0 run_apply "$T_TMP/m.json" --dry-run
  assert_contains "$T_OUT" "planned   plugin:io.x.foo"
  assert_eq "" "$(only_calls 'plugin add')"
}

# ---- config ----------------------------------------------------------------------------------------------------------

# peer_setup : a Tailscale peer "box" whose home is $REMOTE; scp copies from it, ssh serves $T_TMP/m.json
peer_setup() {
  export REMOTE=$T_TMP/remote
  mkdir -p "$REMOTE"
  stub tailscale 'echo "{\"Peer\":{\"a\":{\"HostName\":\"box\",\"DNSName\":\"box.ts.net.\",\"OS\":\"linux\",\"Online\":true,\"TailscaleIPs\":[\"100.1.1.1\"]}}}"'
  stub ssh 'if [[ $* == *--version* ]]; then echo "startkin '"$(<"$ROOT/VERSION")"'"; else cat "$T_TMP/m.json"; fi'
  stub scp 'echo "scp $*" >>"$CALLS"
src=${*: -2:1}; dst=${*: -1}
[[ $src == box.ts.net:* ]] || exit 1
cp -a "$REMOTE/${src#box.ts.net:}" "$dst"'
}

# cfg REL [PRIVATE [EVIDENCE_JSON_ARRAY]] : a config copy item for ~/.config/REL
cfg() {
  jq -c --argjson p "${2:-false}" --argjson e "${3:-[]}" '.private = $p | .provenance.evidence = $e' <<<"$(it "config:$1" config config \
    "$(jq -nc --arg r "$1" '{type:"copy",path:("~/.config/"+$r),dest:("~/.config/"+$r)}')")"
}
# remote REL CONTENT : put a file on the peer; local REL CONTENT : put a file on this machine
remote() { mkdir -p "$(dirname "$REMOTE/.config/$1")"; printf '%s\n' "$2" >"$REMOTE/.config/$1"; }
local_cfg() { mkdir -p "$(dirname "$HOME/.config/$1")"; printf '%s\n' "$2" >"$HOME/.config/$1"; }
content() { cat "$HOME/.config/$1"; }

test_config_content_is_not_in_the_manifest_so_a_file_manifest_needs_a_peer() {
  setup; answer y
  mf "$(cfg foo/a.conf)"
  assert_status 0 run_apply "$T_TMP/m.json"
  assert_contains "$T_OUT" "skipped   config:foo/a.conf"
  assert_contains "$T_OUT" "--from-peer"
  [[ ! -e $HOME/.config/foo/a.conf ]] || t_fail "written without content"
}

test_new_config_file_is_fetched_from_the_peer_and_created() {
  setup; peer_setup; answer y
  remote foo/a.conf "color=red"
  mf "$(cfg foo/a.conf)"
  assert_status 0 run_apply --from-peer box
  assert_contains "$T_OUT" "new: "
  assert_contains "$T_OUT" "installed config:foo/a.conf"
  assert_eq "color=red" "$(content foo/a.conf)"
  assert_contains "$T_OUT" "startkin rollback"
}

test_changed_config_shows_a_diff_backs_up_and_replaces() {
  setup; peer_setup; answer y
  remote foo/a.conf "color=red"
  local_cfg foo/a.conf "color=blue"
  mf "$(cfg foo/a.conf)"
  assert_status 0 run_apply --from-peer box
  assert_contains "$T_OUT" "-color=blue"
  assert_contains "$T_OUT" "+color=red"
  assert_eq "color=red" "$(content foo/a.conf)"
  assert_eq "color=blue" "$(cat "$STARTKIN_STATE_DIR"/backups/*/files/.config/foo/a.conf)"
}

test_declined_config_is_left_alone_and_unchanged_is_present() {
  setup; peer_setup; answer n
  remote foo/a.conf "color=red"
  remote foo/b.conf "same"
  local_cfg foo/a.conf "color=blue"
  local_cfg foo/b.conf "same"
  mf "$(cfg foo/a.conf)" "$(cfg foo/b.conf)"
  assert_status 0 run_apply --from-peer box
  assert_eq "color=blue" "$(content foo/a.conf)"
  assert_contains "$T_OUT" "skipped   config:foo/a.conf (not confirmed)"
  assert_contains "$T_OUT" "present   config:foo/b.conf"
  [[ ! -d $STARTKIN_STATE_DIR/backups ]] || t_fail "backup made without a change"
}

test_config_dry_run_fetches_and_writes_nothing() {
  setup; peer_setup; answer ""
  remote foo/a.conf "color=red"
  local_cfg foo/a.conf "color=blue"
  mf "$(cfg foo/a.conf)"
  assert_status 0 run_apply --from-peer box --dry-run
  assert_contains "$T_OUT" "planned   config:foo/a.conf"
  assert_eq "" "$(only_calls '^scp')"
  assert_eq "color=blue" "$(content foo/a.conf)"
  [[ ! -d $STARTKIN_STATE_DIR ]] || t_fail "state written in a dry run"
}

test_machine_specific_config_needs_explicit_consent_even_with_yes() {
  setup; peer_setup; answer ""
  remote hypr/monitors.conf "monitor=DP-1,preferred"
  remote foo/gpu.conf "env=DRI_PRIME,1"
  local_cfg hypr/monitors.conf "monitor=eDP-1,preferred"
  mf "$(cfg hypr/monitors.conf true '["machine-specific: monitor layout"]')" \
    "$(cfg foo/gpu.conf true '["machine-specific: gpu settings"]')"
  assert_status 0 run_apply --from-peer box --yes
  assert_contains "$T_OUT" "machine-specific"
  assert_contains "$T_OUT" "skipped   config:hypr/monitors.conf (not confirmed)"
  assert_eq "monitor=eDP-1,preferred" "$(content hypr/monitors.conf)"
  [[ ! -e $HOME/.config/foo/gpu.conf ]] || t_fail "machine-specific file written under --yes"
  assert_status 0 run_apply --from-peer box --yes --allow-machine-specific
  assert_eq "monitor=DP-1,preferred" "$(content hypr/monitors.conf)"
  assert_eq "env=DRI_PRIME,1" "$(content foo/gpu.conf)"
}

test_monitors_file_is_machine_specific_even_if_the_manifest_forgot() {
  setup; peer_setup; answer ""
  remote hypr/monitors.conf "monitor=DP-1,preferred"
  mf "$(cfg hypr/monitors.conf)"
  assert_status 0 run_apply --from-peer box --yes
  [[ ! -e $HOME/.config/hypr/monitors.conf ]] || t_fail "monitors.conf written under --yes"
}

test_keys_are_never_applied_with_or_without_flags() {
  setup; peer_setup; answer y
  mkdir -p "$REMOTE/.ssh"
  echo "key" >"$REMOTE/.ssh/id_ed25519"
  mf "$(it config:k config config '{"type":"copy","path":"~/.ssh/id_ed25519","dest":"~/.ssh/id_ed25519"}')" \
    "$(it config:k2 config config '{"type":"copy","path":"~/.config/../.ssh/id_ed25519","dest":"~/.config/../.ssh/id_ed25519"}')"
  assert_status 0 run_apply --from-peer box --yes --allow-machine-specific --allow-plugins
  assert_contains "$T_OUT" "skipped   config:k"
  assert_contains "$T_OUT" "skipped   config:k2"
  [[ ! -e $HOME/.ssh ]] || t_fail "key written"
}

test_destination_outside_dot_config_is_refused() {
  setup; peer_setup; answer y
  mkdir -p "$REMOTE/.local"
  echo x >"$REMOTE/.local/x"
  mf "$(it config:o config config '{"type":"copy","path":"~/.local/x","dest":"~/.bashrc"}')"
  assert_status 0 run_apply --from-peer box --yes
  assert_contains "$T_OUT" "skipped   config:o (destination must be inside"
  [[ ! -e $HOME/.bashrc ]] || t_fail "wrote outside ~/.config"
}

test_fetched_content_with_a_secret_is_refused_and_never_printed() {
  setup; peer_setup; answer y
  local tok
  tok="ghp_$(printf 'a%.0s' {1..36})"
  remote foo/a.conf "token=$tok"
  mf "$(cfg foo/a.conf)"
  assert_status 0 run_apply --from-peer box --yes
  assert_contains "$T_OUT" "skipped   config:foo/a.conf (fetched content failed the secrets check: github-token at line 1"
  [[ $T_OUT$T_ERR != *"$tok"* ]] || t_fail "secret printed"
  [[ ! -e $HOME/.config/foo/a.conf ]] || t_fail "secret-bearing file written"
}

test_scanner_flagged_content_is_never_applied() {
  setup; peer_setup; answer y
  remote foo/a.conf "x=1"
  mf "$(cfg foo/a.conf true '["content flagged (github-token) at line 1"]')"
  assert_status 0 run_apply --from-peer box --yes --allow-machine-specific
  assert_contains "$T_OUT" "skipped   config:foo/a.conf"
  [[ ! -e $HOME/.config/foo/a.conf ]] || t_fail "flagged file written"
}

test_config_directory_is_merged_and_rolled_back_whole() {
  setup; peer_setup; answer y
  mkdir -p "$REMOTE/.config/dir"
  echo new >"$REMOTE/.config/dir/a"
  mkdir -p "$HOME/.config/dir"
  echo old >"$HOME/.config/dir/a"
  echo keep >"$HOME/.config/dir/mine"
  mf "$(it config:dir config config '{"type":"copy","path":"~/.config/dir","dest":"~/.config/dir"}')"
  assert_status 0 run_apply --from-peer box
  assert_eq "new" "$(content dir/a)"
  assert_eq "keep" "$(content dir/mine)"
  assert_status 0 "$BIN" rollback latest --yes
  assert_eq "old" "$(content dir/a)"
}

# ---- rollback --------------------------------------------------------------------------------------------------------

test_rollback_restores_replaced_files_and_removes_created_ones() {
  setup; peer_setup; answer y
  remote foo/a.conf "color=red"
  remote foo/new.conf "n=1"
  local_cfg foo/a.conf "color=blue"
  mf "$(cfg foo/a.conf)" "$(cfg foo/new.conf)"
  assert_status 0 run_apply --from-peer box
  assert_eq "color=red" "$(content foo/a.conf)"
  answer y
  assert_status 0 run_apply_rollback latest
  assert_eq "color=blue" "$(content foo/a.conf)"
  [[ ! -e $HOME/.config/foo/new.conf ]] || t_fail "created file survived rollback"
  assert_status 1 run_apply_rollback latest
  assert_contains "$T_ERR" "nothing to roll back"
}

run_apply_rollback() { "$BIN" rollback "$@" <"$T_TMP/in"; }

test_rollback_by_id_list_and_errors() {
  setup; peer_setup; answer y
  remote foo/a.conf "color=red"
  mf "$(cfg foo/a.conf)"
  assert_status 0 run_apply --from-peer box
  assert_status 0 "$BIN" rollback --list
  local id
  id=$(awk 'NR==1{print $1}' <<<"$T_OUT")
  [[ -n $id ]] || t_fail "no id listed"
  answer n
  assert_status 1 run_apply_rollback "$id"
  [[ -e $HOME/.config/foo/a.conf ]] || t_fail "declined rollback still removed the file"
  assert_status 0 "$BIN" rollback "$id" --dry-run
  assert_contains "$T_OUT" "remove"
  [[ -e $HOME/.config/foo/a.conf ]] || t_fail "dry-run rollback changed the file"
  assert_status 1 "$BIN" rollback no-such-id --yes
  assert_status 0 "$BIN" rollback "$id" --yes
  [[ ! -e $HOME/.config/foo/a.conf ]] || t_fail "rollback by id did not remove the created file"
}

test_rollback_asks_before_overwriting_a_file_changed_since_apply() {
  setup; peer_setup; answer y
  remote foo/a.conf "color=red"
  local_cfg foo/a.conf "color=blue"
  mf "$(cfg foo/a.conf)"
  assert_status 0 run_apply --from-peer box
  echo "edited later" >"$HOME/.config/foo/a.conf"
  answer $'y\nn'
  assert_status 0 run_apply_rollback latest
  assert_contains "$T_OUT" "changed since"
  assert_eq "edited later" "$(content foo/a.conf)"
}

test_rollback_with_a_missing_backup_copy_keeps_the_file() {
  setup; peer_setup; answer y
  remote foo/a.conf "color=red"
  local_cfg foo/a.conf "color=blue"
  mf "$(cfg foo/a.conf)"
  assert_status 0 run_apply --from-peer box
  rm -rf "$STARTKIN_STATE_DIR"/backups/*/files
  assert_status 1 run_apply_rollback latest --yes
  assert_contains "$T_ERR" "backup copy"
  assert_eq "color=red" "$(content foo/a.conf)"
}

# ---- services --------------------------------------------------------------------------------------------------------

svc() { it "service:$1:$2" service service "$3" "" 0.95; }

test_pacman_backed_service_installs_its_package_then_enables_it() {
  setup; answer y
  mf "$(svc system cups.service '{"type":"pacman","package":"cups"}')"
  assert_status 0 run_apply "$T_TMP/m.json" --yes
  assert_contains "$(calls)" "omarchy pkg add cups"
  assert_contains "$(calls)" "systemctl enable --now cups.service"
  assert_contains "$T_OUT" "installed service:system:cups.service"
  assert_status 0 run_apply "$T_TMP/m.json" --yes
  assert_contains "$T_OUT" "present   service:system:cups.service"
}

test_user_service_needs_no_sudo_and_dry_run_runs_nothing() {
  setup; answer y
  mf "$(svc user foo.timer '{"type":"pacman","package":"foo"}')"
  assert_status 0 run_apply "$T_TMP/m.json" --dry-run
  assert_contains "$T_OUT" "systemctl --user enable --now foo.timer"
  assert_contains "$T_OUT" "planned   service:user:foo.timer"
  assert_eq "" "$(only_calls '^systemctl enable\|^systemctl --user enable\|^omarchy')"
  assert_status 0 run_apply "$T_TMP/m.json" --yes
  assert_contains "$(calls)" "systemctl --user enable --now foo.timer"
  assert_eq "" "$(only_calls '^sudo')"
}

test_service_with_missing_package_manager_state_and_bad_values_is_skipped() {
  setup; answer y
  mf "$(svc system 'x;rm.service' '{"type":"pacman","package":"foo"}')" \
    "$(svc system u.service '{"type":"unknown","hint":"systemctl enable u.service"}')"
  assert_status 0 run_apply "$T_TMP/m.json"
  assert_contains "$T_OUT" "skipped   service:system:x;rm.service (invalid"
  assert_contains "$T_OUT" "skipped   service:system:u.service (no install method"
  assert_eq "" "$(only_calls 'enable')"
}

test_user_unit_file_is_copied_from_the_peer_with_backup_then_enabled() {
  setup; peer_setup; answer y
  mkdir -p "$REMOTE/.config/systemd/user"
  echo "[Service]" >"$REMOTE/.config/systemd/user/mine.service"
  mf "$(svc user mine.service '{"type":"copy","path":"~/.config/systemd/user/mine.service"}')"
  answer $'y\ny'
  assert_status 0 run_apply --from-peer box
  assert_eq "[Service]" "$(content systemd/user/mine.service)"
  assert_contains "$(calls)" "systemctl --user daemon-reload"
  assert_contains "$(calls)" "systemctl --user enable --now mine.service"
  assert_contains "$T_OUT" "installed service:user:mine.service"
}

run_tests
