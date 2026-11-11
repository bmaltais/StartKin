#!/usr/bin/env bash
# shellcheck disable=SC2031 # T_TMP is set per test by the harness, in the test's own subshell
# shellcheck source=harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/scan/packages.sh
source "$ROOT/lib/scan/packages.sh"

# A fake machine: Omarchy ships base+hyprland+neovim+btop in its package lists and jq/git/hyprland as dependencies of
# omarchy-dev. The user added ripgrep (repo), libfoo (explicit, required by ripgrep), aurtool (foreign).
setup_machine() {
  mkdir -p "$T_TMP/omarchy/install"
  printf '# core\n\nbase\nhyprland\n  \n# c\nneovim\n' >"$T_TMP/omarchy/install/omarchy-base.packages"
  printf '# other\nbtop\n' >"$T_TMP/omarchy/install/omarchy-other.packages"
  export STARTKIN_OMARCHY_DIR=$T_TMP/omarchy
  # shellcheck disable=SC2016 # the stub body expands when it runs
  stub pacman '
case "$*" in
  "-Qq") printf "omarchy-dev\nomarchy-settings-dev\nripgrep\n" ;;
  "-Q omarchy") exit 1 ;;
  "-Q omarchy-dev") echo "omarchy-dev 4.0.0-1" ;;
  "-Qi omarchy-dev omarchy-settings-dev")
    printf "Name            : omarchy-dev\nDepends On      : jq  git>=2  hyprland\n\nName            : omarchy-settings-dev\nDepends On      : None\n" ;;
  "-Qei")
    printf "Name            : base\nVersion         : 3-1\nRequired By     : None\n\n"
    printf "Name            : git\nVersion         : 2.50-1\nRequired By     : None\n\n"
    printf "Name            : omarchy-dev\nVersion         : 4.0.0-1\nRequired By     : None\n\n"
    printf "Name            : ripgrep\nVersion         : 14.1-1\nRequired By     : None\n\n"
    printf "Name            : libfoo\nVersion         : 1.2-3\nRequired By     : ripgrep  bar\n                  baz\n\n"
    printf "Name            : aurtool\nVersion         : 0.9-1\nRequired By     : None\n" ;;
  "-Qemq") echo aurtool ;;
  "-Sl") printf "core base 3-1\nextra ripgrep 14.1-1 [installed]\nextra libfoo 1.2-3 [installed]\nextra git 2.50-1\n" ;;
  *) echo "unexpected pacman $*" >&2; exit 1 ;;
esac'
  stub paru 'exit 0'
}

test_excludes_omarchy_set_and_adds_user_packages() {
  setup_machine
  local j
  j=$(scan_packages)
  assert_json_eq 'map(.name) | sort' '["aurtool","libfoo","ripgrep"]' "$j"
}

test_repo_package_item() {
  setup_machine
  local j
  j=$(scan_packages)
  assert_json_eq '.[] | select(.name=="ripgrep") | [.id,.kind,.category,.risk,.version,.private]' \
    '["pacman:ripgrep","other","package","low","14.1-1",false]' "$j"
  assert_json_eq '.[] | select(.name=="ripgrep") | .install' '{"type":"pacman","package":"ripgrep","repo":"extra"}' "$j"
  assert_json_eq '.[] | select(.name=="ripgrep") | .provenance.method' '"package-manager"' "$j"
  assert_contains "$(jq -r '.[] | select(.name=="ripgrep") | .provenance.evidence | join("|")' <<<"$j")" "omarchy-dev 4.0.0-1"
}

test_aur_package_item() {
  setup_machine
  local j
  j=$(scan_packages)
  assert_json_eq '.[] | select(.name=="aurtool") | .id' '"aur:aurtool"' "$j"
  assert_json_eq '.[] | select(.name=="aurtool") | .install' '{"type":"aur","package":"aurtool","helper":"paru"}' "$j"
  assert_json_eq '.[] | select(.name=="aurtool") | .risk' '"medium"' "$j"
}

test_dependency_only_packages_are_libraries() {
  setup_machine
  local j
  j=$(scan_packages)
  assert_json_eq '.[] | select(.name=="libfoo") | .kind' '"library"' "$j"
  assert_contains "$(jq -r '.[] | select(.name=="libfoo") | .provenance.evidence | join("|")' <<<"$j")" "required by: ripgrep, bar, baz"
}

test_no_omarchy_package_means_unknown_baseline() {
  setup_machine
  stub pacman 'case "$*" in "-Qei") printf "Name : zzz\nVersion : 1-1\nRequired By : None\n" ;; "-Q "*) exit 1 ;; esac'
  local j
  j=$(scan_packages 2>"$T_TMP/err")
  assert_json_eq 'map(.name)' '["zzz"]' "$j"
  assert_contains "$(<"$T_TMP/err")" "no omarchy package"
}

test_huge_baseline_does_not_hit_argv_limit() {
  setup_machine
  # a baseline list over 128 KB (the per-argument limit)
  seq 1 20000 | sed 's/^/some-baseline-package-/' >>"$T_TMP/omarchy/install/omarchy-other.packages"
  local j
  j=$(scan_packages 2>&1)
  assert_json_eq 'map(.name) | sort' '["aurtool","libfoo","ripgrep"]' "$j"
}

test_output_validates() {
  setup_machine
  local j
  j=$(scan_packages)
  jq -n --argjson items "$j" \
    '{schema_version: "1.0", machine: {hostname: "h", omarchy_version: "1", arch: "x86_64", gpu: [], form_factor: "desktop"}, items: $items}' \
    >"$T_TMP/m.json"
  assert_status 0 "$ROOT/scripts/validate-manifest" "$T_TMP/m.json"
}

test_empty_when_pacman_missing() {
  ln -s "$(command -v rm)" "$T_BIN/rm" # the harness cleanup needs rm
  PATH=$T_BIN
  assert_eq '[]' "$(scan_packages 2>/dev/null)"
}

run_tests
