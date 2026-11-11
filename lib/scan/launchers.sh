#!/usr/bin/env bash
# Scanner: user launcher entries in ~/.local/share/applications (incl. Omarchy webapps and TUIs).
# Baseline: the .desktop files Omarchy itself ships in $STARTKIN_OMARCHY_DIR/applications (default
# /usr/share/omarchy/applications); an entry with the same file name is not reported.
# Each remaining entry is a `copy` item pointing at the .desktop file (icons are not followed).
# shellcheck shell=bash

# launcher_field FILE KEY : first unlocalized KEY= value of the [Desktop Entry] section
launcher_field() {
  awk -v key="$2" '
    /^\[/ { in_entry = ($0 == "[Desktop Entry]"); next }
    in_entry && index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }
  ' "$1"
}

scan_launchers() {
  local dir=${HOME}/.local/share/applications
  local base
  base=$(omarchy_dir)/applications
  [[ -d $dir ]] || { echo '[]'; return 0; }

  local f file name exec_line hidden id tags items=()
  for f in "$dir"/*.desktop; do
    [[ -f $f ]] || continue
    file=$(basename "$f")
    [[ -e $base/$file ]] && continue
    hidden=$(launcher_field "$f" Hidden)
    [[ $hidden == true ]] && continue
    name=$(launcher_field "$f" Name)
    [[ -n $name ]] || name=${file%.desktop}
    exec_line=$(launcher_field "$f" Exec)
    tags=()
    case $exec_line in
      *omarchy-launch-webapp* | *omarchy-webapp-handler*) tags+=("omarchy webapp") ;;
      *omarchy-launch-tui*) tags+=("omarchy tui") ;;
    esac
    id=launcher:${file//[[:space:]]/_}
    items+=("$(item_json "$id" "$name" launcher launcher low \
      "$(jq -nc --arg p "$(tilde_path "$f")" '{type: "copy", path: $p}')" "" adjacent-evidence 0.8 false \
      "file $file" "${tags[@]}")")
  done
  items_join "${items[@]}"
}
