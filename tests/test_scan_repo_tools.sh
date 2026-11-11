#!/usr/bin/env bash
# Tests for lib/scan/repo-tools.sh: fixture dirs and fake binaries only, never this machine's real files.
# shellcheck disable=SC2031,SC2016,SC2329 # T_TMP is per-test; stub bodies expand when they run; prov_* overrides are called by the scanner
# shellcheck source=harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/scan/repo-tools.sh
source "$ROOT/lib/scan/repo-tools.sh"

# setup : fixture HOME, empty dirs, and stubs so nothing real is consulted
setup() {
  export HOME=$T_TMP/home
  BIN=$HOME/.local/bin SHARE=$HOME/.local/share ROOTS=$HOME/src PLUG=$HOME/.config/omarchy/plugins
  mkdir -p "$BIN" "$SHARE" "$ROOTS" "$PLUG"
  export STARTKIN_BIN_DIRS=$BIN STARTKIN_APP_DIRS=$SHARE STARTKIN_GIT_ROOTS=$ROOTS
  export STARTKIN_PLUGIN_DIR=$PLUG STARTKIN_HISTORY_FILES=$HOME/.history
  export STARTKIN_REGISTRY_DIRS=$SHARE/uv:$SHARE/mise
  stub pacman 'exit 1'
  stub go 'exit 1'
  stub strings 'exit 0'
  # Fake binaries start with "ELF" instead of the real magic so the bash stubs below can stand in for exec.
  prov_is_elf() { [[ -f $1 && $(head -c3 -- "$1") == ELF ]]; }
  prov_probe() { return 0; }
}

# fake_elf PATH [BODY] : an "ELF" test binary
fake_elf() { printf 'ELF fake binary\n%s\n' "${2:-}" >"$1"; chmod +x "$1"; }

# clone DIR URL : a git repo with an origin and one commit
clone() {
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" remote add origin "$2"
  git -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
}

item() { jq -c --arg n "$1" '.[] | select(.name == $n)' <<<"$2"; }

test_empty() {
  setup
  assert_eq '[]' "$(scan_repo_tools)"
}

test_skips_backups_hidden_and_package_owned() {
  setup
  fake_elf "$BIN/tool.prev"
  fake_elf "$BIN/.hidden-rollback"
  fake_elf "$BIN/owned"
  fake_elf "$BIN/mine"
  stub pacman '[[ $1 == -Qo && $3 == */owned ]]'
  out=$(scan_repo_tools)
  assert_eq '["mine"]' "$(jq -c 'map(.name)' <<<"$out")"
}

test_skips_link_to_package_owned_target() {
  setup
  mkdir -p "$T_TMP/usr"
  fake_elf "$T_TMP/usr/sw"
  ln -s "$T_TMP/usr/sw" "$BIN/sw"
  stub pacman '[[ $1 == -Qo && $3 == */usr/sw ]]'
  assert_eq '[]' "$(scan_repo_tools)"
}

test_skips_links_into_plugins_dir() {
  setup
  mkdir -p "$PLUG/io.x.plug/bin" "$T_TMP/dev/Plug/bin"
  fake_elf "$T_TMP/dev/Plug/bin/plug"
  ln -s "$T_TMP/dev/Plug" "$PLUG/devplug" # the plugin dir itself is a symlink to a checkout
  ln -s "$PLUG/devplug/bin/plug" "$BIN/plug"
  fake_elf "$PLUG/io.x.plug/bin/real"
  ln -s "$PLUG/io.x.plug/bin/real" "$BIN/real"
  assert_eq '[]' "$(scan_repo_tools)"
}

test_plugin_dir_is_configurable() {
  setup
  mkdir -p "$T_TMP/elsewhere"
  fake_elf "$T_TMP/elsewhere/p"
  ln -s "$T_TMP/elsewhere/p" "$BIN/p"
  assert_eq 1 "$(scan_repo_tools | jq length)" "reported when not a plugin path"
  assert_eq '[]' "$(STARTKIN_PLUGIN_DIR=$T_TMP/elsewhere scan_repo_tools)"
}

test_skips_links_into_registry_dirs() {
  setup
  mkdir -p "$SHARE/uv/python/bin"
  fake_elf "$SHARE/uv/python/bin/python3.12"
  ln -s "$SHARE/uv/python/bin/python3.12" "$BIN/python3.12"
  assert_eq '[]' "$(scan_repo_tools)"
}

