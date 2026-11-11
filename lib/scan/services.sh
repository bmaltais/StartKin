#!/usr/bin/env bash
# Scanner: enabled systemd units (system and user) beyond the Omarchy baseline.
#
# A unit is baseline, and not reported, when any of these holds:
#   1. its vendor preset is "enabled" (distro default, e.g. getty@, systemd-resolved). The user-manager preset is
#      `enable *`, so every packaged user unit looks preset-enabled; there the unit counts as baseline only when
#      it ships from a package that is a dependency (pipewire, p11-kit) or is in Omarchy's own package lists
#      ($STARTKIN_OMARCHY_DIR/install/*.packages), and a unit file under $HOME is never baseline by preset;
#   2. Omarchy's own install scripts enable it: derived at scan time from
#      $STARTKIN_OMARCHY_DIR/install (default /usr/share/omarchy/install). System scripts are parsed for
#      `systemctl ... enable UNIT...`; user units come from any script that calls `systemctl --user ... enable`
#      and lists unit names (enable-user-units.sh);
#   3. it hangs off a baseline service: a .socket/.path/.timer with the same stem (cups.socket), or a unit named
#      "<baseline stem>-..." (NetworkManager-dispatcher.service). Preset-enabled system units count as baseline here.
# There is no hard-coded unit list: if the Omarchy tree is missing, only rule 1 applies (with a warning).
#
# Install descriptor: a package-owned unit is `pacman` (the package provides the unit, apply must also enable
# it); a unit file under $HOME is `copy` of that file; anything else is `unknown` with a hint.
# shellcheck shell=bash

# services_norm : stdin unit names, one per line; append .service when there is no unit-type suffix
services_norm() {
  awk 'NF { if ($0 ~ /\.(service|socket|timer|path|target|mount)$/) print; else print $0 ".service" }'
}

