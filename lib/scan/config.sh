#!/usr/bin/env bash
# Scanner: ~/.config diffed against what Omarchy ships.
# Baselines (a file is "shipped" if it is byte-identical in any of them):
#   $STARTKIN_SKEL_DIR/.config      (default /etc/skel, from the omarchy-settings package)
#   $STARTKIN_OMARCHY_DIR/config    (default /usr/share/omarchy, the same package's config templates)
#   $STARTKIN_OMARCHY_DIR/themes/NAME for omarchy/themes/NAME
# One `copy` item per changed or added file. A directory with no shipped counterpart (or a user theme) is one
# item for the whole directory, unless it holds a denied or secret-bearing file, in which case its files are
# listed one by one. Never reads contents into the manifest: only a category, a status and flags go in evidence.
# Paths the secrets policy denies are skipped. Files with a secret pattern or machine-specific values
# (monitors, GPU, connector names, absolute home paths) get private=true and risk=high.
# STARTKIN_CONFIG_MAX_FILES (default 500): an unshipped directory with more files is assumed to be state or cache and skipped.
# shellcheck shell=bash

# shellcheck source=../secrets.sh
source "${STARTKIN_ROOT:?}/lib/secrets.sh"

CONFIG_SCAN_MAX_BYTES=2097152 # files above this are not content-scanned and are marked private