test_go_binary_exact() {
  setup
  fake_elf "$BIN/skillpack"
  stub go 'printf "%s\n" "$3: go1.25" "	path	github.com/bmaltais/skillpack/cmd/skillpack" "	mod	github.com/bmaltais/skillpack	v0.0.0-20261108012502-e00a5187616a	"'
  prov_probe() { [[ $2 == --version ]] && echo "skillpack version v20261108-e00a518"; return 0; }
  out=$(item skillpack "$(scan_repo_tools)")
  assert_json_eq '.provenance.method' '"build-metadata"' "$out"
  assert_json_eq '.provenance.confidence' '0.95' "$out"
  assert_json_eq '.install' '{"type":"go","module":"github.com/bmaltais/skillpack/cmd/skillpack"}' "$out"
  assert_json_eq '.version' '"v20261108-e00a518"' "$out"
  assert_json_eq '.category' '"repo-tool"' "$out"
  assert_json_eq '.private' 'false' "$out"
}

test_symlink_into_clone() {
  setup
  clone "$ROOTS/oma-cast" https://x@github.com/me/oma-cast.git
  mkdir -p "$ROOTS/oma-cast/bin"
  printf '#!/bin/sh\n' >"$ROOTS/oma-cast/bin/oma-cast"
  chmod +x "$ROOTS/oma-cast/bin/oma-cast"
  ln -s "$ROOTS/oma-cast/bin/oma-cast" "$BIN/oma-cast"
  head=$(git -C "$ROOTS/oma-cast" rev-parse HEAD)
  out=$(item oma-cast "$(scan_repo_tools)")
  assert_json_eq '.provenance.method' '"adjacent-evidence"' "$out"
  assert_json_eq '.install' "{\"type\":\"git-build\",\"url\":\"https://github.com/me/oma-cast.git\",\"ref\":\"$head\"}" "$out" "credentials stripped, HEAD recorded"
}

test_rust_workspace_hint_finds_differently_named_clone() {
  setup
  clone "$ROOTS/Mono" https://github.com/me/Mono.git
  mkdir -p "$ROOTS/Mono/crates/startfs"
  fake_elf "$BIN/startfs"
  stub strings 'echo "crates/startfs/src/quic.rs"'
  prov_probe() { [[ $2 == --version ]] && echo "startfs 1.18.3 (protocol 21)"; return 0; }
  out=$(item startfs "$(scan_repo_tools)")
  assert_json_eq '.provenance.method' '"build-metadata"' "$out"
  assert_json_eq '.install.url' '"https://github.com/me/Mono.git"' "$out"
  assert_json_eq '.version' '"1.18.3"' "$out"
}

test_sibling_install_script_names_repo() {
  setup
  fake_elf "$BIN/startfs"
  mkdir -p "$SHARE/startfs"
  printf '# curl -fsSL https://raw.githubusercontent.com/me/StartFS/main/scripts/install.sh | sh\nrepo=me/StartFS\n' >"$SHARE/startfs/install.sh"
  out=$(item startfs "$(scan_repo_tools)")
  assert_json_eq '.provenance.method' '"adjacent-evidence"' "$out"
  assert_json_eq '.install' '{"type":"script","url":"https://raw.githubusercontent.com/me/StartFS/main/scripts/install.sh","interpreter":"sh"}' "$out"
  assert_json_eq 'length' '1' "$(scan_repo_tools)" "the data dir is not reported twice"
}

test_help_url() {
  setup
  fake_elf "$BIN/foo"
  prov_probe() { [[ $2 == --help ]] && echo "Docs: https://github.com/acme/foo-cli."; return 0; }
  out=$(item foo "$(scan_repo_tools)")
  assert_json_eq '.provenance.method' '"version-flag"' "$out"
  assert_json_eq '.install.url' '"https://github.com/acme/foo-cli"' "$out"
}

test_name_match_clone_is_name_search() {
  setup
  clone "$ROOTS/Widget" https://github.com/me/widget.git
  fake_elf "$BIN/widget"
  out=$(item widget "$(scan_repo_tools)")
  assert_json_eq '.provenance.method' '"name-search"' "$out"
  assert_json_eq '.risk' '"medium"' "$out"
}

test_strings_url_needs_exactly_one_clone() {
  setup
  clone "$ROOTS/a" https://github.com/me/alpha.git
  clone "$ROOTS/b" https://github.com/me/beta.git
  fake_elf "$BIN/one" ONE
  fake_elf "$BIN/two" TWO
  stub strings 'if grep -q ONE; then echo "see github.com/me/alpha for docs"; else printf "github.com/me/alpha\ngithub.com/me/beta\n"; fi'
  all=$(scan_repo_tools)
  assert_json_eq '.provenance.method' '"build-metadata"' "$(item one "$all")"
  assert_json_eq '.provenance.confidence' '0.5' "$(item one "$all")"
  assert_json_eq '.provenance.method' '"none"' "$(item two "$all")" "two matches is ambiguous"
}

