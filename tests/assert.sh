#!/usr/bin/env bash
# Tiny assert helper for the plain-bash test runner (see docs/engine.md). Sourced via tests/harness.sh.
# shellcheck shell=bash

T_FAILS=0
T_OUT="" T_ERR=""
export T_OUT T_ERR

t_fail() { T_FAILS=$((T_FAILS + 1)); printf '    FAIL: %s\n' "$*" >&2; }

# assert_eq EXPECTED ACTUAL [MESSAGE]
assert_eq() {
  [[ $1 == "$2" ]] || t_fail "${3:-assert_eq}: expected [$1] got [$2]"
}

# assert_contains HAYSTACK NEEDLE [MESSAGE]
assert_contains() {
  [[ $1 == *"$2"* ]] || t_fail "${3:-assert_contains}: [$2] not in [$1]"
}

# assert_status EXPECTED_CODE COMMAND... : runs the command; stdout/stderr land in $T_OUT / $T_ERR
assert_status() {
  local want=$1 got ofile efile
  shift
  ofile=$(mktemp) efile=$(mktemp)
  "$@" >"$ofile" 2>"$efile"
  got=$?
  T_OUT=$(<"$ofile") T_ERR=$(<"$efile")
  rm -f "$ofile" "$efile"
  [[ $got == "$want" ]] || t_fail "assert_status: [$*] exited $got, wanted $want (stderr: $T_ERR)"
}

# assert_json_eq JQ_FILTER EXPECTED JSON [MESSAGE]
assert_json_eq() {
  local got
  if ! got=$(jq -c "$1" <<<"$3" 2>&1); then
    t_fail "${4:-assert_json_eq}: invalid JSON or filter: $got"
    return
  fi
  [[ $got == "$2" ]] || t_fail "${4:-assert_json_eq}: $1 expected [$2] got [$got]"
}
