#!/usr/bin/env bash
# Helper: which tool symlinks in the user's bin dir point into Omarchy plugin folders.
# Used by the plugin scanner (to annotate items) and meant for the binary scanner (to skip these links).
# Source this; it only defines functions.
# shellcheck shell=bash

# plugin_dirs [PLUGINS_DIR] : print the plugin directories (symlinks followed), one per line.
# Skips dot-directories (.add.tmp.*, .<id>.bak.*) like omarchy-plugin-catalog, and dirs without manifest.json.
plugin_dirs() {
  local dir=${1:-${STARTKIN_PLUGINS_DIR:-$HOME/.config/omarchy/plugins}} d
  [[ -d $dir ]] || return 0
  for d in "$dir"/*/; do
    d=${d%/}
    [[ -f $d/manifest.json ]] && printf '%s\n' "$d"
  done
  return 0
}

# plugin_id_of PLUGIN_DIR : manifest id, falling back to the directory name.
plugin_id_of() {
  local id
  id=$(jq -r '.id // empty' "$1/manifest.json" 2>/dev/null) || id=
  printf '%s\n' "${id:-$(basename "$1")}"
}

# plugin_bin_links [PLUGINS_DIR] [BIN_DIR] : print a JSON array
#   [{"name": "startdrive", "path": "<bin>/startdrive", "target": "<fully resolved target>", "plugin_id": "<manifest id>"}]
# with one entry per symlink in BIN_DIR whose fully resolved target lies inside a plugin folder (a symlinked
# plugin folder counts via its resolved location). Defaults: $STARTKIN_PLUGINS_DIR or ~/.config/omarchy/plugins,
# $STARTKIN_BIN_DIR or ~/.local/bin. Missing dirs give [].
plugin_bin_links() {
  local pdir=${1:-} bdir=${2:-${STARTKIN_BIN_DIR:-$HOME/.local/bin}}
  local d link target root id
  local -a roots=() ids=() out=()
  while IFS= read -r d; do
    roots+=("$(readlink -f "$d")")
    ids+=("$(plugin_id_of "$d")")
  done < <(plugin_dirs "$pdir")
  if [[ -d $bdir ]] && ((${#roots[@]})); then
    shopt -s dotglob nullglob
    for link in "$bdir"/*; do
      [[ -L $link ]] || continue
      target=$(readlink -f "$link")
      for d in "${!roots[@]}"; do
        root=${roots[$d]} id=${ids[$d]}
        if [[ $target == "$root" || $target == "$root"/* ]]; then
          out+=("$(jq -nc --arg n "$(basename "$link")" --arg p "$link" --arg t "$target" --arg i "$id" \
            '{name: $n, path: $p, target: $t, plugin_id: $i}')")
          break
        fi
      done
    done
    shopt -u dotglob nullglob
  fi
  if ((${#out[@]})); then printf '%s\n' "${out[@]}" | jq -sc .; else echo '[]'; fi
}
