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

# services_ctl SCOPE ARGS... : systemctl for the system manager (SCOPE system) or the user manager (SCOPE user)
services_ctl() {
  local scope=$1
  shift
  if [[ $scope == user ]]; then systemctl --user "$@"; else systemctl "$@"; fi
}

# services_norm : stdin unit names, one per line; append .service when there is no unit-type suffix
services_norm() {
  awk 'NF { if ($0 ~ /\.(service|socket|timer|path|target|mount)$/) print; else print $0 ".service" }'
}

# services_baseline SCOPE (system|user) : baseline unit names derived from Omarchy's install scripts
services_baseline() {
  local scope=$1 dir
  dir=$(omarchy_dir)/install
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
  frag=$(services_ctl user show -p FragmentPath --value "$1" 2>/dev/null) || return 1
  [[ -n $frag && $frag != "$HOME"/* ]] || return 1
  owner=$(pacman_owner "$frag") || return 1
  pkg=${owner%% *}
  [[ $pkg == omarchy* ]] && return 0
  grep -qxF -- "$pkg" "$(omarchy_dir)"/install/*.packages 2>/dev/null && return 0
  pacman_is_dependency "$pkg"
}

# services_item SCOPE UNIT : one manifest item for an enabled unit
services_item() {
  local scope=$1 unit=$2 frag="" owner="" pkg="" ver="" risk=medium id="service:$1:$2"
  frag=$(services_ctl "$scope" show -p FragmentPath --value "$unit" 2>/dev/null) || frag=""
  [[ $scope == user ]] && risk=low

  if [[ -n $frag && $frag == "$HOME"/* ]]; then
    item_json "$id" "$unit" service service "$risk" \
      "$(jq -nc --arg p "$(tilde_path "$frag")" '{type: "copy", path: $p}')" "" adjacent-evidence 0.7 false \
      "enabled $scope unit" "unit file $(tilde_path "$frag")"
  elif [[ -n $frag ]] && owner=$(pacman_owner "$frag"); then
    read -r pkg ver <<<"$owner"
    item_json "$id" "$unit" service service "$risk" \
      "$(jq -nc --arg p "$pkg" '{type: "pacman", package: $p}')" "$ver" package-manager 0.95 false \
      "enabled $scope unit" "owned by $pkg ($(tilde_path "$frag"))"
  else
    local hint="systemctl enable $unit" evidence=("enabled $scope unit")
    [[ $scope == user ]] && hint="systemctl --user enable $unit"
    [[ -n $frag ]] && evidence+=("unit file $(tilde_path "$frag")")
    item_json "$id" "$unit" service service "$risk" \
      "$(jq -nc --arg h "$hint" '{type: "unknown", hint: $h}')" "" fallback 0.3 false "${evidence[@]}"
  fi
}

scan_services() {
  command -v systemctl >/dev/null 2>&1 || { warn "systemctl not found, no services scanned"; echo '[]'; return 0; }
  [[ -d $(omarchy_dir)/install ]] || warn "Omarchy install scripts not found; service baseline is vendor presets only"

  local scope list base unit preset items=()
  for scope in system user; do
    list=$(services_ctl "$scope" list-unit-files --state=enabled --no-legend --type=service,socket,timer,path 2>/dev/null) || {
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
  items_join "${items[@]}"
}
