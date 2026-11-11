#!/usr/bin/env bash
# Shared helpers for the apply tests (test_apply.sh, test_apply_files.sh). Every installer is a stub that logs its argv
# and, for package managers, records the result in $STATE: nothing is ever really installed, no window is opened, and
# HOME is a temp dir.
# shellcheck disable=SC2031,SC2016 # T_TMP is per test; stub bodies expand when they run
# shellcheck source=harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
BIN=$ROOT/bin/startkin

setup() {
  export HOME=$T_TMP/home STARTKIN_NO_GUM=1 STARTKIN_SRC_DIR=$T_TMP/src STARTKIN_DMI_DIR=$T_TMP/dmi
  export STARTKIN_STATE_DIR=$T_TMP/state STARTKIN_PLUGINS_DIR=$HOME/.config/omarchy/plugins
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
  # systemctl never touches a real manager: it logs, and "is-enabled" answers from $T_TMP/enabled.
  stub systemctl 'echo "systemctl $*" >>"$CALLS"
case " $* " in
  *" is-enabled "*) grep -qxF -- "${*: -1}" "$T_TMP/enabled" 2>/dev/null ;;
  *" enable "*) printf "%s\n" "${*: -1}" >>"$T_TMP/enabled" ;;
esac'
  stub sudo 'echo "sudo $*" >>"$CALLS"; exec "$@"'
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
