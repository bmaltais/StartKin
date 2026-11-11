#!/usr/bin/env bash
# Scanner: Omarchy plugins in ~/.config/omarchy/plugins (research: docs/omarchy-plugins.md).
# One item per plugin folder with a readable manifest.json. Contract: docs/engine.md.
#
# Overrides (tests): STARTKIN_PLUGINS_DIR, STARTKIN_BIN_DIR, STARTKIN_SHELL_JSON.
#
# The schema is closed, so extra facts ride in provenance.evidence as short strings:
#   "rev <sha>"                  checked-out commit of a git install
#   "enabled in shell.json" / "disabled in shell.json"
#   "bin link: <name>"           a symlink in the bin dir that points into this plugin (see lib/plugin_links.sh)
# shellcheck shell=bash

# shellcheck source=../plugin_links.sh
source "${STARTKIN_ROOT:?}/lib/plugin_links.sh"

# plugins_git_root DIR : the git checkout holding plugin DIR (itself if it has .git; for a symlinked dir, the
# repo enclosing the link target). Prints nothing when there is none.
plugins_git_root() {
  local d=$1 top
  if [[ -L $d ]]; then
    top=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) && printf '%s\n' "$top"
  elif [[ -e $d/.git ]]; then
    printf '%s\n' "$d"
  fi
  return 0
}

# plugins_clean_url URL : drop userinfo from http(s) URLs so tokens never reach the manifest
plugins_clean_url() { sed -E 's#^(https?://)[^/@]*@#\1#' <<<"$1"; }

# plugins_enabled_ids : ids referenced in shell.json (plugins[], bar.layout.*, bar.id), one per line
plugins_enabled_ids() {
  local f=${STARTKIN_SHELL_JSON:-$HOME/.config/omarchy/shell.json}
  [[ -f $f ]] || return 0
  jq -r '[(.plugins // [])[], ((.bar.layout // {}) | to_entries[] | .value[]?), (.bar.id // empty)]
         | .[] | if type == "object" then .id else . end | strings' "$f" 2>/dev/null
  return 0
}

scan_plugins() {
  local links enabled have_shell=0 shell_json=${STARTKIN_SHELL_JSON:-$HOME/.config/omarchy/shell.json}
  local d id name version homepage cloned root origin rev source
  local -a items=() evidence
  [[ -f $shell_json ]] && have_shell=1
  links=$(plugin_bin_links)
  enabled=$(plugins_enabled_ids)

  while IFS= read -r d; do
    if ! jq -e 'type == "object"' "$d/manifest.json" >/dev/null 2>&1; then
      warn "plugins: skipping $(basename "$d"): manifest.json is not valid JSON"
      continue
    fi
    id=$(plugin_id_of "$d")
    name=$(jq -r '.name // empty' "$d/manifest.json")
    version=$(jq -r '.version // empty' "$d/manifest.json")
    homepage=$(jq -r '.homepage // empty' "$d/manifest.json")
    cloned=$(jq -r '.omarchy.clonedFrom // empty' "$d/manifest.json")
    evidence=("manifest.json")

    root=$(plugins_git_root "$d")
    origin="" rev=""
    if [[ -n $root ]]; then
      origin=$(git -C "$root" remote get-url origin 2>/dev/null) || origin=
      rev=$(git -C "$root" rev-parse HEAD 2>/dev/null) || rev=
    fi

    # Install descriptor: git origin, else homepage, else a form StartKin cannot reproduce.
    local install method conf
    if [[ -n $cloned ]]; then
      install=$(jq -nc --arg p "$(tilde_path "$d")" --arg h "clone of built-in $cloned" '{type: "unknown", path: $p, hint: $h}')
      method=fallback conf=0.3
    elif [[ -n $origin ]]; then
      source=$(tilde_path "$(plugins_clean_url "$origin")")
      install=$(jq -nc --arg i "$id" --arg s "$source" '{type: "plugin", plugin_id: $i, source: $s}')
      method=adjacent-evidence conf=0.9
      evidence+=("git remote origin")
    elif [[ $homepage == http://* || $homepage == https://* ]]; then
      install=$(jq -nc --arg i "$id" --arg s "$(plugins_clean_url "$homepage")" '{type: "plugin", plugin_id: $i, source: $s}')
      method=adjacent-evidence conf=0.5
      evidence+=("manifest homepage")
    elif [[ -L $d ]]; then
      install=$(jq -nc --arg p "$(tilde_path "$(readlink -f "$d")")" --arg h "symlinked plugin folder, no git origin" '{type: "unknown", path: $p, hint: $h}')
      method=fallback conf=0.3
    else
      install=$(jq -nc --arg p "$(tilde_path "$d")" '{type: "copy", path: $p}')
      method=fallback conf=0.4
      evidence+=("plain copy, no git origin or homepage")
    fi

    [[ -n $rev ]] && evidence+=("rev $rev")
    if ((have_shell)); then
      if grep -qxF -- "$id" <<<"$enabled"; then evidence+=("enabled in shell.json"); else evidence+=("disabled in shell.json"); fi
    fi
    local n
    while IFS= read -r n; do
      [[ -n $n ]] && evidence+=("bin link: $n")
    done < <(jq -r --arg id "$id" '.[] | select(.plugin_id == $id) | .name' <<<"$links")

    items+=("$(item_json "plugin:$id" "${name:-$id}" plugin plugin high "$install" "$version" "$method" "$conf" false \
      "${evidence[@]}")")
  done < <(plugin_dirs)

  items_join "${items[@]}" | jq -c 'sort_by(.id)'
}
