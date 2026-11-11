#!/usr/bin/env bash
# Shared helpers. Source this; it has no side effects beyond defining functions and STARTKIN_ROOT.
# shellcheck shell=bash

STARTKIN_ROOT=${STARTKIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}

# tilde_path PATH : PATH with a leading $HOME shortened to ~ (manifests and messages must not leak the user name;
# `apply` expands the ~ again, docs/manifest.md)
tilde_path() {
  local p=$1
  if ((${#HOME} > 1)) && [[ $p == "$HOME" || $p == "$HOME"/* ]]; then p="~${p#"$HOME"}"; fi
  printf '%s' "$p"
}

# tilde_text TEXT : TEXT with every "$HOME/" shortened to "~/" (for messages that embed paths)
tilde_text() {
  local t=$1 tl='~'
  if ((${#HOME} > 1)); then t=${t//"$HOME"\//"$tl"/}; fi
  printf '%s' "$t"
}

# log MSG... : diagnostic to stderr (stdout is reserved for data)
log() { printf 'startkin: %s\n' "$(tilde_text "$*")" >&2; }

# warn MSG... : same, flagged
warn() { printf 'startkin: warning: %s\n' "$(tilde_text "$*")" >&2; }

# die [-c CODE] MSG... : print and exit (default code 1)
die() {
  local code=1
  if [[ ${1:-} == -c ]]; then code=$2; shift 2; fi
  printf 'startkin: %s\n' "$(tilde_text "$*")" >&2
  exit "$code"
}

# require_cmd NAME... : die with a pointer to the package when a tool is missing
require_cmd() {
  local c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "required tool not found: $c"; done
}

# version : the engine version (from the VERSION file)
version() { tr -d '[:space:]' <"$STARTKIN_ROOT/VERSION"; }

# now_utc : ISO 8601 UTC timestamp, second precision
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
