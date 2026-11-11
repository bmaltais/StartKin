#!/usr/bin/env bash
# Tests for `startkin apply` packages and tools (lib/apply.sh). Every installer is a stub that logs its argv and, for
# package managers, records the result in $STATE: nothing is ever really installed.
# shellcheck disable=SC2031,SC2016 # T_TMP is per test; stub bodies expand when they run
# shellcheck source=apply_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/apply_lib.sh"

test_dry_run_shows_commands_and_installs_nothing() {
  setup; answer ""
  mf "$(pac ripgrep)" "$(pac fd)"
  assert_status 0 run_apply "$T_TMP/m.json" --dry-run
  assert_contains "$T_OUT" "omarchy pkg add ripgrep fd"
  assert_contains "$T_OUT" "planned"
  assert_eq "" "$(only_calls '^omarchy')" "no install ran"
  assert_eq "" "$(cat "$STATE")"
}

test_pacman_batched_into_one_call_after_confirmation() {
  setup; answer y
  mf "$(pac ripgrep)" "$(pac fd)"
  assert_status 0 run_apply "$T_TMP/m.json"
  assert_eq "1" "$(only_calls '^omarchy pkg add' | grep -c .)"
  assert_contains "$(calls)" "omarchy pkg add ripgrep fd"
  assert_contains "$T_OUT" "installed pacman:ripgrep"
}

test_declined_confirmation_installs_nothing() {
  setup; answer n
  mf "$(pac ripgrep)"
  assert_status 0 run_apply "$T_TMP/m.json"
  assert_eq "" "$(only_calls '^omarchy')"
  assert_contains "$T_OUT" "not confirmed"
  : >"$T_TMP/in"
  assert_status 0 run_apply "$T_TMP/m.json"
  assert_eq "" "$(only_calls '^omarchy')" "end of input is no"
}

test_yes_skips_prompt() {
  setup; answer ""
  mf "$(pac ripgrep)"
  assert_status 0 run_apply "$T_TMP/m.json" --yes
  assert_contains "$(calls)" "omarchy pkg add ripgrep"
}

test_already_installed_is_skipped_and_reported() {
  setup; answer y
  echo ripgrep >"$STATE"
  mf "$(pac ripgrep)"
  assert_status 0 run_apply "$T_TMP/m.json"
  assert_contains "$T_OUT" "present   pacman:ripgrep"
  assert_eq "" "$(only_calls '^omarchy')"
}

test_present_note_mentions_defaults_when_versions_differ() {
  setup; answer y
  echo ripgrep >"$STATE"
  mf "$(pac ripgrep)"
  jq '.machine.omarchy_version = "3.3.0-1"' "$T_TMP/m.json" >"$T_TMP/m2.json"
  assert_status 0 run_apply "$T_TMP/m2.json" --dry-run
  assert_contains "$T_OUT" "now in Omarchy defaults"
  assert_contains "$T_ERR" "3.3.0-1"
}

test_aur_uses_omarchy_and_flags_downloaded_code() {
  setup; answer y
  mf "$(aur yay-thing)"
  assert_status 0 run_apply "$T_TMP/m.json"
  assert_contains "$T_OUT" "runs downloaded code"
  assert_contains "$(calls)" "omarchy pkg aur add yay-thing"
}

test_aur_falls_back_to_helper_when_no_omarchy() {
  setup; answer y
  export STARTKIN_OMARCHY=$T_BIN/absent
  stub yay 'echo "yay $*" >>"$CALLS"; shift; shift; [[ $1 == -- ]] && shift; printf "%s\n" "$@" >>"$STATE"'
  mf "$(aur foo)"
  assert_status 0 run_apply "$T_TMP/m.json"
  assert_contains "$(calls)" "yay -S --needed -- foo"
}

test_install_that_did_not_land_is_failed() {
  setup; answer y
  stub omarchy 'echo "omarchy $*" >>"$CALLS"; exit 0'
  mf "$(pac ripgrep)"
  assert_status 1 run_apply "$T_TMP/m.json"
  assert_contains "$T_OUT" "failed    pacman:ripgrep"
}

test_floating_terminal_when_no_tty() {
  setup; answer y
  export STARTKIN_FLOAT_CMD=$T_BIN/float
  stub float 'echo "float $*" >>"$CALLS"; bash -c "$1"'
  mf "$(pac ripgrep)"
  assert_status 0 run_apply "$T_TMP/m.json"
  assert_contains "$T_OUT" "/float "
  assert_contains "$(calls)" "float $T_BIN/omarchy pkg add ripgrep"
}