# config_category REL : category tag for a path relative to ~/.config
config_category() {
  case $1 in
    omarchy/themes | omarchy/themes/* | omarchy/themed | omarchy/themed/*) echo themes ;;
    omarchy | omarchy/*) echo omarchy ;;
    hypr | hypr/* | hyprland* | xdg-desktop-portal | xdg-desktop-portal/*) echo hypr ;;
    alacritty | alacritty/* | foot | foot/* | ghostty | ghostty/* | kitty | kitty/* | wezterm | wezterm/*) echo terminal ;;
    nvim | nvim/* | Code | Code/* | zed* | helix | helix/* | micro | micro/* | emacs | emacs/*) echo editor ;;
    tmux | tmux/* | starship.toml | fish | fish/* | zsh | zsh/*) echo shell ;;
    btop | btop/* | lazygit | lazygit/* | git | git/* | mise | mise/* | opencode | opencode/* | herdr | herdr/* | gh | gh/*) echo cli-tools ;;
    fcitx* | ibus | ibus/*) echo input ;;
    wireplumber | wireplumber/* | pulse | pulse/* | pipewire | pipewire/*) echo audio ;;
    autostart | autostart/*) echo autostart ;;
    chromium* | google-chrome* | BraveSoftware* | microsoft-edge* | vivaldi* | opera*) echo browser ;;
    qtengine | qtengine/* | gtk-* | QtProject.conf | fontconfig | fontconfig/* | dconf | dconf/*) echo appearance ;;
    mimeapps.list | xdg-terminals.list | user-dirs.dirs | menus | menus/*) echo desktop ;;
    *) echo app ;;
  esac
}

# config_noise REL : true for backups, caches, logs, storage and database blobs, app state (persistence dirs) and paths another scanner owns
config_noise() {
  local rel=$1 part IFS=/
  case $rel in omarchy/plugins | omarchy/plugins/*) return 0 ;; esac
  for part in $rel; do # any path component
    case $part in
      *.bak | *.bak.* | *.bak-* | *.orig | *.rej | *~ | *.swp | .\#* | .git | node_modules | __pycache__) return 0 ;;
      Cached* | cached_* | *Storage | "Shared Dictionary" | sand-* | *-persistence | "Crash Reports" | *Cache | *Cache_Data | Dictionaries | cache | logs | Logs | IndexedDB | blob_storage | Crashpad | sentry | "Service Worker" | Partitions | leveldb) return 0 ;;
      *.log | *.log.* | *.log-* | LOG | LOG.old | TransportSecurity | Cookies | Cookies-journal | "Network Persistent State") return 0 ;;
      *.blob | *.vscdb | *.vscdb.* | *.sqlite | *.sqlite3 | *.sqlite-* | *.db | *.db-* | *-wal | *-shm | *-journal) return 0 ;;
    esac
  done
  return 1
}

# config_machine_reasons REL FILE : print one reason per line for machine-specific content (never the content)
config_machine_reasons() {
  local rel=$1 f=$2
  case ${rel##*/} in monitors.* | kanshi*) echo "monitor layout" ;; esac
  [[ -f $f ]] || return 0
  grep -qIE 'AQ_DRM_DEVICES|WLR_DRM_DEVICES|LIBVA_DRIVER_NAME|__GLX_VENDOR_LIBRARY_NAME|GBM_BACKEND|NVD_BACKEND|DRI_PRIME|__NV_PRIME_RENDER_OFFLOAD' "$f" 2>/dev/null && echo "gpu settings"
  grep -qIE '(^|[^[:alnum:]_-])(eDP|DP|HDMI-A|HDMI|DVI-[DI]|VGA|LVDS)-[0-9]+([^[:alnum:]_]|$)' "$f" 2>/dev/null && echo "monitor names"
  if grep -qIE '(^|[^[:alnum:]_])/(home|Users)/[A-Za-z0-9._-]+' "$f" 2>/dev/null ||
    { ((${#HOME} > 1)) && grep -qIF -- "$HOME/" "$f" 2>/dev/null; }; then echo "absolute home path"; fi
  return 0
}

# config_state REL FILE : "same", "modified" or "added" against the baselines in $CONFIG_BASES
config_state() {
  local b exists=0
  for b in "${CONFIG_BASES[@]}"; do
    [[ -f $b/$1 ]] || continue
    exists=1
    cmp -s -- "$b/$1" "$2" && { echo same; return 0; }
  done
  if ((exists)); then echo modified; else echo added; fi
}

# config_item REL STATUS RISK PRIVATE EVIDENCE... : print one compact item
config_item() {
  local rel=$1 status=$2 risk=$3 private=$4
  shift 4
  local install
  install=$(jq -nc --arg path "$(tilde_path "$CONFIG_DIR/$rel")" --arg rel "$rel" '{type: "copy", path: $path, dest: ("~/.config/" + $rel)}')
  item_json "config:${rel//[[:space:]]/_}" "$rel" config config "$risk" "$install" "" adjacent-evidence 0.9 "$private" \
    "category: $(config_category "$rel")" "status: $status" "$@"
}

# config_file_flags FILE REL : set CONFIG_RISK, CONFIG_PRIVATE, CONFIG_EVIDENCE (array) for a file that passed the path policy
config_file_flags() {
  local f=$1 rel=$2 size reason kind line
  CONFIG_RISK=low CONFIG_PRIVATE=false CONFIG_EVIDENCE=()
  case $rel in omarchy/hooks/* | autostart/* | *.sh) CONFIG_RISK=medium ;; esac
  if [[ -x $f && ! -d $f ]]; then CONFIG_RISK=medium; fi
  while IFS= read -r reason; do
    [[ -n $reason ]] || continue
    CONFIG_RISK=high CONFIG_PRIVATE=true
    CONFIG_EVIDENCE+=("machine-specific: $reason")
  done < <(config_machine_reasons "$rel" "$f")
  if [[ -L $f ]]; then
    CONFIG_EVIDENCE+=("symlink")
    return 0
  fi
  case ${f,,} in # images, fonts and video hold no config text: not worth scanning
    *.png | *.jpg | *.jpeg | *.webp | *.gif | *.svgz | *.ico | *.mp4 | *.webm | *.ttf | *.otf | *.woff | *.woff2) return 0 ;;
  esac
  size=$(stat -c %s -- "$f" 2>/dev/null || echo 0)
  if ((size > CONFIG_SCAN_MAX_BYTES)); then
    CONFIG_RISK=high CONFIG_PRIVATE=true
    CONFIG_EVIDENCE+=("not content-scanned: file over ${CONFIG_SCAN_MAX_BYTES} bytes")
    return 0
  fi
  while IFS=$'\t' read -r kind line; do
    [[ -n $kind ]] || continue
    CONFIG_RISK=high CONFIG_PRIVATE=true
    CONFIG_EVIDENCE+=("content flagged ($kind) at line $line")
    warn "$CONFIG_DIR/$rel: $kind at line $line"
  done < <(secrets_scan_file "$f")
  return 0
}

# config_emit_file REL STATUS : print the item for one file unless the path is denied
config_emit_file() {
  local rel=$1 status=$2 f=$CONFIG_DIR/$1 cat
  if cat=$(secrets_path_denied "$f"); then
    warn "skipped ($cat): $f"
    return 0
  fi
  config_file_flags "$f" "$rel"
  config_item "$rel" "$status" "$CONFIG_RISK" "$CONFIG_PRIVATE" "${CONFIG_EVIDENCE[@]}"
}

# config_dir_risk REL FILES... : medium if the directory holds autostart, hook, script or executable files, else low
config_dir_risk() {
  local rel=$1 f
  shift
  case $rel in omarchy/hooks | omarchy/hooks/* | autostart | autostart/*) echo medium; return 0 ;; esac
  for f in "$@"; do
    if [[ -x $f && ! -d $f ]] || [[ $f == *.sh ]]; then echo medium; return 0; fi
  done
  echo low
}

# config_emit_dir REL STATUS : one item for the directory if everything in it is clean, else its files one by one
config_emit_dir() {
  local rel=$1 status=$2 d=$CONFIG_DIR/$1 max=${STARTKIN_CONFIG_MAX_FILES:-500} files=() f r clean=1
  mapfile -t -n $((max + 1)) files < <(find "$d" \( -type f -o -type l \) 2>/dev/null | LC_ALL=C sort)
  if ((${#files[@]} > max)); then
    warn "skipped (over $max files, probably state or cache): $d"
    return 0
  fi
  ((${#files[@]})) || return 0
  for f in "${files[@]}"; do
    r=${f#"$CONFIG_DIR"/}
    if config_noise "$r"; then clean=0; break; fi # a copy of the directory would carry the noise: list files instead
    config_file_flags "$f" "$r"
    if secrets_path_denied "$f" >/dev/null || [[ $CONFIG_PRIVATE == true ]]; then clean=0; break; fi
  done
  if ((clean)); then
    config_item "$rel" "$status" "$(config_dir_risk "$rel" "${files[@]}")" false "directory, ${#files[@]} files"
    return 0
  fi
  for f in "${files[@]}"; do
    r=${f#"$CONFIG_DIR"/}
    config_noise "$r" && continue
    config_emit_file "$r" "$status"
  done
}

# config_has_base_dir REL : is REL a directory in any baseline?
config_has_base_dir() {
  local b
  for b in "${CONFIG_BASES[@]}"; do [[ -d $b/$1 ]] && return 0; done
  return 1
}

# config_visit REL : classify one entry of ~/.config
config_visit() {
  local rel=$1 p=$CONFIG_DIR/$1 cat state shipped
  config_noise "$rel" && return 0
  if cat=$(secrets_path_denied "$p"); then
    warn "skipped ($cat): $p"
    return 0
  fi
  if [[ -d $p && ! -L $p ]]; then
    case $rel in
      omarchy/themes)
        config_walk "$rel"
        return 0
        ;;
      omarchy/themes/*)
        shipped=$CONFIG_OMARCHY/themes/${rel#omarchy/themes/}
        if [[ -d $shipped ]]; then
          diff -rq -- "$shipped" "$p" >/dev/null 2>&1 && return 0
          config_emit_dir "$rel" modified
        else
          config_emit_dir "$rel" added
        fi
        return 0
        ;;
    esac
    if config_has_base_dir "$rel"; then config_walk "$rel"; else config_emit_dir "$rel" added; fi
    return 0
  fi
  [[ -f $p || -L $p ]] || return 0
  state=$(config_state "$rel" "$p")
  [[ $state == same ]] || config_emit_file "$rel" "$state"
}

# config_walk REL : visit every entry of a directory under ~/.config ("" is the root)
config_walk() {
  local rel=$1 e had_nullglob=0 had_dotglob=0
  shopt -q nullglob && had_nullglob=1
  shopt -q dotglob && had_dotglob=1
  shopt -s nullglob dotglob
  for e in "$CONFIG_DIR${rel:+/$rel}"/*; do
    config_visit "${e#"$CONFIG_DIR"/}"
  done
  # restore the caller's options (config_visit recurses into config_walk, so each level puts back what it found)
  ((had_nullglob)) || shopt -u nullglob
  ((had_dotglob)) || shopt -u dotglob
  return 0
}

scan_config() {
  local CONFIG_DIR=$HOME/.config
  local CONFIG_OMARCHY
  CONFIG_OMARCHY=$(omarchy_dir)
  local CONFIG_BASES=("${STARTKIN_SKEL_DIR:-/etc/skel}/.config" "$CONFIG_OMARCHY/config")
  local CONFIG_RISK CONFIG_PRIVATE CONFIG_EVIDENCE=()
  [[ -d $CONFIG_DIR ]] || { echo '[]'; return 0; }
  (config_walk "") | jq -s '.'
}
