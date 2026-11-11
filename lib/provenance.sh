#!/usr/bin/env bash
# Provenance helpers for untracked binaries and app dirs (used by lib/scan/repo-tools.sh; docs/design.md, "Provenance").
# Source this; it defines functions only. Every environment knob has a default and a test override:
#   STARTKIN_BIN_DIRS       colon list of directories whose entries are binaries (default ~/.local/bin:/usr/local/bin)
#   STARTKIN_APP_DIRS       colon list of directories whose entries are app dirs (default ~/.local/share)
#   STARTKIN_GIT_ROOTS      colon list of directories holding git clones (default ~/StartFS/github)
#   STARTKIN_PLUGIN_DIR     Omarchy plugins dir; links into it belong to the plugin scanner (default ~/.config/omarchy/plugins)
#   STARTKIN_REGISTRY_DIRS  colon list of dirs owned by registry tools (uv, mise, cargo...); links into them are skipped
#   STARTKIN_HISTORY_FILES  colon list of shell history files (default ~/.bash_history:~/.zsh_history)
#   STARTKIN_PROBE=1        allow running unowned CLI binaries with --version/--help (`startkin scan --probe`).
#                           Off by default: scanning must be read-only. GUI-looking binaries are never run.
#   STARTKIN_DESKTOP_DIRS   colon list of .desktop directories used to recognise GUI launchers
# shellcheck shell=bash

# Results of prov_trace, read by the caller.
# shellcheck disable=SC2034 # read by lib/scan/repo-tools.sh
R_METHOD="" R_CONF="" R_INSTALL="" R_VERSION="" R_EVID=()

# prov_dirs VAR DEFAULT : print the entries of colon-list env var VAR (or DEFAULT), one per line
prov_dirs() {
  local v=${!1:-$2} d
  local -a parts
  IFS=: read -ra parts <<<"$v"
  for d in "${parts[@]}"; do [[ -n $d ]] && printf '%s\n' "${d%/}"; done
  return 0
}

prov_bin_dirs() { prov_dirs STARTKIN_BIN_DIRS "$HOME/.local/bin:/usr/local/bin"; }
prov_app_dirs() { prov_dirs STARTKIN_APP_DIRS "$HOME/.local/share"; }
prov_git_roots() { prov_dirs STARTKIN_GIT_ROOTS "$HOME/StartFS/github"; }
prov_plugin_dir() { prov_dirs STARTKIN_PLUGIN_DIR "$HOME/.config/omarchy/plugins"; }
prov_registry_dirs() {
  prov_dirs STARTKIN_REGISTRY_DIRS "$HOME/.local/share/uv:$HOME/.local/share/mise:$HOME/.cargo/bin:$HOME/.local/share/pnpm:$HOME/.local/share/pipx"
}
prov_history_files() { prov_dirs STARTKIN_HISTORY_FILES "$HOME/.bash_history:$HOME/.zsh_history"; }

# prov_tilde PATH : PATH with $HOME shortened to ~ (evidence must not leak the user name)
prov_tilde() { tilde_path "$1"; }