# A float stub that spews ghostty-style debug noise on stdout and stderr, then runs the command.
noisy_float() {
  export STARTKIN_FLOAT_CMD=$T_BIN/float
  stub float 'echo "float $*" >>"$CALLS"; echo "info(opengl): EGL extensions=x"; echo "warning(io_exec): odd" >&2; '"$1"
}

test_floating_terminal_noise_goes_to_a_log_not_the_output() {
  setup; answer y
  noisy_float 'bash -c "$1"'
  mf "$(pac ripgrep)"
  assert_status 0 run_apply "$T_TMP/m.json"
  assert_not_contains "$T_OUT" "info(opengl)"
  assert_not_contains "$T_OUT" "warning(io_exec)"
  assert_not_contains "$T_ERR" "io_exec"
  assert_not_contains "$T_ERR" "opengl"
  assert_not_contains "$T_OUT" "apply-terminal.log"
  assert_contains "$(cat "$STARTKIN_STATE_DIR/apply-terminal.log")" "info(opengl): EGL extensions=x"
  assert_contains "$(cat "$STARTKIN_STATE_DIR/apply-terminal.log")" "warning(io_exec): odd"
}

test_failed_floating_install_names_the_log_and_shows_its_tail() {
  setup; answer y
  noisy_float 'exit 1'
  mf "$(pac ripgrep)"
  assert_status 1 run_apply "$T_TMP/m.json"
  assert_contains "$T_OUT" "failed    pacman:ripgrep"
  assert_contains "$T_OUT" "$STARTKIN_STATE_DIR/apply-terminal.log"
  assert_contains "$T_OUT" "info(opengl): EGL extensions=x"
}

test_registry_tools_pinned_and_run() {
  setup; answer y
  mf "$(it cargo:bat registry-tool cli '{"type":"cargo","crate":"bat","locked":true}' 0.24.0)" \
    "$(it go:x registry-tool cli '{"type":"go","module":"github.com/x/y/cmd/tool"}' v1.2.3)" \
    "$(it npm:left registry-tool cli '{"type":"npm","package":"left"}' 2.0.0)" \
    "$(it uv:ruff registry-tool cli '{"type":"uv","package":"ruff"}' 0.5.0)" \
    "$(it pipx:black registry-tool cli '{"type":"pipx","package":"black"}' 24.1.0)" \
    "$(it mise:node registry-tool runtime '{"type":"mise","tool":"node"}' 22.1.0)"
  stub npm 'echo "npm $*" >>"$CALLS"; [[ $1 == ls ]] && exit 1; exit 0'
  assert_status 0 run_apply "$T_TMP/m.json" --yes
  local c
  c=$(calls)
  assert_contains "$c" "cargo install --locked --version 0.24.0 bat"
  assert_contains "$c" "go install github.com/x/y/cmd/tool@v1.2.3"
  assert_contains "$c" "npm install -g left@2.0.0"
  assert_contains "$c" "uv tool install ruff==0.5.0"
  assert_contains "$c" "pipx install black==24.1.0"
  assert_contains "$c" "mise use -g node@22.1.0"
}

test_registry_tool_already_installed_is_skipped() {
  setup; answer y
  stub cargo 'echo "cargo $*" >>"$CALLS"; [[ $1 == install && $2 == --list ]] && echo "bat v0.24.0:"; exit 0'
  mf "$(it cargo:bat registry-tool cli '{"type":"cargo","crate":"bat"}' 0.24.0)"
  assert_status 0 run_apply "$T_TMP/m.json"
  assert_contains "$T_OUT" "present   cargo:bat"
  assert_eq "" "$(only_calls 'install --version')"
}

test_crate_name_is_matched_literally_in_the_installed_list() {
  setup; answer y
  stub cargo 'echo "cargo $*" >>"$CALLS"; [[ $1 == install && $2 == --list ]] && echo "axb v1.0.0:"; exit 0'
  mf "$(it cargo:a.b registry-tool cli '{"type":"cargo","crate":"a.b"}' 1.0.0)"
  assert_status 0 run_apply "$T_TMP/m.json"
  assert_contains "$(calls)" "cargo install --version 1.0.0 a.b"
}

test_unpinned_git_build_and_unverified_download_need_allow_unpinned() {
  setup; answer ""
  stub git 'echo "git $*" >>"$CALLS"; if [[ $1 == clone ]]; then mkdir -p "${@: -1}"; fi'
  stub curl 'echo "curl $*" >>"$CALLS"; while [[ $1 != -o ]]; do shift; done; printf x >"$2"'
  mf "$(it t1 repo-tool cli '{"type":"git-build","url":"https://example.com/o/t1.git","build":["true"]}')" \
    "$(it rb:a repo-tool cli '{"type":"release-binary","url":"https://example.com/a"}')"
  assert_status 0 run_apply "$T_TMP/m.json" --yes
  assert_eq "" "$(only_calls 'git clone')"
  assert_eq "" "$(only_calls curl)"
  assert_contains "$T_OUT" "not confirmed"
  assert_status 0 run_apply "$T_TMP/m.json" --yes --allow-unpinned
  assert_contains "$(calls)" "git clone"
  assert_contains "$(calls)" "curl"
}

