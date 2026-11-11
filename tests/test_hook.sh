#!/usr/bin/env bash
# shellcheck disable=SC2031 # T_TMP is set per test by the harness, in the test's own subshell
# shellcheck source=harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

test_install_hook() {
  git init -q "$T_TMP/r"
  mkdir -p "$T_TMP/r/scripts"
  cp "$ROOT/scripts/install-hooks" "$T_TMP/r/scripts/"
  # shellcheck disable=SC2016 # $1 expands in the inner bash
  assert_status 0 bash -c 'cd "$1" && scripts/install-hooks' _ "$T_TMP/r"
  assert_eq ".githooks" "$(git -C "$T_TMP/r" config core.hooksPath)"
  [[ -x $T_TMP/r/.githooks/pre-commit ]] || t_fail "hook not executable"
  assert_contains "$(<"$T_TMP/r/.githooks/pre-commit")" "check"
}

run_tests
