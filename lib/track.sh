#!/usr/bin/env bash
# `startkin track install METHOD SPEC`: run a real install and record source, version, method and date in the
# registry (docs/adopt.md). Methods: cargo go npm uv pipx git-build. pacman is excluded (use `omarchy pkg add`).
#   STARTKIN_SRC_DIR  where git-build clones (default ~/.local/src)
# Needs lib/common.sh, lib/registry.sh, lib/ui.sh, lib/adopt.sh (adopt_url_ok). Source this.
# shellcheck shell=bash

TRACK_USAGE='Usage: startkin track install METHOD SPEC [--dry-run] [--yes] [--id ITEM_ID]
  METHOD  cargo CRATE[@VER] | go MODULE[@VER] | npm PKG[@VER] | uv PKG[==VER] | pipx PKG[==VER]
          git-build URL --build CMD [--build CMD]... [--ref REF]
  --dry-run  show the commands and what would be recorded; run nothing
  --yes      do not ask before running'

# Results of track_plan.
TRACK_CMDS=() TRACK_INSTALL="" TRACK_ID="" TRACK_NAME="" TRACK_VER=""

# track_q ARG... : the arguments as one shell-safe line
track_q() { local o="" a; for a in "$@"; do o+="$(printf '%q' "$a") "; done; printf '%s' "${o% }"; }

# track_plan METHOD SPEC REF ID [BUILD...] : fill the TRACK_* results; 2 (message on stderr) for a bad request
track_plan() {
  local method=$1 spec=$2 ref=$3 id=$4 dir url builds mod b
  shift 4
  TRACK_CMDS=() TRACK_VER=""
  if [[ -z $spec || $spec == -* || $spec == *[[:space:]]* ]]; then warn "track: bad spec: '$spec'"; return 2; fi
  case $method in
    cargo)
      TRACK_NAME=${spec%%@*}
      [[ $spec == *@* ]] && TRACK_VER=${spec#*@}
      TRACK_CMDS=("$(track_q cargo install --locked "$spec")")
      TRACK_INSTALL=$(jq -nc --arg c "$TRACK_NAME" '{type: "cargo", crate: $c, locked: true}')
      ;;
    go)
      mod=${spec%@*}
      [[ $spec == *@* ]] && TRACK_VER=${spec##*@}
      [[ $TRACK_VER == latest ]] && TRACK_VER=""
      TRACK_NAME=${mod##*/}
      TRACK_CMDS=("$(track_q go install "$mod@${TRACK_VER:-latest}")")
      TRACK_INSTALL=$(jq -nc --arg m "$mod" '{type: "go", module: $m}')
      ;;
    npm)
      TRACK_NAME=$(sed -E 's/^(.+)@[^@/]*$/\1/' <<<"$spec")
      [[ $TRACK_NAME != "$spec" ]] && TRACK_VER=${spec##*@}
      TRACK_CMDS=("$(track_q npm install -g "$spec")")
      TRACK_INSTALL=$(jq -nc --arg p "$TRACK_NAME" '{type: "npm", package: $p}')
      ;;
    uv | pipx)
      TRACK_NAME=${spec%%[=<>~!]*}
      [[ $spec == *==* ]] && TRACK_VER=${spec#*==}
      if [[ $method == uv ]]; then TRACK_CMDS=("$(track_q uv tool install "$spec")"); else TRACK_CMDS=("$(track_q pipx install "$spec")"); fi
      TRACK_INSTALL=$(jq -nc --arg t "$method" --arg p "$TRACK_NAME" '{type: $t, package: $p}')
      ;;
    git-build)
      adopt_url_ok "$spec" 'https?://|ssh://|git@|git://' || { warn "track: not a git URL: $spec"; return 2; }
      (($# > 0)) || { warn "track: git-build needs at least one --build CMD"; return 2; }
      url=$(prov_clean_url "$spec")
      TRACK_NAME=$(basename -- "${url%.git}")
      dir=${STARTKIN_SRC_DIR:-$HOME/.local/src}/$TRACK_NAME
      if [[ -d $dir/.git ]]; then TRACK_CMDS=("$(track_q git -C "$dir" fetch --tags)"); else TRACK_CMDS=("$(track_q git clone "$url" "$dir")"); fi
      [[ -n $ref ]] && TRACK_CMDS+=("$(track_q git -C "$dir" checkout "$ref")")
      for b in "$@"; do TRACK_CMDS+=("cd $(track_q "$dir") && $b"); done
      builds=$(printf '%s\n' "$@" | jq -R . | jq -sc .)
      TRACK_INSTALL=$(jq -nc --arg u "$url" --arg r "$ref" --argjson b "$builds" \
        '{type: "git-build", url: $u} + (if $r != "" then {ref: $r} else {} end) + {build: $b}')
      ;;
    pacman | aur) warn "track: $method installs are not tracked here; use omarchy pkg add (docs/omarchy-plugins.md)"; return 2 ;;
    *) warn "track: unknown method '$method' (cargo go npm uv pipx git-build)"; return 2 ;;
  esac
  if [[ -z $id ]]; then
    if [[ $method == git-build ]]; then id="track:git-build:$TRACK_NAME"; else id="$method:$TRACK_NAME"; fi
  fi
  TRACK_ID=$id
}

