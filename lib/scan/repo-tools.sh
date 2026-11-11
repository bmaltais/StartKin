#!/usr/bin/env bash
# Scanner: binaries and app dirs that no package manager owns, traced to where they came from (issue #7).
# Candidates: entries of the bin dirs (~/.local/bin, /usr/local/bin) and the app dirs (~/.local/share).
# Skipped: backups (*.prev ...), hidden files, anything pacman owns, links into the Omarchy plugins dir
# (the plugin scanner reports those) and links into registry-tool dirs (uv, mise, cargo...).
# Tracing methods and confidences are in lib/provenance.sh. Contract: docs/engine.md.
# shellcheck shell=bash

# shellcheck source=../provenance.sh
source "${STARTKIN_ROOT:?}/lib/provenance.sh"

# repo_tools_skip PATH : true when another scanner (or a package) owns PATH
repo_tools_skip() {
  local p=$1 hop d
  local -a hops
  mapfile -t hops < <(prov_link_chain "$p")
  hops+=("$(readlink -f -- "$p" 2>/dev/null || true)")
  while IFS= read -r d; do
    for hop in "${hops[@]}"; do
      [[ -n $hop ]] && prov_under "$hop" "$d" && return 0
    done
    prov_under "$p" "$d" && return 0
  done < <({ prov_plugin_dir; prov_registry_dirs; })
  prov_pkg_owned "$p"
}

# repo_tools_main_file DIR : the executable that represents an app dir (named like the dir, else the first one)
repo_tools_main_file() {
  local dir=$1 base f first=""
  base=$(basename -- "$dir")
  while IFS= read -r f; do
    [[ $f == *.so || $f == *.so.* ]] && continue
    prov_is_elf "$f" || [[ $(head -c2 -- "$f" 2>/dev/null) == '#!' ]] || continue # .desktop files are often +x too
    [[ -n $first ]] || first=$f
    [[ $(basename -- "$f") == "$base" ]] && { printf '%s' "$f"; return 0; }
  done < <(find -L "$dir" -maxdepth 2 -type f -perm -u+x 2>/dev/null | sort)
  [[ -n $first ]] && printf '%s' "$first"
  return 0
}

# repo_tools_item PATH KIND NAME [TRACE_PATH] : print one item as JSON
repo_tools_item() {
  local path=$1 kind=$2 name=$3 trace=${4:-$1} where risk target id hint=""
  prov_trace "$trace" "$name"
  target=$(readlink -f -- "$path" 2>/dev/null || echo "$path")
  [[ $target == *.AppImage ]] && hint="AppImage"
  if [[ $R_METHOD == none ]]; then
    R_INSTALL=$(jq -nc --arg p "$path" --arg h "$hint" '{type: "unknown", path: $p} + (if $h != "" then {hint: $h} else {} end)')
  fi
  where=$(prov_tilde "$(dirname -- "$path")")
  id="repo-tool:${name//[[:space:]]/_}"
  risk=low
  awk -v c="$R_CONF" 'BEGIN {exit !(c < 0.7)}' && risk=medium
  jq -nc \
    --arg id "$id" --arg name "$name" --arg kind "$kind" --arg risk "$risk" \
    --argjson install "$R_INSTALL" --arg version "$R_VERSION" \
    --arg method "$R_METHOD" --argjson conf "$R_CONF" --arg where "found in $where" \
    --argjson evid "$(printf '%s\n' "${R_EVID[@]}" | jq -R . | jq -sc 'map(select(. != ""))')" \
    '{id: $id, name: $name, kind: $kind, category: "repo-tool", risk: $risk, install: $install,
      version: (if $version == "" then null else $version end),
      provenance: {method: $method, confidence: $conf, evidence: ([$where] + $evid)},
      private: false}'
}

scan_repo_tools() {
  local dir entry name kind trace main item
  local -A seen_names=() seen_targets=()
  local -a items=()
  prov_load_clones

  while IFS= read -r dir; do
    [[ -d $dir ]] || continue
    while IFS= read -r entry; do
      name=$(basename -- "$entry")
      prov_skip_name "$name" && continue
      [[ -d $entry && ! -L $entry ]] && continue
      [[ -L $entry || -x $entry ]] || continue
      repo_tools_skip "$entry" && continue
      kind=cli
      [[ $(readlink -f -- "$entry" 2>/dev/null) == *.AppImage ]] && kind=gui-app
      if [[ -f $entry && ! -L $entry ]] && ! prov_is_elf "$entry"; then kind=script; fi
      item=$(repo_tools_item "$entry" "$kind" "$name") || continue
      items+=("$item")
      seen_names[$name]=1
      seen_targets[$(readlink -f -- "$entry" 2>/dev/null || echo "$entry")]=1
    done < <(find "$dir" -mindepth 1 -maxdepth 1 \( -type f -o -type l \) 2>/dev/null | sort)
  done < <(prov_bin_dirs)

  local t top
  while IFS= read -r dir; do
    [[ -d $dir ]] || continue
    while IFS= read -r entry; do
      name=$(basename -- "$entry")
      prov_skip_name "$name" && continue
      [[ -n ${seen_names[$name]:-} ]] && continue
      # A bin link that points into this entry already represents it.
      top=""
      for t in "${!seen_targets[@]}"; do prov_under "$t" "$entry" && top=1; done
      [[ -n $top ]] && continue
      if [[ -d $entry ]]; then
        main=$(repo_tools_main_file "$entry")
        [[ -n $main || -e $entry/.git ]] || continue
        kind=other
      else
        [[ $name == *.AppImage && -x $entry ]] || continue
        main=$entry kind=gui-app
      fi
      repo_tools_skip "$entry" && continue
      trace=$entry
      [[ -d $entry && ! -L $entry && -n $main ]] && trace=$main
      item=$(repo_tools_item "$entry" "$kind" "$name" "$trace") || continue
      items+=("$item")
    done < <(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null | sort)
  done < <(prov_app_dirs)

  if ((${#items[@]})); then
    printf '%s\n' "${items[@]}" | jq -s '
      reduce .[] as $i ({seen: {}, out: []};
        ($i.id) as $id
        | (.seen[$id] // 0) as $n
        | .seen[$id] = $n + 1
        | .out += [if $n == 0 then $i else ($i | .id = "\($id):\($n + 1)") end])
      | .out'
  else
    echo '[]'
  fi
}
