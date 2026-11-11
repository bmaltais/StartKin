#!/usr/bin/env bash
# `startkin adopt`: confirm where untraced or guessed items came from; the answer goes to the registry
# (lib/registry.sh, docs/adopt.md) and is applied to every later scan. Source this.
# Needs lib/common.sh, lib/scan.sh, lib/registry.sh, lib/ui.sh.
# shellcheck shell=bash

ADOPT_USAGE='Usage: startkin adopt [--list [--json]]
       startkin adopt ITEM_ID SOURCE
Sources: --git URL [--ref REF] [--build CMD]...   --go MODULE   --cargo CRATE
         --release URL [--sha256 HEX]   --script URL   --copy   --confirm (keep the scanner'"'"'s guess)
Without arguments: walk through the items needing confirmation (gum if installed, plain prompts otherwise).'

# adopt_candidates : JSON array of scanned items that need confirmation (no provenance, or confidence below 0.9)
adopt_candidates() {
  scan_collect | jq -c 'map(select(.provenance.method == "none" or .provenance.confidence < 0.9))'
}

# adopt_item ID : the scanned item with that id as the scanners reported it (no registry overlay), or fail
adopt_item() {
  scan_collect_raw | jq -ce --arg id "$1" 'map(select(.id == $id)) | first // empty' | grep .
}

# adopt_describe ITEM_JSON : one line, "id  method  conf  current guess"
adopt_describe() {
  jq -r '"\(.id)  \(.provenance.method)  \(.provenance.confidence)  " +
    (.install | if .type == "unknown" then "unknown (\(.path // "?"))"
                else "\(.type) \(.url // .module // .crate // .package // .path // "")" end)' <<<"$1"
}

# adopt_url_ok URL SCHEMES_ERE : a single token with an accepted scheme
adopt_url_ok() { [[ $1 =~ ^($2)[^[:space:]]+$ ]]; }

# adopt_descriptor TYPE VALUE REF SHA ITEM_JSON [BUILD...] : print the install descriptor, or return 2 (message on stderr)
adopt_descriptor() {
  local type=$1 val=$2 ref=$3 sha=$4 item=$5 builds path
  shift 5
  case $type in
    git)
      adopt_url_ok "$val" 'https?://|ssh://|git@|git://' || { warn "not a git URL: $val"; return 2; }
      builds=$(printf '%s\n' "$@" | jq -R . | jq -sc 'map(select(. != ""))')
      jq -nc --arg u "$val" --arg r "$ref" --argjson b "$builds" \
        '{type: "git-build", url: $u} + (if $r != "" then {ref: $r} else {} end) + (if ($b | length) > 0 then {build: $b} else {} end)'
      ;;
    go | cargo)
      [[ -n $val && $val != *[[:space:]]* ]] || { warn "bad $type name: $val"; return 2; }
      if [[ $type == go ]]; then jq -nc --arg m "$val" '{type: "go", module: $m}'; else jq -nc --arg c "$val" '{type: "cargo", crate: $c}'; fi
      ;;
    release)
      adopt_url_ok "$val" 'https?://' || { warn "not an http(s) URL: $val"; return 2; }
      jq -nc --arg u "$val" --arg s "$sha" '{type: "release-binary", url: $u} + (if $s != "" then {sha256: $s} else {} end)'
      ;;
    script)
      adopt_url_ok "$val" 'https?://' || { warn "not an http(s) URL: $val"; return 2; }
      jq -nc --arg u "$val" '{type: "script", url: $u}'
      ;;
    copy)
      path=$(jq -r '.install.path // empty' <<<"$item")
      [[ -n $path ]] || { warn "this item has no local path to copy"; return 2; }
      jq -nc --arg p "$path" '{type: "copy", path: $p}'
      ;;
    confirm)
      jq -ce 'select(.install.type != "unknown") | .install' <<<"$item" | grep . || { warn "nothing to confirm: the scanner has no guess for this item"; return 1; }
      ;;
  esac
}

# adopt_record ITEM_JSON INSTALL_JSON : write the registry entry and say so
adopt_record() {
  local id version install
  id=$(jq -r .id <<<"$1")
  version=$(jq -r '.version // empty' <<<"$1")
  registry_put "$id" "$2" "$version" adopt || return 1
  install=$(jq -r '"\(.type) \(.url // .module // .crate // .path // "")"' <<<"$2")
  echo "adopted $id: $install"
}