test_pinned_items_still_run_on_plain_yes() {
  setup; answer ""
  stub git 'echo "git $*" >>"$CALLS"; if [[ $1 == clone ]]; then mkdir -p "${@: -1}"; fi'
  mf "$(it t1 repo-tool cli '{"type":"git-build","url":"https://example.com/o/t1.git","ref":"v1","build":["true"]}')"
  assert_status 0 run_apply "$T_TMP/m.json" --yes
  assert_contains "$(calls)" "git clone"
}

test_registry_tool_needs_confirmation_per_item() {
  setup; answer n
  mf "$(it npm:left registry-tool cli '{"type":"npm","package":"left"}' 2.0.0)"
  stub npm 'echo "npm $*" >>"$CALLS"; [[ $1 == ls ]] && exit 1; exit 0'
  assert_status 0 run_apply "$T_TMP/m.json"
  assert_contains "$T_OUT" "npm install -g left@2.0.0"
  assert_eq "" "$(only_calls 'npm install')"
}

test_git_build_clones_pins_and_builds() {
  setup; answer y
  stub git 'echo "git $*" >>"$CALLS"; if [[ $1 == clone ]]; then mkdir -p "${@: -1}"; fi'
  stub make 'echo "make $*" >>"$CALLS"'
  mf "$(it track:git-build:tool repo-tool cli '{"type":"git-build","url":"https://example.com/o/tool.git","ref":"v1.0","build":["make","make install PREFIX=$HOME/.local"]}')"
  assert_status 0 run_apply "$T_TMP/m.json"
  assert_contains "$T_OUT" "runs downloaded code"
  assert_contains "$(calls)" "git clone -- https://example.com/o/tool.git $T_TMP/src/tool"
  assert_contains "$(calls)" "git -C $T_TMP/src/tool checkout v1.0"
  assert_contains "$(calls)" "make install PREFIX=$HOME/.local"
}

test_git_build_unpinned_is_called_out_and_bad_url_rejected() {
  setup; answer ""
  mf "$(it t1 repo-tool cli '{"type":"git-build","url":"https://example.com/o/t1.git","build":["make"]}')" \
    "$(it t2 repo-tool cli '{"type":"git-build","url":"https://x/$(touch pwned)","build":["make"]}')"
  assert_status 0 run_apply "$T_TMP/m.json" --dry-run
  assert_contains "$T_OUT" "unpinned"
  assert_contains "$T_OUT" "skipped   t2 (invalid url in manifest)"
}

test_release_binary_verifies_checksum_before_install() {
  setup; answer y
  local sha
  sha=$(printf 'x' | sha256sum | cut -d' ' -f1)
  stub curl 'echo "curl $*" >>"$CALLS"; while [[ $1 != -o ]]; do shift; done; printf x >"$2"'
  mf "$(it rb:tool repo-tool cli "{\"type\":\"release-binary\",\"url\":\"https://example.com/tool-linux\",\"sha256\":\"$sha\"}")"
  assert_status 0 run_apply "$T_TMP/m.json"
  [[ -x $HOME/.local/bin/tool-linux ]] || t_fail "binary not installed"
  assert_contains "$T_OUT" "sha256sum -c"
}

test_release_binary_bad_checksum_installs_nothing() {
  setup; answer y
  stub curl 'while [[ $1 != -o ]]; do shift; done; printf x >"$2"'
  mf "$(it rb:tool repo-tool cli "{\"type\":\"release-binary\",\"url\":\"https://example.com/tool-linux\",\"sha256\":\"$(printf '0%.0s' {1..64})\"}")"
  assert_status 1 run_apply "$T_TMP/m.json"
  [[ ! -e $HOME/.local/bin/tool-linux ]] || t_fail "installed despite checksum mismatch"
  assert_contains "$T_OUT" "failed"
}

test_release_binary_without_checksum_warns_and_archives_skipped() {
  setup; answer ""
  mf "$(it rb:a repo-tool cli '{"type":"release-binary","url":"https://example.com/a"}')" \
    "$(it rb:b repo-tool cli '{"type":"appimage","url":"https://example.com/b.tar.gz"}')" \
    "$(it rb:c repo-tool cli '{"type":"release-binary","url":"http://example.com/c"}')"
  assert_status 0 run_apply "$T_TMP/m.json" --dry-run
  assert_contains "$T_OUT" "not verified"
  assert_contains "$T_OUT" "only raw binaries"
  assert_contains "$T_OUT" "skipped   rb:c (invalid url"
}

