#!/usr/bin/env bash
# Interactive prompts: gum when it is installed and stdin/stdout are a terminal, plain `read` otherwise.
# Prompts go to stderr; chosen values go to stdout. STARTKIN_NO_GUM=1 forces the plain path. Source this.
# shellcheck shell=bash

# ui_gum_ok : true when gum should be used
ui_gum_ok() { [[ ${STARTKIN_NO_GUM:-0} != 1 ]] && command -v gum >/dev/null 2>&1 && [[ -t 0 && -t 1 ]]; }

# ui_confirm PROMPT : true on yes; end of input counts as no
ui_confirm() {
  local ans
  if ui_gum_ok; then gum confirm "$1"; return; fi
  printf '%s [y/N] ' "$1" >&2
  read -r ans || { echo >&2; return 1; }
  [[ ${ans,,} == y || ${ans,,} == yes ]]
}

# ui_input PROMPT : print one line of input (may be empty); false at end of input
ui_input() {
  local ans
  if ui_gum_ok; then gum input --placeholder "$1"; return; fi
  printf '%s: ' "$1" >&2
  read -r ans || return 1
  printf '%s\n' "$ans"
}

# ui_choose PROMPT OPTION... : print the chosen option; the plain path takes its number or its text. False at end of input.
ui_choose() {
  local prompt=$1 ans i o
  shift
  if ui_gum_ok; then gum choose --header "$prompt" "$@"; return; fi
  while :; do
    printf '%s\n' "$prompt" >&2
    i=1
    for o in "$@"; do printf '  %d) %s\n' "$i" "$o" >&2; i=$((i + 1)); done
    printf '> ' >&2
    read -r ans || { echo >&2; return 1; }
    i=1
    for o in "$@"; do
      if [[ $ans == "$i" || $ans == "$o" ]]; then printf '%s\n' "$o"; return 0; fi
      i=$((i + 1))
    done
    printf 'not an option: %s\n' "$ans" >&2
  done
}