# prov_under PATH DIR : true when PATH is DIR or inside it
prov_under() { [[ $1 == "$2" || $1 == "$2"/* ]]; }

# prov_link_chain PATH : every hop of a symlink chain (not PATH itself), absolute, ending at the final target
prov_link_chain() {
  local p=$1 t n=0
  while [[ -L $p ]] && ((n++ < 10)); do
    t=$(readlink -- "$p") || return 0
    [[ $t == /* ]] || t=$(dirname -- "$p")/$t
    printf '%s\n' "$t"
    p=$t
  done
  return 0
}

# prov_skip_name NAME : true for names that are backups or hidden helpers, never reported
prov_skip_name() {
  case $1 in
    .* | *.prev | *.bak | *.old | *.orig | *.staged | *~) return 0 ;;
  esac
  return 1
}

# prov_pkg_owned PATH... : true when pacman says a package owns any of the paths (or their resolved targets)
prov_pkg_owned() {
  command -v pacman >/dev/null 2>&1 || return 1
  local p r
  for p in "$@"; do
    r=$(readlink -f -- "$p" 2>/dev/null || true)
    pacman -Qo -- "$p" >/dev/null 2>&1 && return 0
    [[ -n $r && $r != "$p" ]] && pacman -Qo -- "$r" >/dev/null 2>&1 && return 0
  done
  return 1
}

# prov_is_elf FILE
prov_is_elf() {
  [[ -f $1 ]] || return 1
  [[ $(head -c4 -- "$1" 2>/dev/null) == $'\x7f'ELF ]]
}

# prov_clean_url URL : drop credentials from a URL
prov_clean_url() { printf '%s' "$1" | sed -E 's#(://)[^/@]*@#\1#'; }

# prov_repo_key URL : "owner/repo" lowercased, or empty for something that is not a hosted repo URL
prov_repo_key() {
  local u=${1%/} k
  u=${u%.git}
  k=$(printf '%s' "$u" | sed -nE 's#^(https?://|ssh://([^@/]+@)?|[^@/]+@)?[^/:]+[/:]([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)$#\3#p')
  printf '%s' "${k,,}"
}

# prov_strings MINLEN FILE : printable strings of the first 32 MB of FILE (big AppImages would take minutes)
prov_strings() { head -c 33554432 -- "$2" 2>/dev/null | strings -n "$1" 2>/dev/null || true; }

prov_desktop_dirs() { prov_dirs STARTKIN_DESKTOP_DIRS "$HOME/.local/share/applications:/usr/share/applications:/usr/local/share/applications"; }

# prov_needed FILE : the shared libraries an ELF file links (DT_NEEDED), one per line; fails when they cannot be read
prov_needed() {
  command -v readelf >/dev/null 2>&1 || return 1
  readelf -d -- "$1" 2>/dev/null | sed -nE 's/.*\(NEEDED\).*\[(.*)\]/\1/p'
}

# prov_gui_like FILE : true when FILE looks like (or might be) a GUI app, so it must never be run. Unknown counts as GUI.
prov_gui_like() {
  local r base d x libs exe
  r=$(readlink -f -- "$1" 2>/dev/null) || return 0
  base=${1##*/}
  case $r in
    *.AppImage | */quickshell* | */[Ee]lectron* | */qt[0-9]*/*) return 0 ;;
  esac
  d=$(dirname -- "$r")
  [[ -e $d/resources/app.asar || -e $d/chrome-sandbox || -e $d/libffmpeg.so ]] && return 0
  while IFS= read -r x; do
    [[ -d $x ]] || continue
    # first word of every Exec= line, quotes dropped
    while IFS= read -r exe; do
      exe=${exe//[\"\']/}
      [[ $exe == "$1" || $exe == "$r" || ${exe##*/} == "$base" || ${exe##*/} == "${r##*/}" ]] && return 0
    done < <(awk -F= '$1 == "Exec" { split(substr($0, 6), w, " "); print w[1] }' "$x"/*.desktop 2>/dev/null)
  done < <(prov_desktop_dirs)
  libs=$(prov_needed "$r") || return 0
  grep -qE '^lib(wayland|X11|xcb|Qt[0-9]|gtk|gdk|SDL|glfw|EGL|GL\.|GLX|vulkan|adwaita|cef|electron)' <<<"$libs" && return 0
  return 1
}

# prov_probe FILE FLAG : first 4 KB of FILE FLAG's output. Only with STARTKIN_PROBE=1, never for GUI-looking
# binaries; runs with a sanitized environment (no display or session bus), no stdin, in its own process group
# and session, killed (group included) after 3 s.
prov_probe() {
  [[ ${STARTKIN_PROBE:-0} == 1 ]] || return 0
  prov_gui_like "$1" && return 0
  env -i PATH="$PATH" HOME="$HOME" setsid timeout --kill-after=1 3 "$1" "$2" </dev/null 2>&1 | head -c 4096 || true
}

# prov_version_of TEXT : the first version-looking token of TEXT
prov_version_of() { printf '%s' "$1" | grep -m1 -oE 'v?[0-9]+(\.[0-9]+)+[0-9A-Za-z.+_-]*|v[0-9]{6,}-[0-9a-f]+' | head -n1 || true; }

# --- git clones ---------------------------------------------------------------------------------------------

declare -A CLONE_URL=() CLONE_HEAD=()

# prov_git_info DIR : set GIT_URL and GIT_HEAD from the clone at DIR; false without an origin
prov_git_info() {
  GIT_URL=$(git -C "$1" config --get remote.origin.url 2>/dev/null) || return 1
  [[ -n $GIT_URL ]] || return 1
  GIT_URL=$(prov_clean_url "$GIT_URL")
  GIT_HEAD=$(git -C "$1" rev-parse HEAD 2>/dev/null) || GIT_HEAD=""
}

# prov_load_clones : fill CLONE_URL / CLONE_HEAD for every clone under the configured roots (hidden dirs skipped)
prov_load_clones() {
  CLONE_URL=() CLONE_HEAD=()
  local root g d
  while IFS= read -r root; do
    [[ -d $root ]] || continue
    while IFS= read -r -d '' g; do
      d=${g%/.git}
      [[ ${d#"$root"} == */.* ]] && continue
      prov_git_info "$d" || continue
      CLONE_URL[$d]=$GIT_URL
      CLONE_HEAD[$d]=$GIT_HEAD
    done < <(find "$root" -maxdepth 3 -name .git -prune -print0 2>/dev/null)
  done < <(prov_git_roots)
}