test_mise_wrapper_script() {
  setup
  printf '#!/bin/bash\nexec mise x "npm:@moonshot-ai/kimi-code" -- "kimi" "$@"\n' >"$BIN/kimi"
  chmod +x "$BIN/kimi"
  out=$(item kimi "$(scan_repo_tools)")
  assert_json_eq '.install' '{"type":"mise","tool":"npm:@moonshot-ai/kimi-code","backend":"npm"}' "$out"
  assert_json_eq '.kind' '"script"' "$out"
}

test_history_without_secrets() {
  setup
  fake_elf "$BIN/foo"
  fake_elf "$BIN/bar"
  printf 'ls\ngit clone https://user:pw@github.com/me/foo.git ~/x\ngit clone https://ghp_abc@github.com/me/bar.git\n' >"$HOME/.history"
  all=$(scan_repo_tools)
  foo=$(item foo "$all")
  assert_json_eq '.provenance.method' '"shell-history"' "$foo"
  assert_json_eq '.install.url' '"https://github.com/me/foo.git"' "$foo" "credentials stripped"
  assert_eq 0 "$(grep -c 'pw@' <<<"$foo")" "no password in evidence"
  assert_json_eq '.provenance.method' '"none"' "$(item bar "$all")" "lines that look secret are ignored"
}

test_history_evidence_is_only_the_derived_fact() {
  setup
  fake_elf "$BIN/foo"
  fake_elf "$BIN/rg3"
  fake_elf "$BIN/sshy"
  # secrets-policy rule 3: raw command lines (and anything riding on them) never reach the manifest
  printf 'git clone https://github.com/me/foo.git ~/x # AKIAIOSFODNN7EXAMPLE\ncargo install rg3 --registry-key=Zk3jQ9xLm2Vb8Nc4Rt7Ws1Yp5Qa6\ngit clone git@github.com:me/sshy.git --depth 1 ZZtopQ7xV9mK2\n' >"$HOME/.history"
  all=$(scan_repo_tools)
  assert_json_eq '.[] | select(.name=="foo") | .provenance.evidence | map(select(startswith("installed via")))' \
    '["installed via shell history: git clone https://github.com/me/foo.git"]' "$all"
  assert_json_eq '.[] | select(.name=="rg3") | .provenance.evidence | map(select(startswith("installed via")))' \
    '["installed via shell history: cargo install"]' "$all"
  assert_json_eq '.[] | select(.name=="sshy") | .provenance.evidence | map(select(startswith("installed via")))' \
    '["installed via shell history: git clone"]' "$all" "a non-https remote is not echoed"
  for s in AKIAIOSFODNN7EXAMPLE Zk3jQ9xLm2Vb8Nc4Rt7Ws1Yp5Qa6 ZZtopQ7xV9mK2 "--depth"; do
    assert_eq 0 "$(grep -cF -- "$s" <<<"$all")" "[$s] leaked"
  done
}

test_history_cargo_is_not_mistaken_for_go() {
  setup
  fake_elf "$BIN/rg2"
  printf 'cargo install rg2\n' >"$HOME/.history"
  assert_json_eq '.[0].install' '{"type":"cargo","crate":"rg2"}' "$(scan_repo_tools)"
}

test_history_url_must_relate_to_the_name() {
  setup
  fake_elf "$BIN/foo"
  printf 'git clone https://github.com/other/unrelated/issues/5 foo\ngit clone https://github.com/foo-org/foo/issues/5\n' >"$HOME/.history"
  assert_json_eq '.[0].provenance.method' '"none"' "$(scan_repo_tools)"
}

test_app_dir_with_only_desktop_files_is_not_an_app() {
  setup
  mkdir -p "$SHARE/applications"
  printf '[Desktop Entry]\n' >"$SHARE/applications/x.desktop"
  chmod +x "$SHARE/applications/x.desktop"
  assert_eq '[]' "$(scan_repo_tools)"
}

test_report_counts_methods() {
  setup
  clone "$ROOTS/oma-cast" https://github.com/me/oma-cast.git
  mkdir -p "$ROOTS/oma-cast/bin"
  printf '#!/bin/sh\n' >"$ROOTS/oma-cast/bin/oma-cast"
  chmod +x "$ROOTS/oma-cast/bin/oma-cast"
  ln -s "$ROOTS/oma-cast/bin/oma-cast" "$BIN/oma-cast"
  clone "$ROOTS/Widget" https://github.com/me/widget.git
  fake_elf "$BIN/widget"
  fake_elf "$BIN/mystery"
  out=$(scan_repo_tools | prov_report)
  assert_contains "$out" "items 3: exact 1, heuristic 1, unknown 1"
  assert_contains "$out" "name-search: 1"
}

