#!/usr/bin/env bash
# Every pacman query StartKin makes, in one place. All of them are read-only and fail quietly when pacman is absent.
# shellcheck shell=bash

# pacman_omarchy_version : "<pkg> <version>" of the installed omarchy package (omarchy, else omarchy-dev); empty if none
pacman_omarchy_version() {
  local pkg
  for pkg in omarchy omarchy-dev; do
    pacman -Q "$pkg" 2>/dev/null && return 0
  done
  return 0
}

# pacman_owns PATH... : true when a package owns any of the paths. Paths under $HOME are never asked about: no
# package owns them, and each `pacman -Qo` costs about a quarter of a second.
pacman_owns() {
  local p
  command -v pacman >/dev/null 2>&1 || return 1
  for p in "$@"; do
    ((${#HOME} > 1)) && [[ $p == "$HOME"/* ]] && continue
    pacman -Qo -- "$p" >/dev/null 2>&1 && return 0
  done
  return 1
}

# pacman_owner FILE : "<pkg> <version>" of the package that owns FILE; fails when none does
pacman_owner() {
  local owner
  owner=$(pacman -Qo "$1" 2>/dev/null) && [[ $owner == *" is owned by "* ]] || return 1
  printf '%s\n' "${owner##* is owned by }"
}

# pacman_is_dependency PKG : true when PKG was installed as a dependency
pacman_is_dependency() { pacman -Qi "$1" 2>/dev/null | grep -q '^Install Reason.*dependency'; }

# pacman_omarchy_package_names : installed packages whose name starts with omarchy
pacman_omarchy_package_names() { pacman -Qq 2>/dev/null | grep '^omarchy' || true; }

# pacman_dependency_names PKG... : names the packages depend on (version constraints stripped), one per line.
# Depends On may continue on indented lines.
pacman_dependency_names() {
  LC_ALL=C pacman -Qi "$@" 2>/dev/null | awk '
    /^[A-Za-z]/ { key = ($0 ~ /^Depends On/) }
    key { sub(/^[^:]*:/, ""); n = split($0, a, /  +/); for (i = 1; i <= n; i++) { sub(/[<>=:].*/, "", a[i]); gsub(/ /, "", a[i]); if (a[i] != "" && a[i] != "None") print a[i] } }'
}

# pacman_explicit_table : one line per explicitly installed package: name<TAB>version<TAB>required-by (comma-separated)
pacman_explicit_table() {
  LC_ALL=C pacman -Qei 2>/dev/null | awk '
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
    END { flush() }'
}

# pacman_foreign_names : explicitly installed packages not in a sync repo (AUR), one per line
pacman_foreign_names() { pacman -Qemq 2>/dev/null; }

# pacman_repo_table : name<TAB>repo for every package in the sync databases
pacman_repo_table() { LC_ALL=C pacman -Sl 2>/dev/null | awk '{ print $2 "\t" $1 }'; }
