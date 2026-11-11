#!/usr/bin/env bash
# Scanner: packages the user added after the Omarchy install. Contract: docs/engine.md.
#
# Baseline = names in Omarchy's shipped lists (<omarchy dir>/install/*.packages) + the omarchy* packages themselves
# + everything those packages depend on. Added = `pacman -Qe` (explicitly installed) minus baseline; `pacman -Qem`
# marks AUR/foreign ones. Explicit packages that other installed packages require are emitted as kind "library"
# (dependency-only in practice), the rest as "other"; gui-app/cli are not guessed.
# STARTKIN_OMARCHY_DIR overrides /usr/share/omarchy (tests).
# shellcheck shell=bash

# packages_omarchy_version : "<pkg> <version>" of the installed omarchy package, empty if none
packages_omarchy_version() {
  local pkg
  for pkg in omarchy omarchy-dev; do
    pacman -Q "$pkg" 2>/dev/null && return 0
  done
  return 0
}

# packages_baseline : one baseline package name per line
packages_baseline() {
  local dir=${STARTKIN_OMARCHY_DIR:-/usr/share/omarchy}/install own=()
  local f
  for f in "$dir"/*.packages; do
    [[ -f $f ]] && sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$f"
  done
  mapfile -t own < <(pacman -Qq 2>/dev/null | grep '^omarchy')
  if ((${#own[@]})); then
    printf '%s\n' "${own[@]}"
    # Depends On may continue on indented lines; names are split off any version constraint.
    LC_ALL=C pacman -Qi "${own[@]}" 2>/dev/null | awk '
      /^[A-Za-z]/ { key = ($0 ~ /^Depends On/) }
      key { sub(/^[^:]*:/, ""); n = split($0, a, /  +/); for (i = 1; i <= n; i++) { sub(/[<>=:].*/, "", a[i]); gsub(/ /, "", a[i]); if (a[i] != "" && a[i] != "None") print a[i] } }'
  fi
}

scan_packages() {
  if ! command -v pacman >/dev/null 2>&1; then
    warn "packages: pacman not found, skipping"
    echo '[]'
    return 0
  fi

  local base_ver baseline helper="" explicit foreign
  base_ver=$(packages_omarchy_version)
  if [[ -z $base_ver ]]; then
    warn "packages: no omarchy package installed; baseline is only the shipped package lists, expect noise"
    base_ver="none"
  fi
  baseline=$(packages_baseline | sort -u)
  command -v paru >/dev/null 2>&1 && helper=paru
  [[ -z $helper ]] && command -v yay >/dev/null 2>&1 && helper=yay

  # name<TAB>version<TAB>required-by (comma-separated, empty when none), one line per explicit package
  explicit=$(LC_ALL=C pacman -Qei 2>/dev/null | awk '
    function flush() { if (name != "") print name "\t" ver "\t" req; name = ""; ver = ""; req = "" }
    function add(s,   n, a, i) {
      n = split(s, a, /  +/)
      for (i = 1; i <= n; i++) { gsub(/^ +| +$/, "", a[i]); if (a[i] != "" && a[i] != "None") req = req (req == "" ? "" : ",") a[i] }
    }
    /^Name/ { flush(); sub(/^[^:]*: */, ""); name = $0; key = ""; next }
    /^Version/ { sub(/^[^:]*: */, ""); ver = $0; key = ""; next }
    /^Required By/ { key = "req"; sub(/^[^:]*: */, ""); add($0); next }
    /^ / && key == "req" { add($0); next }
    /^[A-Za-z]/ { key = "" }
    END { flush() }')
  foreign=$(pacman -Qemq 2>/dev/null)

  jq -Rn \
    --arg base "$baseline" \
    --arg foreign "$foreign" \
    --rawfile repos <(LC_ALL=C pacman -Sl 2>/dev/null | awk '{ print $2 "\t" $1 }') \
    --arg helper "$helper" \
    --arg basever "$base_ver" '
    def lines: split("\n") | map(select(. != ""));
    ($base | lines | map({(.): true}) | add // {}) as $b
    | ($foreign | lines | map({(.): true}) | add // {}) as $f
    | ($repos | lines | map(split("\t") | {(.[0]): .[1]}) | add // {}) as $r
    | [inputs | select(. != "") | split("\t") | {name: .[0], version: .[1], req: (.[2] // "" | split(",") | map(select(. != "")))}
       | select($b[.name] | not)
       | . as $p
       | ($f[$p.name] // false) as $aur
       | {id: ((if $aur then "aur:" else "pacman:" end) + $p.name),
          name: $p.name,
          kind: (if ($p.req | length) > 0 then "library" else "other" end),
          category: "package",
          risk: (if $aur then "medium" else "low" end),
          install: (if $aur
                    then ({type: "aur", package: $p.name} + (if $helper != "" then {helper: $helper} else {} end))
                    else ({type: "pacman", package: $p.name} + (if $r[$p.name] then {repo: $r[$p.name]} else {} end)) end),
          version: (if $p.version == "" then null else $p.version end),
          provenance: {method: "package-manager",
                       confidence: (if $aur then 0.8 else 0.95 end),
                       evidence: (["pacman -Qe", "baseline: \($basever)"]
                                  + (if ($p.req | length) > 0 then ["required by: " + ($p.req | join(", "))] else [] end))},
          private: false}]' <<<"$explicit"
}
