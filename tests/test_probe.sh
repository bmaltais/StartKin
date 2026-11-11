#!/usr/bin/env bash
# Scanning is read-only by default: no binary is executed unless probing is switched on (STARTKIN_PROBE=1 or
# `scan --probe`), and even then GUI-looking binaries are never run. Fixtures only; a marker file shows an exec.
# shellcheck disable=SC2031,SC2016,SC2329 # T_TMP is per-test; fixture bodies expand when they run; prov_* overrides are called indirectly
# shellcheck source=harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/provenance.sh
source "$ROOT/lib/provenance.sh"

# fixture BIN_NAME : a script that records that it ran, with its environment, then prints a version
fixture() {
  export HOME=$T_TMP/home
  mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications"
  FIX=$HOME/.local/bin/$1
  printf '#!/bin/sh\necho "ran DISPLAY=${DISPLAY:-unset} WAYLAND=${WAYLAND_DISPLAY:-unset}" >> "%s"\necho "tool 1.2.3"\n' "$T_TMP/marker" >"$FIX"
  chmod +x "$FIX"
  export STARTKIN_DESKTOP_DIRS=$HOME/.local/share/applications
  prov_is_elf() { [[ -f $1 ]]; }
  prov_needed() { echo libc.so.6; }
}

test_not_executed_by_default() {
  fixture cli
  unset STARTKIN_PROBE
  assert_eq "" "$(prov_probe "$FIX" --version)"
  [[ ! -e $T_TMP/marker ]] || t_fail "binary was executed without STARTKIN_PROBE=1"
  prov_trace "$FIX" cli
  [[ ! -e $T_TMP/marker ]] || t_fail "prov_trace executed the binary without STARTKIN_PROBE=1"
  assert_eq "" "$R_VERSION"
}

test_probe_runs_a_cli_with_a_clean_environment() {
  fixture cli
  export STARTKIN_PROBE=1 DISPLAY=:0 WAYLAND_DISPLAY=wayland-1
  assert_contains "$(prov_probe "$FIX" --version)" "tool 1.2.3"
  assert_eq "ran DISPLAY=unset WAYLAND=unset" "$(<"$T_TMP/marker")" "display variables must not reach the probe"
}

test_probe_skips_gui_by_library() {
  fixture guitool
  export STARTKIN_PROBE=1
  prov_needed() { printf 'libc.so.6\nlibwayland-client.so.0\n'; }
  assert_eq "" "$(prov_probe "$FIX" --version)"
  [[ ! -e $T_TMP/marker ]] || t_fail "GUI binary was executed"
}

test_probe_skips_binary_with_a_desktop_entry() {
  fixture launcher
  export STARTKIN_PROBE=1
  printf '[Desktop Entry]\nName=L\nExec=/usr/local/bin/launcher --flag %%U\n' >"$HOME/.local/share/applications/l.desktop"
  assert_eq "" "$(prov_probe "$FIX" --version)"
  [[ ! -e $T_TMP/marker ]] || t_fail "binary with a .desktop Exec was executed"
}

test_probe_skips_electron_app_dir() {
  fixture electronish
  export STARTKIN_PROBE=1
  mkdir -p "$HOME/.local/bin/resources"
  : >"$HOME/.local/bin/resources/app.asar"
  assert_eq "" "$(prov_probe "$FIX" --version)"
  [[ ! -e $T_TMP/marker ]] || t_fail "electron app was executed"
}

test_probe_skips_when_libraries_cannot_be_read() {
  fixture unknownlibs
  export STARTKIN_PROBE=1
  prov_needed() { return 1; }
  assert_eq "" "$(prov_probe "$FIX" --version)"
  [[ ! -e $T_TMP/marker ]] || t_fail "binary of unknown kind was executed"
}

test_probe_times_out_and_kills_the_group() {
  fixture slow
  export STARTKIN_PROBE=1
  printf '#!/bin/sh\n(sleep 29.7311; echo late >> "%s") &\nsleep 29.7311\n' "$T_TMP/late" >"$FIX"
  prov_probe "$FIX" --version >/dev/null
  sleep 0.2
  assert_eq "" "$(pgrep -f "sleep 29.7311" | head -n1)" "children outlive the timeout"
}

run_tests