# services_baseline SCOPE (system|user) : baseline unit names derived from Omarchy's install scripts
services_baseline() {
  local scope=$1 dir=${STARTKIN_OMARCHY_DIR:-/usr/share/omarchy}/install
  [[ -d $dir ]] || return 0
  if [[ $scope == system ]]; then
    grep -rhE 'systemctl' "$dir" 2>/dev/null | awk '
      { sub(/^[ \t]+/, "") }
      /^#/ || /--user/ || !/enable/ { next }
      {
        i = index($0, "enable"); rest = substr($0, i + 6)
        sub(/[>|&;].*/, "", rest)
        n = split(rest, w, /[ \t]+/)
        for (k = 1; k <= n; k++) if (w[k] != "" && w[k] !~ /^-/ && w[k] !~ /[$"]/) print w[k]
      }' | services_norm
  else
    local f
    while IFS= read -r f; do
      grep -hvE '^[[:space:]]*#' "$f" | grep -oE '[A-Za-z0-9@_.-]+\.(service|socket|timer|path)\b'
    done < <(grep -rlE 'systemctl[[:space:]]+--user' "$dir" 2>/dev/null)
  fi
}

# services_is_companion UNIT KNOWN : succeed when UNIT is baseline (listed in KNOWN, one per line) or hangs off a
# baseline service: same stem as a .socket/.path/.timer (cups.socket), or stem "<baseline>-..." (NetworkManager-dispatcher)
services_is_companion() {
  local unit=$1 known=$2 stem=${1%.*} k
  grep -qxF -- "$unit" <<<"$known" && return 0
  case $unit in *.socket | *.path | *.timer) grep -qxF -- "$stem.service" <<<"$known" && return 0 ;; esac
  while IFS= read -r k; do
    [[ $k == *.service && $stem == "${k%.service}"-* ]] && return 0
  done <<<"$known"
  return 1
}

# services_user_default UNIT : succeed when a preset-enabled user unit is a distro/Omarchy default (see header, rule 1)
services_user_default() {
  local frag owner pkg
  frag=$(systemctl --user show -p FragmentPath --value "$1" 2>/dev/null) || return 1
  [[ -n $frag && $frag != "$HOME"/* ]] || return 1
  owner=$(pacman -Qo "$frag" 2>/dev/null) || return 1
  pkg=${owner##* is owned by }
  pkg=${pkg%% *}
  [[ $pkg == omarchy* ]] && return 0
  grep -qxF -- "$pkg" "${STARTKIN_OMARCHY_DIR:-/usr/share/omarchy}"/install/*.packages 2>/dev/null && return 0
  pacman -Qi "$pkg" 2>/dev/null | grep -q '^Install Reason.*dependency'
}

# services_item SCOPE UNIT : one manifest item for an enabled unit
services_item() {
  local scope=$1 unit=$2 frag="" owner="" pkg="" ver="" sysctl=(systemctl)
  [[ $scope == user ]] && sysctl=(systemctl --user)
  frag=$("${sysctl[@]}" show -p FragmentPath --value "$unit" 2>/dev/null) || frag=""
  local risk=medium
  [[ $scope == user ]] && risk=low

  if [[ -n $frag && $frag == "$HOME"/* ]]; then
    jq -n --arg id "service:$scope:$unit" --arg name "$unit" --arg risk "$risk" --arg path "$(tilde_path "$frag")" --arg scope "$scope" '{
      id: $id, name: $name, kind: "service", category: "service", risk: $risk,
      install: {type: "copy", path: $path}, version: null,
      provenance: {method: "adjacent-evidence", confidence: 0.7, evidence: ["enabled " + $scope + " unit", "unit file " + $path]},
      private: false}'
  elif [[ -n $frag ]] && owner=$(pacman -Qo "$frag" 2>/dev/null) && [[ $owner == *" is owned by "* ]]; then
    read -r pkg ver <<<"${owner##* is owned by }"
    jq -n --arg id "service:$scope:$unit" --arg name "$unit" --arg risk "$risk" --arg pkg "$pkg" --arg ver "$ver" --arg scope "$scope" --arg frag "$(tilde_path "$frag")" '{
      id: $id, name: $name, kind: "service", category: "service", risk: $risk,
      install: {type: "pacman", package: $pkg}, version: (if $ver == "" then null else $ver end),
      provenance: {method: "package-manager", confidence: 0.95, evidence: ["enabled " + $scope + " unit", "owned by " + $pkg + " (" + $frag + ")"]},
      private: false}'
  else
    local hint="systemctl ${sysctl[*]:1} enable $unit"
    jq -n --arg id "service:$scope:$unit" --arg name "$unit" --arg risk "$risk" --arg hint "${hint//  / }" --arg scope "$scope" --arg frag "$(tilde_path "$frag")" '{
      id: $id, name: $name, kind: "service", category: "service", risk: $risk,
      install: {type: "unknown", hint: $hint}, version: null,
      provenance: {method: "fallback", confidence: 0.3, evidence: (["enabled " + $scope + " unit"] + (if $frag == "" then [] else ["unit file " + $frag] end))},
      private: false}'
  fi
}

scan_services() {
  command -v systemctl >/dev/null 2>&1 || { warn "systemctl not found, no services scanned"; echo '[]'; return 0; }
  [[ -d ${STARTKIN_OMARCHY_DIR:-/usr/share/omarchy}/install ]] || warn "Omarchy install scripts not found; service baseline is vendor presets only"

  local scope list base unit preset items=() sysctl
  for scope in system user; do
    sysctl=(systemctl)
    [[ $scope == user ]] && sysctl=(systemctl --user)
    list=$("${sysctl[@]}" list-unit-files --state=enabled --no-legend --type=service,socket,timer,path 2>/dev/null) || {
      warn "could not list $scope units"
      continue
    }
    base=$(services_baseline "$scope")
    [[ $scope == system ]] && base+=$'\n'$(awk '$3 == "enabled" { print $1 }' <<<"$list")
    while read -r unit _ preset _; do
      [[ -n $unit ]] || continue
      services_is_companion "$unit" "$base" && continue
      if [[ $preset == enabled ]]; then
        [[ $scope == system ]] && continue
        services_user_default "$unit" && continue
      fi
      items+=("$(services_item "$scope" "$unit")")
    done <<<"$list"
  done
  if ((${#items[@]})); then printf '%s\n' "${items[@]}" | jq -s '.'; else echo '[]'; fi
}