test_copy_needs_peer_and_unknown_is_skipped() {
  setup; answer ""
  mf "$(it cp:x repo-tool cli '{"type":"copy","path":"~/.local/bin/x","dest":"~/.local/bin/x"}')" \
    "$(it un:y repo-tool cli '{"type":"unknown","path":"~/y"}')"
  assert_status 0 run_apply "$T_TMP/m.json" --dry-run
  assert_contains "$T_OUT" "--from-peer"
  assert_contains "$T_OUT" "no install method"
}

test_incompatible_items_are_skipped_with_reason() {
  setup; answer y
  mf "$(it rb:z repo-tool cli '{"type":"release-binary","url":"https://example.com/z"}')" "$(pac ripgrep)"
  jq '.machine.arch = "riscv64"' "$T_TMP/m.json" >"$T_TMP/m2.json"
  assert_status 0 run_apply "$T_TMP/m2.json" --dry-run
  assert_contains "$T_OUT" "skipped   rb:z (incompatible with this machine: built for riscv64"
  assert_eq "" "$(only_calls curl)"
}

test_overlapping_items_reconciled() {
  setup; answer ""
  mf "$(pac rust)" "$(it mise:rust registry-tool runtime '{"type":"mise","tool":"rust"}' 1.80.0)" \
    "$(it launcher:spotify.desktop launcher launcher '{"type":"copy","path":"~/x.desktop"}' "" 0.8)" "$(pac spotify)"
  assert_status 0 run_apply "$T_TMP/m.json" --dry-run
  assert_contains "$T_OUT" "skipped   mise:rust (duplicate of pacman:rust)"
  assert_contains "$T_OUT" "skipped   launcher:spotify.desktop (duplicate of pacman:spotify)"
  assert_contains "$T_OUT" "omarchy pkg add rust spotify"
}

test_higher_confidence_wins_overlap() {
  setup; answer ""
  mf "$(it pacman:node package runtime '{"type":"pacman","package":"node"}' "" 0.5)" \
    "$(it mise:node registry-tool runtime '{"type":"mise","tool":"node"}' 22.1.0 0.95)"
  assert_status 0 run_apply "$T_TMP/m.json" --dry-run
  assert_contains "$T_OUT" "skipped   pacman:node (duplicate of mise:node)"
}

test_only_selects_items_and_rejects_unknown_ids() {
  setup; answer y
  mf "$(pac ripgrep)" "$(pac fd)"
  assert_status 0 run_apply "$T_TMP/m.json" --only pacman:fd --yes
  assert_contains "$(calls)" "omarchy pkg add fd"
  assert_eq "" "$(only_calls '^omarchy.*ripgrep')"
  assert_status 2 run_apply "$T_TMP/m.json" --only nope
  assert_contains "$T_ERR" "nope"
}

test_items_without_a_stage_are_reported() {
  setup; answer ""
  mf "$(it launcher:x.desktop launcher launcher '{"type":"copy","path":"~/x.desktop"}')"
  assert_status 0 run_apply "$T_TMP/m.json" --dry-run
  assert_contains "$T_OUT" "skipped   launcher:x.desktop (no apply stage"
}

test_invalid_package_name_rejected() {
  setup; answer ""
  mf "$(pac 'x; touch pwned')"
  assert_status 0 run_apply "$T_TMP/m.json" --dry-run
  assert_contains "$T_OUT" "invalid package"
}

test_bad_manifest_and_usage() {
  setup; answer ""
  echo '{"nope":1}' >"$T_TMP/bad.json"
  assert_status 15 run_apply "$T_TMP/bad.json"
  assert_status 1 run_apply "$T_TMP/missing.json"
  assert_status 2 run_apply
  mf "$(pac a)"
  assert_status 2 run_apply "$T_TMP/m.json" --bogus
}

test_from_peer_fetches_manifest() {
  setup; answer y
  mf "$(pac ripgrep)"
  stub tailscale 'echo "{\"Peer\":{\"a\":{\"HostName\":\"box\",\"DNSName\":\"box.ts.net.\",\"OS\":\"linux\",\"Online\":true,\"TailscaleIPs\":[\"100.1.1.1\"]}}}"'
  stub ssh 'if [[ $* == *--version* ]]; then echo "startkin '"$(<"$ROOT/VERSION")"'"; else cat "$T_TMP/m.json"; fi'
  assert_status 0 run_apply --from-peer box --yes
  assert_contains "$(calls)" "omarchy pkg add ripgrep"
}

run_tests