test_untraced_is_unknown() {
  setup
  fake_elf "$BIN/mystery"
  out=$(item mystery "$(scan_repo_tools)")
  assert_json_eq '.provenance' '{"method":"none","confidence":0,"evidence":["found in ~/.local/bin"]}' "$out"
  assert_json_eq '.install' "{\"type\":\"unknown\",\"path\":\"~/.local/bin/mystery\"}" "$out"
  assert_json_eq '.version' 'null' "$out"
}

test_appimage_link_hint() {
  setup
  mkdir -p "$SHARE/appimages"
  fake_elf "$SHARE/appimages/voice.AppImage"
  ln -s "$SHARE/appimages/voice.AppImage" "$BIN/voice"
  all=$(scan_repo_tools)
  assert_json_eq '.install.hint' '"AppImage"' "$(item voice "$all")"
  assert_json_eq '.kind' '"gui-app"' "$(item voice "$all")"
  assert_json_eq 'map(.name)' '["voice"]' "$all" "the AppImage in the app dir is not a second item"
}

test_app_dir_linked_from_bin_reported_once() {
  setup
  mkdir -p "$SHARE/herdr-app" "$SHARE/icons"
  fake_elf "$SHARE/herdr-app/herdr-app"
  : >"$SHARE/herdr-app/LICENSE"
  : >"$SHARE/icons/x.png"
  ln -s "$SHARE/herdr-app/herdr-app" "$BIN/herdr-app"
  assert_json_eq 'map(.name)' '["herdr-app"]' "$(scan_repo_tools)"
}

test_app_dir_without_link_is_reported() {
  setup
  mkdir -p "$SHARE/lonely"
  fake_elf "$SHARE/lonely/lonely"
  all=$(scan_repo_tools)
  assert_json_eq '.[0].kind' '"other"' "$all"
  assert_json_eq '.[0].install.path' "\"~/.local/share/lonely\"" "$all"
}

test_git_roots_env_overrides_default() {
  setup
  clone "$T_TMP/other/gadget" https://github.com/me/gadget.git
  fake_elf "$BIN/gadget"
  assert_json_eq '.[0].provenance.method' '"none"' "$(scan_repo_tools)" "not found in the default root"
  assert_json_eq '.[0].provenance.method' '"name-search"' "$(STARTKIN_GIT_ROOTS=$T_TMP/other:$ROOTS scan_repo_tools)"
}

test_clones_in_hidden_dirs_ignored() {
  setup
  clone "$ROOTS/.claude/worktrees/widget" https://github.com/me/widget.git
  fake_elf "$BIN/widget"
  assert_json_eq '.[0].provenance.method' '"none"' "$(scan_repo_tools)"
}

test_duplicate_names_get_unique_ids() {
  setup
  mkdir -p "$T_TMP/usr-local"
  fake_elf "$BIN/dup"
  fake_elf "$T_TMP/usr-local/dup"
  assert_json_eq 'map(.id) | unique | length' '2' "$(STARTKIN_BIN_DIRS=$BIN:$T_TMP/usr-local scan_repo_tools)"
}

test_output_validates_against_schema() {
  setup
  clone "$ROOTS/oma-cast" https://github.com/me/oma-cast.git
  mkdir -p "$ROOTS/oma-cast/bin"
  printf '#!/bin/sh\n' >"$ROOTS/oma-cast/bin/oma-cast"
  chmod +x "$ROOTS/oma-cast/bin/oma-cast"
  ln -s "$ROOTS/oma-cast/bin/oma-cast" "$BIN/oma-cast"
  fake_elf "$BIN/mystery"
  fake_elf "$BIN/sp"
  stub go 'printf "\tpath\tgithub.com/me/sp/cmd/sp\n"'
  mkdir -p "$SHARE/appimages"
  fake_elf "$SHARE/appimages/v.AppImage"
  ln -s "$SHARE/appimages/v.AppImage" "$BIN/v"
  jq -n --argjson items "$(scan_repo_tools)" \
    '{schema_version: "1.0", machine: {hostname: "h", omarchy_version: "3", arch: "x86_64", gpu: [], form_factor: "desktop"}, items: $items}' \
    >"$T_TMP/m.json"
  assert_eq 4 "$(jq '.items | length' "$T_TMP/m.json")"
  "$ROOT/scripts/validate-manifest" "$T_TMP/m.json" >"$T_TMP/v.out" 2>&1
  rc=$?
  if ((rc == 2)); then
    echo "    skip: no schema validator available ($(head -n1 "$T_TMP/v.out"))" >&2
  else
    assert_eq 0 "$rc" "manifest validates: $(cat "$T_TMP/v.out")"
  fi
}

run_tests
