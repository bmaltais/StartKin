#!/usr/bin/env bash
# Tests for `startkin apply` packages and tools (lib/apply.sh). Every installer is a stub that logs its argv and, for
# package managers, records the result in $STATE: nothing is ever really installed.
# shellcheck disable=SC2031,SC2016 # T_TMP is per test; stub bodies expand when they run
# shellcheck source=harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
BIN=$ROOT/bin/startkin

setup() {
  export HOME=$T_TMP/home STARTKIN_NO_GUM=1 STARTKIN_SRC_DIR=$T_TMP/src STARTKIN_DMI_DIR=$T_TMP/dmi
  export CALLS=$T_TMP/calls STATE=$T_TMP/installed
  mkdir -p "$HOME" "$STARTKIN_DMI_DIR"
  # Hermetic: never reach the real omarchy or its terminal launcher (the latter opens a window).
  export STARTKIN_OMARCHY=$T_BIN/omarchy STARTKIN_FLOAT_CMD=$T_BIN/no-float-terminal
  : >"$CALLS"
  : >"$STATE"
  ARCH=$(uname -m)
  stub pacman 'echo "pacman $*" >>"$CALLS"
case $1 in
  -Q) [[ $2 == omarchy ]] && echo "omarchy ${OMARCHY_VER:-3.4.0-1}"; exit 0 ;;
  -Qq) shift; [[ $1 == -- ]] && shift; grep -qxF -- "$1" "$STATE" ;;
esac'
  stub omarchy 'echo "omarchy $*" >>"$CALLS"
if [[ "$1 $2" == "pkg add" ]]; then shift 2; printf "%s\n" "$@" >>"$STATE"; fi
if [[ "$1 $2 $3" == "pkg aur add" ]]; then shift 3; printf "%s\n" "$@" >>"$STATE"; fi'
  stub lspci 'exit 0'
  local t
  for t in cargo go npm uv pipx mise yay git curl; do stub "$t" 'echo "'"$t"' $*" >>"$CALLS"'; done
}

calls() { cat "$CALLS"; }

# mf ITEM_JSON... : write a manifest from this machine's arch to $T_TMP/m.json
mf() {
  local items
  items=$(printf '%s\n' "$@" | jq -s .)
  jq -n --arg a "$ARCH" --argjson i "$items" \
    '{schema_version:"1.0",generated_at:"2026-01-01T00:00:00Z",machine:{hostname:"src",omarchy_version:"3.4.0-1",arch:$a,gpu:[],form_factor:"other"},items:$i}' >"$T_TMP/m.json"
}
# it ID CATEGORY KIND INSTALL_JSON [VERSION [CONF]]
it() {
  jq -nc --arg id "$1" --arg c "$2" --arg k "$3" --argjson i "$4" --arg v "${5-}" --argjson conf "${6-0.95}" \
    '{id:$id,name:$id,kind:$k,category:$c,risk:"low",install:$i,version:(if $v=="" then null else $v end),
      provenance:{method:"package-manager",confidence:$conf,evidence:[]},private:false}'
}
pac() { it "pacman:$1" package cli "$(jq -nc --arg p "$1" '{type:"pacman",package:$p}')" "${2-}"; }
aur() { it "aur:$1" package cli "$(jq -nc --arg p "$1" '{type:"aur",package:$p}')" "${2-}"; }

run_apply() { "$BIN" apply "$@" <"$T_TMP/in"; }
answer() { printf '%s\n' "$1" >"$T_TMP/in"; }
# only_calls PATTERN : the logged calls that match
only_calls() { grep -- "$1" "$CALLS" || true; }

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
  mf "$(it plugin:x plugin plugin '{"type":"plugin","plugin_id":"x","source":"https://e/x"}')"
  assert_status 0 run_apply "$T_TMP/m.json" --dry-run
  assert_contains "$T_OUT" "skipped   plugin:x (no apply stage"
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