# adopt_interactive : ask about every candidate
adopt_interactive() {
  local items n i item opts choice val ref sha cmd rc install
  local -a builds
  items=$(adopt_candidates)
  n=$(jq length <<<"$items")
  if ((n == 0)); then echo "nothing to adopt: every item has a known source"; return 0; fi
  for ((i = 0; i < n; i++)); do
    item=$(jq -c ".[$i]" <<<"$items")
    echo "[$((i + 1))/$n] $(adopt_describe "$item")"
    opts=(git go cargo release script copy)
    [[ $(jq -r .install.type <<<"$item") != unknown ]] && opts+=(confirm)
    opts+=(skip quit)
    choice=$(ui_choose "Where did $(jq -r .name <<<"$item") come from?" "${opts[@]}") || return 0
    val="" ref="" sha="" builds=()
    case $choice in
      skip) continue ;;
      quit) return 0 ;;
      git)
        val=$(ui_input "git URL") || return 0
        ref=$(ui_input "ref (branch, tag or commit; blank for default)") || return 0
        while cmd=$(ui_input "build command (blank when done)") && [[ -n $cmd ]]; do builds+=("$cmd"); done
        ;;
      go) val=$(ui_input "go module path") || return 0 ;;
      cargo) val=$(ui_input "crate name") || return 0 ;;
      release) val=$(ui_input "release binary URL") || return 0 ;;
      script) val=$(ui_input "install script URL") || return 0 ;;
    esac
    rc=0
    if install=$(adopt_descriptor "$choice" "$val" "$ref" "$sha" "$item" "${builds[@]}"); then
      adopt_record "$item" "$install" || rc=1
    else
      rc=1
    fi
    ((rc)) && echo "skipped $(jq -r .id <<<"$item")" >&2
  done
  return 0
}

# cmd_adopt ARGS... : the subcommand
cmd_adopt() {
  local list=0 json=0 id="" type="" val="" ref="" sha="" a
  local -a builds=()
  set_source() { # TYPE VALUE
    [[ -z $type ]] || die -c 2 "adopt: give one source only"
    type=$1 val=${2-}
  }
  while (($#)); do
    a=$1
    case $a in
      -h | --help) echo "$ADOPT_USAGE"; return 0 ;;
      --list) list=1 ;;
      --json) json=1 ;;
      --confirm | --copy) set_source "${a#--}" "" ;;
      --git | --go | --cargo | --release | --script)
        (($# >= 2)) || die -c 2 "adopt: $a needs a value"
        set_source "${a#--}" "$2"; shift ;;
      --ref | --sha256 | --build)
        (($# >= 2)) || die -c 2 "adopt: $a needs a value"
        case $a in --ref) ref=$2 ;; --sha256) sha=$2 ;; --build) builds+=("$2") ;; esac
        shift ;;
      -*) die -c 2 "adopt: unknown option: $a" ;;
      *) [[ -z $id ]] || die -c 2 "adopt: one item id only"; id=$a ;;
    esac
    shift
  done
  require_cmd jq
  if ((list)); then
    [[ -z $id && -z $type ]] || die -c 2 "adopt: --list takes no item or source"
    local items
    items=$(adopt_candidates)
    if ((json)); then
      printf '%s\n' "$items"
    else
      local it
      while IFS= read -r it; do adopt_describe "$it"; done < <(jq -c '.[]' <<<"$items")
    fi
    return 0
  fi
  ((json)) && die -c 2 "adopt: --json goes with --list"
  if [[ -z $id ]]; then
    [[ -z $type ]] || die -c 2 "adopt: a source needs an item id"
    adopt_interactive
    return
  fi
  [[ -n $type ]] || die -c 2 "adopt: $id needs a source (--git, --go, --cargo, --release, --script, --copy or --confirm)"
  [[ $type == git || (-z $ref && ${#builds[@]} == 0) ]] || die -c 2 "adopt: --ref and --build go with --git"
  [[ $type == release || -z $sha ]] || die -c 2 "adopt: --sha256 goes with --release"
  local item install rc
  item=$(adopt_item "$id") || die "adopt: no such item: $id (see: startkin adopt --list)"
  install=$(adopt_descriptor "$type" "$val" "$ref" "$sha" "$item" "${builds[@]}") && rc=0 || rc=$?
  ((rc == 2)) && return 2
  ((rc)) && return 1
  adopt_record "$item" "$install"
}