# track_version METHOD DIRNAME : best-effort installed version after a successful run (empty when unknown)
track_version() {
  case $1 in
    cargo) cargo install --list 2>/dev/null | sed -nE "s/^$2 v([^ :]+).*/\1/p" | head -n1 ;;
    git-build) git -C "${STARTKIN_SRC_DIR:-$HOME/.local/src}/$2" rev-parse --short HEAD 2>/dev/null ;;
  esac
  return 0
}

# cmd_track ARGS... : the subcommand
cmd_track() {
  local sub=${1:-} method spec ref="" id="" dry=0 yes=0 c rc
  local -a builds=()
  case $sub in
    -h | --help) echo "$TRACK_USAGE"; return 0 ;;
    install) shift ;;
    "") echo "$TRACK_USAGE" >&2; return 2 ;;
    *) die -c 2 "track: unknown subcommand: $sub" ;;
  esac
  method=${1:-} spec=${2:-}
  (($# >= 2)) || { echo "$TRACK_USAGE" >&2; return 2; }
  shift 2
  while (($#)); do
    case $1 in
      --dry-run) dry=1 ;;
      --yes | -y) yes=1 ;;
      --ref | --build | --id)
        (($# >= 2)) || die -c 2 "track: $1 needs a value"
        case $1 in --ref) ref=$2 ;; --build) builds+=("$2") ;; --id) id=$2 ;; esac
        shift ;;
      *) die -c 2 "track: unknown option: $1" ;;
    esac
    shift
  done
  require_cmd jq
  track_plan "$method" "$spec" "$ref" "$id" "${builds[@]}" || return 2

  echo "Will run:"
  for c in "${TRACK_CMDS[@]}"; do echo "  \$ $c"; done
  echo "Will record: $TRACK_ID ($method${TRACK_VER:+ $TRACK_VER}) in $(registry_file)"
  ((dry)) && { echo "(dry run: nothing executed)"; return 0; }
  if ((!yes)) && ! ui_confirm "Run this?"; then
    log "aborted: nothing was run"
    return 1
  fi
  for c in "${TRACK_CMDS[@]}"; do
    bash -c "$c" && continue
    rc=$?
    log "install failed (exit $rc): $c; nothing recorded"
    return 1
  done
  [[ -n $TRACK_VER ]] || TRACK_VER=$(track_version "$method" "$TRACK_NAME")
  registry_put "$TRACK_ID" "$TRACK_INSTALL" "$TRACK_VER" track || return 1
  echo "recorded $TRACK_ID"
}