# prov_clone_of PATH : print the root of the git clone containing PATH (walking up, stopping at $HOME), or fail
prov_clone_of() {
  local d=$1
  [[ -d $d ]] || d=$(dirname -- "$d")
  while [[ $d != / && $d != "$HOME" && -n $d ]]; do
    if [[ -e $d/.git ]]; then printf '%s' "$d"; return 0; fi
    d=$(dirname -- "$d")
  done
  return 1
}

# --- result builders ----------------------------------------------------------------------------------------

# prov_set METHOD CONF INSTALL_JSON EVIDENCE... : record a result
prov_set() {
  R_METHOD=$1 R_CONF=$2 R_INSTALL=$3
  shift 3
  R_EVID+=("$@")
}

# prov_git_build_json URL REF : install descriptor for a clone
prov_git_build_json() {
  jq -nc --arg url "$1" --arg ref "$2" '{type: "git-build", url: $url} + (if $ref != "" then {ref: $ref} else {} end)'
}

# --- tracing steps (each returns 0 and calls prov_set when it traced the item) -------------------------------

# prov_try_go FILE NAME : embedded Go build info
prov_try_go() {
  command -v go >/dev/null 2>&1 || return 1
  local info path mod ver
  info=$(go version -m -- "$1" 2>/dev/null) || return 1
  path=$(awk -F'\t' '$2 == "path" {print $3; exit}' <<<"$info")
  mod=$(awk -F'\t' '$2 == "mod" {print $3 "\t" $4; exit}' <<<"$info")
  [[ -n $path && $path == *.*/* ]] || return 1
  ver=${mod#*$'\t'}
  [[ $ver == "(devel)" || $ver =~ -[0-9]{14}- ]] && ver="" # pseudo-versions say nothing useful; --version is asked later
  R_VERSION=$ver
  prov_set build-metadata 0.95 "$(jq -nc --arg m "$path" '{type: "go", module: $m}')" "go version -m: path $path"
}

# prov_try_crate_hint FILE NAME : Rust workspace path "crates/NAME/" embedded in the binary and a clone that has it
prov_try_crate_hint() {
  command -v strings >/dev/null 2>&1 || return 1
  prov_strings 6 "$1" | grep -q -m1 "crates/$2/" || return 1
  local d
  for d in "${!CLONE_URL[@]}"; do
    [[ -d $d/crates/$2 ]] || continue
    prov_set build-metadata 0.75 "$(prov_git_build_json "${CLONE_URL[$d]}" "${CLONE_HEAD[$d]}")" \
      "strings: crates/$2/ in binary" "clone $(prov_tilde "$d") has crates/$2"
    return 0
  done
  return 1
}

# prov_try_symlink_clone PATH : a symlink whose target lives in a git clone
prov_try_symlink_clone() {
  [[ -L $1 ]] || return 1
  local t d
  t=$(readlink -f -- "$1" 2>/dev/null) || return 1
  [[ -e $t ]] || return 1
  d=$(prov_clone_of "$t") || return 1
  prov_git_info "$d" || return 1
  prov_set adjacent-evidence 0.9 "$(prov_git_build_json "$GIT_URL" "$GIT_HEAD")" "symlink target $(prov_tilde "$t")" "inside clone $(prov_tilde "$d")"
}

# prov_url_from_text : read stdin, print the first github URL as "kind url" (script|git), or fail
prov_url_from_text() {
  local m owner repo rest
  m=$(grep -m1 -oE '(github\.com|raw\.githubusercontent\.com)/[A-Za-z0-9_-][A-Za-z0-9_.-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*(/[^][:space:]"'"'"')<>]*)?' | head -n1) || true
  [[ -n $m ]] || return 1
  m=${m%.}
  owner=${m#*/}
  owner=${owner%%/*}
  rest=${m#*/"$owner"/}
  repo=${rest%%/*}
  repo=${repo%.git}
  if [[ $m == raw.githubusercontent.com/* && $m == *.sh ]]; then
    echo "script https://$m"
  else
    echo "git https://github.com/$owner/$repo"
  fi
}

# prov_try_sibling NAME : an app dir named NAME that mentions its repo or install script in install*/README* files
prov_try_sibling() {
  local name=$1 dir f hit kind url
  while IFS= read -r dir; do
    [[ -d $dir/$name ]] || continue
    for f in "$dir/$name"/install*.sh "$dir/$name"/README*; do
      [[ -f $f ]] || continue
      hit=$(head -c 65536 -- "$f" | prov_url_from_text) || continue
      kind=${hit%% *} url=${hit#* }
      if [[ $kind == script ]]; then
        prov_set adjacent-evidence 0.6 "$(jq -nc --arg u "$url" '{type: "script", url: $u, interpreter: "sh"}')" "$(prov_tilde "$f") names $url"
      else
        prov_set adjacent-evidence 0.6 "$(prov_git_build_json "$url" "")" "$(prov_tilde "$f") names $url"
      fi
      return 0
    done
  done < <(prov_app_dirs)
  return 1
}

# prov_try_script FILE : a small shell script that installs/runs its tool through mise
prov_try_script() {
  local tool backend
  [[ -f $1 ]] || return 1
  prov_is_elf "$1" && return 1
  tool=$(head -c 4096 -- "$1" | grep -m1 -E '^[^#]*mise ' | grep -m1 -oE '(npm|cargo|pipx|go|github|aqua|ubi):[@A-Za-z0-9/_.-]+' | head -n1) || true
  [[ -n $tool ]] || return 1
  backend=${tool%%:*}
  prov_set adjacent-evidence 0.6 "$(jq -nc --arg t "$tool" --arg b "$backend" '{type: "mise", tool: $t, backend: $b}')" "script runs mise tool $tool"
}

# prov_try_probe FILE NAME : --version for the version, --help for a repo URL (ELF files only)
prov_try_probe() {
  local out hit
  prov_is_elf "$1" || return 1
  out=$(prov_probe "$1" --version)
  [[ -n $out ]] && R_VERSION=$(prov_version_of "$out")
  [[ -n $R_VERSION ]] && R_EVID+=("--version reports $R_VERSION")
  out=$(prov_probe "$1" --help)
  hit=$(prov_url_from_text <<<"$out") || return 1
  [[ ${hit%% *} == git ]] || return 1
  prov_set version-flag 0.55 "$(prov_git_build_json "${hit#* }" "")" "--help names ${hit#* }"
}

# prov_try_name NAME : a clone named like the binary, or with crates/NAME, cmd/NAME or bin/NAME
prov_try_name() {
  local name=${1,,} d b
  for d in "${!CLONE_URL[@]}"; do
    b=$(basename -- "$d")
    if [[ ${b,,} == "$name" || -e $d/crates/$1 || -e $d/cmd/$1 || -e $d/bin/$1 ]]; then
      prov_set name-search 0.45 "$(prov_git_build_json "${CLONE_URL[$d]}" "${CLONE_HEAD[$d]}")" "clone $(prov_tilde "$d") matches the name (needs confirmation)"
      return 0
    fi
  done
  return 1
}

# prov_try_strings_url FILE : a repo URL embedded in the binary that matches exactly one local clone's origin
prov_try_strings_url() {
  command -v strings >/dev/null 2>&1 || return 1
  local keys k d found="" n=0
  keys=$(prov_strings 8 "$1" | grep -oE 'github\.com[/:][A-Za-z0-9_.-]+/[A-Za-z0-9_-][A-Za-z0-9_.-]*' | sed -E 's#github\.com[/:]##; s#\.git$##' | tr '[:upper:]' '[:lower:]' | sort -u | head -200) || true
  [[ -n $keys ]] || return 1
  for d in "${!CLONE_URL[@]}"; do
    k=$(prov_repo_key "${CLONE_URL[$d]}")
    if [[ -n $k ]] && grep -qxF -- "$k" <<<"$keys"; then found=$d; n=$((n + 1)); fi
  done
  ((n == 1)) || return 1
  prov_set build-metadata 0.5 "$(prov_git_build_json "${CLONE_URL[$found]}" "${CLONE_HEAD[$found]}")" "strings: repo URL of clone $(prov_tilde "$found") in binary"
}

# prov_try_history NAME : a shell-history line that installed NAME. The history line itself never leaves this
# function (docs/secrets-policy.md, rule 3): evidence is the derived fact only, "installed via shell history:
# <verb>" plus the repo URL when it is a plain https URL without credentials, query or fragment.
prov_try_history() {
  local name=$1 f line target fact
  while IFS= read -r f; do
    [[ -r $f ]] || continue
    line=$(grep -a -E "(git clone|go install|cargo install|npm (i|install) .*-g|pipx install|uv tool install)[^|;&]*$name" -- "$f" 2>/dev/null | grep -a -v -i -E 'token|secret|passw|ghp_|authorization' | tail -n1) || true
    [[ -n $line ]] || continue
    line=${line#*;}
    line=$(printf '%s' "$line" | sed -E 's#(://)[^/@ ]*@#\1#' | cut -c1-120)
    case $line in
      *"git clone "*)
        target=$(sed -nE 's#.*git clone( -[^ ]+)* ((https?://|git@)[^ ]+).*#\2#p' <<<"$line" | head -n1)
        [[ $target =~ ^(https?://|git@)[^/:]+[/:][^/]+/[^/]+$ && ${target,,} == *"${name,,}"* ]] || continue # a repo URL, not an issue link
        fact="installed via shell history: git clone"
        [[ $target =~ ^https://[^/@?#]+/[^@?#]+$ ]] && fact+=" $target"
        prov_set shell-history 0.4 "$(prov_git_build_json "$target" "")" "$fact"
        return 0
        ;;
      *"cargo install "*)
        prov_set shell-history 0.4 "$(jq -nc --arg c "$name" '{type: "cargo", crate: $c}')" "installed via shell history: cargo install"
        return 0
        ;;
      *"go install "*)
        target=$(grep -oE '[A-Za-z0-9.-]+\.[a-z]+/[^[:space:]@]+' <<<"$line" | head -n1) || true
        [[ -n $target ]] || continue
        prov_set shell-history 0.4 "$(jq -nc --arg m "$target" '{type: "go", module: $m}')" "installed via shell history: go install"
        return 0
        ;;
      *"pipx install "*)
        prov_set shell-history 0.4 "$(jq -nc --arg c "$name" '{type: "pipx", package: $c}')" "installed via shell history: pipx install"
        return 0
        ;;
      *"uv tool install "*)
        prov_set shell-history 0.4 "$(jq -nc --arg c "$name" '{type: "uv", package: $c}')" "installed via shell history: uv tool install"
        return 0
        ;;
      *npm*)
        prov_set shell-history 0.4 "$(jq -nc --arg c "$name" '{type: "npm", package: $c}')" "installed via shell history: npm install -g"
        return 0
        ;;
    esac
  done < <(prov_history_files)
  return 1
}

# prov_trace PATH NAME : run the steps in order. Sets R_METHOD, R_CONF, R_INSTALL, R_VERSION, R_EVID (never fails).
prov_trace() {
  local path=$1 name=$2
  # shellcheck disable=SC2034 # read by lib/scan/repo-tools.sh
  R_METHOD="" R_CONF="" R_INSTALL="" R_VERSION="" R_EVID=()
  if [[ -f $path ]] && prov_is_elf "$path"; then
    prov_try_go "$path" "$name" && { prov_extras "$path" "$name"; return 0; }
    prov_try_crate_hint "$path" "$name" && { prov_extras "$path" "$name"; return 0; }
  fi
  prov_try_symlink_clone "$path" && { prov_extras "$path" "$name"; return 0; }
  prov_try_script "$path" && return 0
  prov_try_sibling "$name" && { prov_extras "$path" "$name"; return 0; }
  prov_try_probe "$path" "$name" && return 0
  prov_try_name "$name" && { prov_extras "$path" "$name"; return 0; }
  if [[ -f $path ]] && prov_is_elf "$path"; then
    prov_try_strings_url "$path" && return 0
  fi
  prov_try_history "$name" && return 0
  prov_set none 0 "$(jq -nc --arg p "$path" '{type: "unknown", path: $p}')"
  return 0
}

# prov_extras PATH NAME : after a hit, fill the version from --version when the step did not
prov_extras() {
  local out
  [[ -n $R_VERSION ]] && return 0
  prov_is_elf "$1" || return 0
  out=$(prov_probe "$1" --version)
  [[ -n $out ]] && R_VERSION=$(prov_version_of "$out")
  return 0
}

# prov_report : read a JSON array of items on stdin, print how many were traced exactly (confidence >= 0.9),
# heuristically (0 < confidence < 0.9) or not at all (method none), and a per-method breakdown.
prov_report() {
  jq -r '
    map(select(.category == "repo-tool")) as $i
    | ($i | map(select(.provenance.confidence >= 0.9)) | length) as $exact
    | ($i | map(select(.provenance.confidence > 0 and .provenance.confidence < 0.9)) | length) as $heur
    | ($i | map(select(.provenance.method == "none")) | length) as $none
    | "items \($i | length): exact \($exact), heuristic \($heur), unknown \($none)",
      ($i | group_by(.provenance.method)[] | "  \(.[0].provenance.method): \(length)")'
}
