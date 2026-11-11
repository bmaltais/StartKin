#!/usr/bin/env bash
# Scanner: packages the user added after the Omarchy install. Contract: docs/engine.md.
#
# Baseline = names in Omarchy's shipped lists (<omarchy dir>/install/*.packages) + the omarchy* packages themselves
# + everything those packages depend on. Added = `pacman -Qe` (explicitly installed) minus baseline; `pacman -Qem`
# marks AUR/foreign ones. Explicit packages that other installed packages require are emitted as kind "library"
# (dependency-only in practice), the rest as "other"; gui-app/cli are not guessed.
# STARTKIN_OMARCHY_DIR overrides /usr/share/omarchy (tests).
# shellcheck shell=bash

# packages_baseline : one baseline package name per line
packages_baseline() {
  local dir own=() f
  dir=$(omarchy_dir)/install
  for f in "$dir"/*.packages; do
    [[ -f $f ]] && sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$f"
  done
  mapfile -t own < <(pacman_omarchy_package_names)
  if ((${#own[@]})); then
    printf '%s\n' "${own[@]}"
    pacman_dependency_names "${own[@]}"
  fi
}

scan_packages() {
  if ! command -v pacman >/dev/null 2>&1; then
    warn "packages: pacman not found, skipping"
    echo '[]'
    return 0
  fi

  local base_ver baseline helper="" explicit foreign
  base_ver=$(pacman_omarchy_version)
  if [[ -z $base_ver ]]; then
    warn "packages: no omarchy package installed; baseline is only the shipped package lists, expect noise"
    base_ver="none"
  fi
  baseline=$(packages_baseline | sort -u)
  command -v paru >/dev/null 2>&1 && helper=paru
  [[ -z $helper ]] && command -v yay >/dev/null 2>&1 && helper=yay

  explicit=$(pacman_explicit_table)
  foreign=$(pacman_foreign_names)

  jq -Rn \
    --rawfile base <(printf '%s\n' "$baseline") \
    --rawfile foreign <(printf '%s\n' "$foreign") \
    --rawfile repos <(pacman_repo_table) \
    --arg helper "$helper" \
    --arg basever "$base_ver" "$ITEM_JQ_DEF"'
    def lines: split("\n") | map(select(. != ""));
    ($base | lines | map({(.): true}) | add // {}) as $b
    | ($foreign | lines | map({(.): true}) | add // {}) as $f
    | ($repos | lines | map(split("\t") | {(.[0]): .[1]}) | add // {}) as $r
    | [inputs | select(. != "") | split("\t") | {name: .[0], version: .[1], req: (.[2] // "" | split(",") | map(select(. != "")))}
       | select($b[.name] | not)
       | . as $p
       | ($f[$p.name] // false) as $aur
       | mkitem((if $aur then "aur:" else "pacman:" end) + $p.name;
                $p.name;
                (if ($p.req | length) > 0 then "library" else "other" end);
                "package";
                (if $aur then "medium" else "low" end);
                (if $aur
                 then ({type: "aur", package: $p.name} + (if $helper != "" then {helper: $helper} else {} end))
                 else ({type: "pacman", package: $p.name} + (if $r[$p.name] then {repo: $r[$p.name]} else {} end)) end);
                $p.version;
                "package-manager";
                (if $aur then 0.8 else 0.95 end);
                false;
                (["pacman -Qe", "baseline: \($basever)"]
                 + (if ($p.req | length) > 0 then ["required by: " + ($p.req | join(", "))] else [] end)))]' <<<"$explicit"
}
