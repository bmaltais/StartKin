#!/usr/bin/env bash
# `startkin apply` (#13): reproduce a manifest's packages and tools on this machine. Contract: docs/engine.md "Apply".
#   startkin apply MANIFEST|--from-peer PEER [--dry-run] [--yes] [--only IDS]
# Stages for plugins, config and services (#14) live in lib/apply_more.sh, backups and rollback in lib/backup.sh.
# Needs lib/common.sh, drift.sh, machine.sh, target.sh, peers.sh, ui.sh. Source this.
#
# Shape (a stage is added by naming it in APPLY_STAGES and defining apply_stage_NAME; the driver is not touched):
#   APPLY_STAGES        stage names in apply order (docs/design.md "Apply order")
#   apply_stage_of CAT TYPE   which stage an item belongs to (empty: nothing applies it)
#   apply_stage_NAME ITEMS_JSON   runs one stage over a JSON array of its items; reports each item with apply_record
#   apply_plan ITEM_JSON  per-item planner for stages built on apply_run_items; dispatches to apply_plan_<install type>
# Nothing is executed without being shown first; --dry-run shows and executes nothing.
# shellcheck shell=bash

APPLY_STAGES=(packages registry repos plugins config services)
APPLY_TILDE='~' # a literal tilde for patterns (shellcheck SC2088)

# Run state (one apply per process).
APPLY_DRY=0 APPLY_YES=0 APPLY_PEER="" APPLY_DRIFT="" APPLY_RES="" APPLY_TMP="" APPLY_WARN_IDS=""
# Consents --yes does not give (docs/engine.md "Apply"): plugin code, overwriting machine-specific files, user systemd unit
# files, and builds or downloads that are not pinned to a ref or checksum.
APPLY_ALLOW_PLUGINS=0 APPLY_ALLOW_MACHINE=0 APPLY_ALLOW_UNITS=0 APPLY_ALLOW_UNPINNED=0

# Result of the last apply_plan: commands to run, whether they run downloaded code, a note / reason, and the class of
# consent the commands need (empty: the ordinary "Run this?" that --yes pre-approves; else a class, see apply_confirm_for).
APPLY_CMDS=() APPLY_CODE=0 APPLY_NOTE="" APPLY_CONSENT=""

# ---- small helpers -------------------------------------------------------------------------------------------------

# apply_q ARG... : the arguments as one shell-safe line (what is shown and what is run)
apply_q() { local o="" a; for a in "$@"; do o+="$(printf '%q' "$a") "; done; printf '%s' "${o% }"; }

# apply_f ITEM_JSON JQ_FILTER : a field of the item as text, empty when null/missing
apply_f() { jq -r "($2) // empty" <<<"$1"; }

# Manifest values end up in commands: names, refs and URLs are checked before they are used (a snapshot can be hand-edited).
apply_name_ok() { [[ $1 =~ ^[A-Za-z0-9_@][A-Za-z0-9@._+:/-]*$ && $1 != *..* ]]; }
apply_relpath_ok() { [[ $1 =~ ^[A-Za-z0-9_.@+-][A-Za-z0-9@._+/-]*$ && $1 != *..* ]]; }
apply_ver_ok() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._+~-]*$ ]]; }
apply_url_ok() { [[ $1 =~ ^https://[^[:space:]\'\"\`\$\;\|\&\<\>\\\(\)]+$ ]]; }
apply_git_url_ok() { [[ $1 =~ ^(https://|ssh://|git://|git@)[^[:space:]\'\"\`\$\;\|\&\<\>\\\(\)]+$ ]]; }

# apply_path P : P with a leading ~ expanded to this machine's home
apply_path() {
  case $1 in
    "$APPLY_TILDE") printf '%s' "$HOME" ;;
    "$APPLY_TILDE/"*) printf '%s' "$HOME/${1#"$APPLY_TILDE/"}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# apply_home_path_ok P : the expanded path is inside home, has no .. segment, and still is inside home once symlinks in
# its existing parents are resolved (a symlinked directory cannot redirect a write elsewhere)
apply_home_path_ok() {
  local r h
  [[ $1 != *"/../"* && $1 != */.. && $1 == "$HOME"/* ]] || return 1
  h=$(realpath -m -- "$HOME") && r=$(realpath -m -- "$1") || return 1
  [[ $r == "$h"/* ]]
}

# apply_resolved_under P ROOT : P is inside ROOT after resolving symlinks in both
apply_resolved_under() {
  local r d
  r=$(realpath -m -- "$1") && d=$(realpath -m -- "$2") || return 1
  [[ $r == "$d"/* ]]
}

# apply_record ID STATUS DETAIL : report one item. STATUS: installed | present | planned | skipped | failed
apply_record() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$APPLY_RES"
  printf '  %-9s %s%s\n' "$2" "$1" "${3:+ ($3)}"
}

# apply_tmpdir : set APPLY_TMP, a scratch dir for downloads (not created in a dry run, where it is only displayed)
apply_tmpdir() {
  [[ -n $APPLY_TMP ]] && return 0
  if ((APPLY_DRY)); then APPLY_TMP=${TMPDIR:-/tmp}/startkin-apply.XXXXXX; else APPLY_TMP=$(mktemp -d) || return 1; fi
}

apply_cleanup() { if ((!APPLY_DRY)) && [[ -n $APPLY_TMP && -d $APPLY_TMP ]]; then rm -rf "$APPLY_TMP"; fi; return 0; }

# apply_show CMD... : print the exact command lines about to run
apply_show() { local c; for c in "$@"; do printf '    $ %s\n' "$(tilde_text "$c")"; done; }

# apply_confirm PROMPT : --yes pre-approves; otherwise ask (end of input is no)
apply_confirm() { ((APPLY_YES)) || ui_confirm "$1"; }

# apply_confirm_for CLASSES PROMPT : like apply_confirm, but classes that --yes does not cover need their own flag or an
# interactive yes. CLASSES is a space-separated list (empty: the ordinary prompt). When every class has its flag nothing is
# asked; otherwise one prompt. plugins: --allow-plugins; machine: --allow-machine-specific; units: --allow-units;
# unpinned: --allow-unpinned.
apply_confirm_for() {
  local c unmet=0 any=0
  for c in $1; do
    any=1
    case $c in
      plugins) ((APPLY_ALLOW_PLUGINS)) || unmet=1 ;;
      machine) ((APPLY_ALLOW_MACHINE)) || unmet=1 ;;
      units) ((APPLY_ALLOW_UNITS)) || unmet=1 ;;
      unpinned) ((APPLY_ALLOW_UNPINNED)) || unmet=1 ;;
      *) unmet=1 ;;
    esac
  done
  ((any)) || { apply_confirm "$2"; return; }
  ((!unmet)) || ui_confirm "$2"
}

# The package helper and the visible-terminal launcher; STARTKIN_OMARCHY / STARTKIN_FLOAT_CMD override them (tests).
apply_omarchy() { echo "${STARTKIN_OMARCHY:-omarchy}"; }
apply_float() { echo "${STARTKIN_FLOAT_CMD:-omarchy-launch-floating-terminal-with-presentation}"; }

# apply_in_terminal : true when a privileged command can run right here (stdin is a terminal, or there is no floating
# terminal launcher to use instead)
apply_in_terminal() { [[ -t 0 ]] || ! command -v "$(apply_float)" >/dev/null 2>&1; }

# apply_priv_exec CMD : run a package-manager command that needs sudo. In a terminal it runs there (sudo prompts in
# place). Without one it goes through Omarchy's visible floating terminal (docs/omarchy-plugins.md section 3), as StartDrive does.
apply_priv_exec() {
  if apply_in_terminal; then
    bash -c "$1"
  else
    "$(apply_float)" "$1"
  fi
}

# apply_priv_line CMD : what apply_priv_exec will run, as shown to the user
apply_priv_line() {
  if apply_in_terminal; then
    printf '%s' "$1"
  else
    apply_q "$(apply_float)" "$1"
  fi
}

# ---- stage routing -------------------------------------------------------------------------------------------------

# apply_stage_of CATEGORY TYPE : the stage that applies such an item; empty when none does 
apply_stage_of() {
  case $1:$2 in
    package:pacman | package:aur) echo packages ;;
    plugin:*) echo plugins ;;
    config:*) echo config ;;
    service:*) echo services ;;
    registry-tool:*) echo registry ;;
    repo-tool:*) echo repos ;;
  esac
  return 0
}

# apply_has_stage NAME : true when NAME is in APPLY_STAGES and its apply_stage_NAME function exists
apply_has_stage() {
  local s
  for s in "${APPLY_STAGES[@]}"; do
    [[ $s == "$1" ]] && declare -F "apply_stage_$1" >/dev/null && return 0
  done
  return 1
}

# ---- reconcile -----------------------------------------------------------------------------------------------------

# Overlapping items from different scanners (pacman:rust and mise:rust, a launcher and its package, docs/ROADMAP.md) are
# collapsed to one: the highest provenance confidence wins, then install type pacman > aur > mise > uv > pipx > cargo > go
# > npm; a launcher always loses to a real install.
# shellcheck disable=SC2016 # jq program, not shell
_APPLY_RECONCILE_JQ='
def rank: if .category == "launcher" then 10 else ({pacman:0, aur:1, mise:2, uv:3, pipx:4, cargo:5, go:6, npm:7}[.install.type] // 9) end;
def key:
  if .category == "launcher" then (.id | sub("^launcher:"; "") | sub("\\.desktop$"; "") | ascii_downcase)
  elif (.category == "package" or .category == "registry-tool") then
    ((.install.package // .install.crate // .install.module // .install.tool // "")
     | sub("@[^@/]*$"; "") | sub("^[^:/@]*:"; "") | split("/") | last | ascii_downcase)
  else "" end;
. as $all
| ($all | map({id: .id, k: key, s: [-(.provenance.confidence // 0), rank]})) as $ks
| ($ks | map(select(.k != "")) | group_by(.k) | map(sort_by(.s))
   | map(. as $g | $g[1:] | map({id: .id, by: $g[0].id})) | add // []) as $dropped
| {keep: ($all | map(select(.id as $i | $dropped | map(.id) | index($i) | not))), dropped: $dropped}'

# apply_reconcile ITEMS_JSON : prints {keep: [items], dropped: [{id, by}]}
apply_reconcile() { jq -c "$_APPLY_RECONCILE_JQ" <<<"$1"; }

# ---- per-item planners (registry and repo tools) -------------------------------------------------------------------
# apply_plan_<type> ITEM_JSON sets APPLY_CMDS / APPLY_CODE / APPLY_NOTE and returns 0 (run it), 10 (already present, note
# says why) or 11 (skip, note says why).

# apply_need MANAGER : 11 with a note when the manager binary is missing
apply_need() { command -v "$1" >/dev/null 2>&1 || { APPLY_NOTE="$1 not found on PATH"; return 11; }; }

# apply_bad FIELD : reject a manifest value that fails validation
apply_bad() { APPLY_NOTE="invalid $1 in manifest"; return 11; }

# apply_ver_opt_ok V : V is empty or a valid version
apply_ver_opt_ok() { [[ -z $1 ]] || apply_ver_ok "$1"; }

apply_plan_cargo() {
  local p v locked
  p=$(apply_f "$1" .install.crate) v=$(apply_f "$1" .version) locked=$(apply_f "$1" .install.locked)
  apply_name_ok "$p" || { apply_bad crate; return; }
  apply_ver_opt_ok "$v" || { apply_bad version; return; }
  apply_need cargo || return
  if cargo install --list 2>/dev/null | awk -v p="$p" '$1 == p && $2 ~ /^v/ { f = 1 } END { exit !f }'; then APPLY_NOTE="already installed"; return 10; fi
  local a=(cargo install)
  [[ $locked == true ]] && a+=(--locked)
  [[ -n $v ]] && a+=(--version "$v")
  APPLY_CMDS=("$(apply_q "${a[@]}" "$p")")
}

apply_plan_go() {
  local m v bin dir
  m=$(apply_f "$1" .install.module) v=$(apply_f "$1" .version)
  apply_name_ok "$m" || { apply_bad module; return; }
  apply_ver_opt_ok "$v" || { apply_bad version; return; }
  apply_need go || return
  bin=${m##*/}
  dir=${GOBIN:-${GOPATH:+${GOPATH%%:*}/bin}}
  dir=${dir:-$HOME/go/bin}
  if [[ -x $dir/$bin ]]; then APPLY_NOTE="already installed"; return 10; fi
  APPLY_CMDS=("$(apply_q go install "$m@${v:-latest}")")
}

apply_plan_npm() {
  local p v
  p=$(apply_f "$1" .install.package) v=$(apply_f "$1" .version)
  apply_name_ok "$p" || { apply_bad package; return; }
  apply_ver_opt_ok "$v" || { apply_bad version; return; }
  apply_need npm || return
  if npm ls -g --depth=0 "$p" >/dev/null 2>&1; then APPLY_NOTE="already installed"; return 10; fi
  APPLY_CMDS=("$(apply_q npm install -g "$p${v:+@$v}")")
}

# apply_plan_pyvenv TOOL ITEM_JSON : uv and pipx share their shape
apply_plan_pyvenv() {
  local t=$1 p v
  p=$(apply_f "$2" .install.package) v=$(apply_f "$2" .version)
  apply_name_ok "$p" || { apply_bad package; return; }
  apply_ver_opt_ok "$v" || { apply_bad version; return; }
  apply_need "$t" || return
  if [[ $t == uv ]]; then
    if uv tool list 2>/dev/null | awk -v p="$p" '$1 == p { f = 1 } END { exit !f }'; then APPLY_NOTE="already installed"; return 10; fi
    APPLY_CMDS=("$(apply_q uv tool install "$p${v:+==$v}")")
  else
    if pipx list --short 2>/dev/null | awk -v p="$p" '$1 == p { f = 1 } END { exit !f }'; then APPLY_NOTE="already installed"; return 10; fi
    APPLY_CMDS=("$(apply_q pipx install "$p${v:+==$v}")")
  fi
}
apply_plan_uv() { apply_plan_pyvenv uv "$1"; }
apply_plan_pipx() { apply_plan_pyvenv pipx "$1"; }

apply_plan_mise() {
  local t v
  t=$(apply_f "$1" .install.tool) v=$(apply_f "$1" .version)
  apply_name_ok "$t" || { apply_bad tool; return; }
  apply_ver_opt_ok "$v" || { apply_bad version; return; }
  apply_need mise || return
  if [[ -n $(mise ls --installed "$t" 2>/dev/null) ]]; then APPLY_NOTE="already installed"; return 10; fi
  APPLY_CMDS=("$(apply_q mise use -g "$t${v:+@$v}")")
}

# Source builds: clone (checkout the recorded ref), then run the recorded build commands. The build commands are arbitrary
# code from the manifest, so they are shown and confirmed like everything else; an unpinned clone is called out.
apply_plan_git_build() {
  local url ref dir name b
  url=$(apply_f "$1" .install.url) ref=$(apply_f "$1" .install.ref)
  apply_git_url_ok "$url" || { apply_bad url; return; }
  [[ -z $ref ]] || { apply_name_ok "$ref" && [[ $ref != -* ]]; } || { apply_bad ref; return; }
  apply_need git || return
  name=$(basename -- "${url%.git}")
  apply_name_ok "$name" || { apply_bad url; return; }
  dir=${STARTKIN_SRC_DIR:-$HOME/.local/src}/$name
  if [[ -d $dir/.git ]]; then APPLY_NOTE="source already cloned at $dir; not rebuilt"; return 10; fi
  APPLY_CODE=1
  APPLY_CMDS=("$(apply_q git clone -- "$url" "$dir")")
  if [[ -n $ref ]]; then APPLY_CMDS+=("$(apply_q git -C "$dir" checkout "$ref")"); else APPLY_NOTE="unpinned: no ref recorded, builds the default branch (needs --allow-unpinned or an interactive yes)"; APPLY_CONSENT=unpinned; fi
  while IFS= read -r b; do
    [[ -n $b ]] && APPLY_CMDS+=("cd $(apply_q "$dir") && $b")
  done < <(jq -r '.install.build // [] | .[]' <<<"$1")
}

# apply_plan_download TYPE ITEM_JSON : release-binary and appimage. Raw binaries only (archives are not unpacked).
apply_plan_download() {
  local url sha dest name
  url=$(apply_f "$2" .install.url) sha=$(apply_f "$2" .install.sha256) dest=$(apply_f "$2" .install.dest)
  apply_url_ok "$url" || { apply_bad url; return; }
  [[ -z $sha ]] || [[ $sha =~ ^[0-9a-fA-F]{64}$ ]] || { apply_bad sha256; return; }
  name=$(basename -- "${url%%[?#]*}")
  apply_name_ok "$name" || { apply_bad url; return; }
  case ${name,,} in
    *.tar.* | *.tgz | *.zip | *.gz | *.xz | *.bz2 | *.zst | *.deb | *.rpm) APPLY_NOTE="release is an archive or package; only raw binaries are installed"; return 11 ;;
  esac
  dest=$(apply_path "${dest:-~/.local/bin/$name}")
  apply_home_path_ok "$dest" || { APPLY_NOTE="destination must be inside home: ${dest}"; return 11; }
  if [[ -e $dest ]]; then APPLY_NOTE="$dest exists"; return 10; fi
  apply_need curl || return
  apply_tmpdir || return 11
  APPLY_CODE=1
  APPLY_CMDS=("$(apply_q curl -fsSL -o "$APPLY_TMP/$name" -- "$url")")
  if [[ -n $sha ]]; then
    APPLY_CMDS+=("cd $(apply_q "$APPLY_TMP") && printf '%s  %s\\n' $(apply_q "${sha,,}" "$name") | sha256sum -c -")
  else
    APPLY_NOTE="no sha256 recorded: the download is not verified (needs --allow-unpinned or an interactive yes)"
    APPLY_CONSENT=unpinned
  fi
  APPLY_CMDS+=("$(apply_q install -Dm755 "$APPLY_TMP/$name" "$dest")")
}
apply_plan_release_binary() { apply_plan_download release-binary "$1"; }
apply_plan_appimage() { apply_plan_download appimage "$1"; }

# copy: a binary or file that exists only on the source machine. Fetched over scp from the peer given with --from-peer.
apply_plan_copy() {
  local src dest host rel hopt
  src=$(apply_f "$1" .install.path) dest=$(apply_f "$1" '.install.dest // .install.path')
  [[ $src == "$APPLY_TILDE/"* ]] || { APPLY_NOTE="source path is not under the source home"; return 11; }
  apply_relpath_ok "${src#"$APPLY_TILDE/"}" || { apply_bad path; return; }
  dest=$(apply_path "$dest")
  apply_home_path_ok "$dest" || { APPLY_NOTE="destination must be inside home: ${dest}"; return 11; }
  if [[ -e $dest ]]; then APPLY_NOTE="$dest exists"; return 10; fi
  if [[ -z $APPLY_PEER ]]; then APPLY_NOTE="the file only exists on the source machine; apply with --from-peer to copy it"; return 11; fi
  host=$(apply_peer_host "$APPLY_PEER") || { APPLY_NOTE="cannot resolve peer $APPLY_PEER"; return 11; }
  hopt=$(peers_scp_opts "$host")
  rel=${src#"$APPLY_TILDE/"}
  APPLY_CODE=1
  APPLY_CMDS=("$(apply_q mkdir -p -- "$(dirname -- "$dest")")"
    "$(apply_q "${STARTKIN_SCP:-scp}" -p -o BatchMode=yes ${hopt:+"$hopt"} -- "$host:$rel" "$dest")")
}

apply_plan_script() { APPLY_NOTE="script installs are not applied automatically; run it yourself after reviewing it"; return 11; }
apply_plan_unknown() { APPLY_NOTE="no install method recorded; run 'startkin adopt' on the source machine"; return 11; }

# apply_peer_host PEER : the host peers_fetch would connect to
apply_peer_host() {
  local row
  row=$(peers_table | jq -r --arg n "$1" 'map(select((.name | ascii_downcase) == ($n | ascii_downcase))) | first | if . == null then empty else (.short // "") + "\t" + .host end') || return 1
  [[ -n $row ]] || return 1
  peers_target "${row#*$'\t'}" "${row%%$'\t'*}"
  printf '%s' "$PEERS_HOST"
}

# apply_plan ITEM_JSON : dispatch on the install type; unknown types are skipped
apply_plan() {
  local t fn
  APPLY_CMDS=() APPLY_CODE=0 APPLY_NOTE="" APPLY_CONSENT=""
  t=$(apply_f "$1" .install.type)
  fn=apply_plan_${t//-/_}
  if [[ -n $t ]] && declare -F "$fn" >/dev/null; then "$fn" "$1"; else APPLY_NOTE="no installer for type '$t'"; return 11; fi
}

# apply_run_items ITEMS_JSON : generic stage body. Plan each item, show its commands, confirm, run, report.
apply_run_items() {
  local item id rc c ok
  while IFS= read -r -u 3 item; do
    id=$(apply_f "$item" .id)
    apply_plan "$item"
    rc=$?
    case $rc in
      10) apply_record "$id" present "$APPLY_NOTE"; continue ;;
      0) ;;
      *) apply_record "$id" skipped "$APPLY_NOTE"; continue ;;
    esac
    printf '  %s%s\n' "$id" "$([[ $APPLY_CODE == 1 ]] && echo ' [runs downloaded code]')"
    [[ -n $APPLY_NOTE ]] && printf '    note: %s\n' "$APPLY_NOTE"
    apply_show "${APPLY_CMDS[@]}"
    if ((APPLY_DRY)); then apply_record "$id" planned ""; continue; fi
    if ! apply_confirm_for "$APPLY_CONSENT" "Run this?"; then apply_record "$id" skipped "not confirmed"; continue; fi
    ok=1
    for c in "${APPLY_CMDS[@]}"; do bash -c "$c" || { ok=0; break; }; done
    if ((ok)); then apply_record "$id" installed ""; else apply_record "$id" failed "command failed"; fi
  done 3< <(jq -c '.[]' <<<"$1")
}

apply_stage_registry() { apply_run_items "$1"; }
apply_stage_repos() { apply_run_items "$1"; }

# ---- packages stage ------------------------------------------------------------------------------------------------

# apply_aur_helper ITEMS_JSON : the helper named in the manifest if installed here, else yay or paru; empty when none
apply_aur_helper() {
  local h
  for h in $(jq -r '[.[].install.helper // empty] | unique | .[]' <<<"$1") yay paru; do
    apply_name_ok "$h" && command -v "$h" >/dev/null 2>&1 && { echo "$h"; return 0; }
  done
  return 1
}

# apply_pkg_batch KIND ITEMS_JSON : install every missing package of KIND (pacman | aur) with one command (one sudo prompt)
apply_pkg_batch() {
  local kind=$1 item id pkg line cmd ids=() pkgs=() helper="" a
  while IFS= read -r item; do
    id=$(apply_f "$item" .id) pkg=$(apply_f "$item" .install.package)
    if ! apply_name_ok "$pkg" || [[ $pkg == */* ]]; then apply_record "$id" skipped "invalid package in manifest"; continue; fi
    if pacman -Qq -- "$pkg" >/dev/null 2>&1; then
      apply_record "$id" present "$(apply_present_note)"
      continue
    fi
    ids+=("$id") pkgs+=("$pkg")
  done < <(jq -c --arg k "$kind" '.[] | select(.install.type == $k)' <<<"$2")
  ((${#pkgs[@]})) || return 0

  if [[ $kind == pacman ]]; then
    if command -v "$(apply_omarchy)" >/dev/null 2>&1; then a=("$(apply_omarchy)" pkg add "${pkgs[@]}"); else a=(sudo pacman -S --needed -- "${pkgs[@]}"); fi
  else
    if command -v "$(apply_omarchy)" >/dev/null 2>&1; then
      a=("$(apply_omarchy)" pkg aur add "${pkgs[@]}")
    elif helper=$(apply_aur_helper "$2"); then
      a=("$helper" -S --needed -- "${pkgs[@]}")
    else
      for id in "${ids[@]}"; do apply_record "$id" skipped "no AUR helper (omarchy, yay or paru) found"; done
      return 0
    fi
  fi
  cmd=$(apply_q "${a[@]}")
  line=$(apply_priv_line "$cmd")
  if [[ $kind == aur ]]; then printf '  AUR packages build from PKGBUILDs written by their maintainers [runs downloaded code]\n'; fi
  printf '  %s: %s\n' "$kind" "${pkgs[*]}"
  apply_show "$line"
  if ((APPLY_DRY)); then for id in "${ids[@]}"; do apply_record "$id" planned ""; done; return 0; fi
  if ! apply_confirm "Run this?"; then
    for id in "${ids[@]}"; do apply_record "$id" skipped "not confirmed"; done
    return 0
  fi
  apply_priv_exec "$cmd" || true
  # The exit status of a floating terminal says little: check what is actually installed.
  local i
  for i in "${!pkgs[@]}"; do
    if pacman -Qq -- "${pkgs[$i]}" >/dev/null 2>&1; then apply_record "${ids[$i]}" installed ""; else apply_record "${ids[$i]}" failed "not installed afterwards"; fi
  done
}

# apply_present_note : why "already installed" may be a surprise when the Omarchy versions differ
apply_present_note() {
  if [[ $APPLY_DRIFT == same || -z $APPLY_DRIFT ]]; then echo "already installed"; else echo "already installed or now in Omarchy defaults"; fi
}

apply_stage_packages() {
  apply_pkg_batch pacman "$1"
  apply_pkg_batch aur "$1"
}

# ---- driver --------------------------------------------------------------------------------------------------------

APPLY_USAGE='Usage: startkin apply MANIFEST | --from-peer PEER [--dry-run] [--yes] [--only IDS]
                     [--allow-plugins] [--allow-machine-specific] [--allow-units] [--allow-unpinned]
  MANIFEST         a manifest file (startkin export --out FILE)
  --from-peer PEER fetch the manifest from a Tailscale peer (startkin peers); also the source of config file contents
  --dry-run        show every command; install nothing, ask nothing
  --yes            pre-approve every ordinary "Run this?" prompt (packages, registry tools, pinned builds and verified
                   downloads, services from packages); read a --dry-run first
  --only IDS       comma-separated item ids to apply
  --allow-plugins  also pre-approve plugin installs (unsandboxed code; --yes alone still asks)
  --allow-machine-specific
                   also pre-approve overwriting machine-specific config (monitors, GPU settings); --yes alone still asks
  --allow-units    also pre-approve copied user systemd unit files (enabled and started); --yes alone still asks
  --allow-unpinned also pre-approve git builds with no recorded ref and downloads with no sha256; --yes alone still asks
  Config files are shown as a diff, backed up, and can be undone with: startkin rollback [ID|latest]'

# apply_stage_title NAME : heading shown before a stage
apply_stage_title() {
  case $1 in
    packages) echo "Packages (pacman, AUR)" ;;
    registry) echo "Registry tools (cargo, go, npm, uv, pipx, mise)" ;;
    repos) echo "Tools from repos (git builds, release binaries, AppImages, copies)" ;;
    plugins) echo "Omarchy plugins" ;;
    config) echo "Config files (diff, backup, rollback)" ;;
    services) echo "systemd services" ;;
    *) echo "$1" ;;
  esac
}

# apply_load_manifest FILE : check FILE is a usable manifest (schema 1.x, items with id/category/install)
apply_load_manifest() {
  [[ -f $1 && -r $1 ]] || die "apply: cannot read manifest: $1"
  jq -e 'type == "object" and ((.schema_version // "" | tostring | startswith("1.")))
         and (.items | type == "array") and (.machine | type == "object")
         and all(.items[]; type == "object" and (.id | type == "string") and (.category | type == "string")
                           and (.install | type == "object") and (.install.type | type == "string"))
         and ((.items | map(.id) | unique | length) == (.items | length))' "$1" >/dev/null 2>&1 ||
    die -c 15 "apply: $1 is not a usable StartKin manifest (needs schema 1.x, machine, unique item ids, each with category and install.type)"
}

# apply_main MANIFEST_FILE ONLY : selection, target check, reconcile, then the stages in order. Returns 1 if any item failed.
apply_main() {
  local manifest=$1 only=$2 target checks items sel rc=0 id reasons stage s st n rec dropped by
  local -A bucket=()

  drift_check_manifest "$manifest"
  APPLY_DRIFT=$(drift_compare_machines "$(jq -c .machine "$manifest")" "$(machine_json)")
  printf 'Manifest from %s (Omarchy %s), generated %s\n' \
    "$(jq -r .machine.hostname "$manifest")" "$(jq -r .machine.omarchy_version "$manifest")" "$(jq -r '.generated_at // "unknown"' "$manifest")"

  items=$(jq -c '.items' "$manifest")
  if [[ -n $only ]]; then
    for id in ${only//,/ }; do
      jq -e --arg i "$id" 'any(.[]; .id == $i)' <<<"$items" >/dev/null || die -c 2 "apply: --only: no such item in the manifest: $id"
    done
    items=$(jq -c --arg o "$only" '($o | split(",")) as $ids | map(select(.id as $i | $ids | index($i)))' <<<"$items")
  fi

  # Target awareness (#15): incompatible items are skipped and reported, warn items are flagged.
  target=$(machine_json_with_libc)
  checks=$(target_check_manifest "$manifest" "$target") || die "apply: target check failed"
  while IFS=$'\t' read -r id reasons; do
    apply_record "$id" skipped "incompatible with this machine: $reasons"
  done < <(jq -r --argjson sel "$(jq -c 'map(.id)' <<<"$items")" \
    '.items[] | select(.status == "incompatible" and (.id as $i | $sel | index($i))) | [.id, (.reasons | map(.message) | join("; "))] | @tsv' <<<"$checks")
  APPLY_WARN_IDS=$(jq -r '.items[] | select(.status == "warn") | [.id, (.reasons | map(.message) | join("; "))] | @tsv' <<<"$checks")
  items=$(jq -c --argjson c "$checks" '($c.items | map(select(.status == "incompatible") | .id)) as $bad | map(select(.id as $i | $bad | index($i) | not))' <<<"$items")

  rec=$(apply_reconcile "$items")
  items=$(jq -c .keep <<<"$rec")
  while IFS=$'\t' read -r id by; do
    apply_record "$id" skipped "duplicate of $by"
  done < <(jq -r '.dropped[] | [.id, .by] | @tsv' <<<"$rec")
  dropped=$(jq '.dropped | length' <<<"$rec")
  ((dropped)) && log "reconciled $dropped overlapping item(s) from different scanners"

  # Route to stages. Items nothing applies are reported, not silently dropped.
  local -A warn_of=()
  while IFS=$'\t' read -r id reasons; do [[ -n $id ]] && warn_of[$id]=$reasons; done <<<"$APPLY_WARN_IDS"
  while IFS= read -r sel; do
    id=$(apply_f "$sel" .id)
    stage=$(apply_stage_of "$(apply_f "$sel" .category)" "$(apply_f "$sel" .install.type)")
    if [[ -n $stage ]] && apply_has_stage "$stage"; then
      bucket[$stage]+="$sel"$'\n'
    else
      apply_record "$id" skipped "no apply stage for ${stage:-this kind of item} yet"
    fi
  done < <(jq -c '.[]' <<<"$items")

  for s in "${APPLY_STAGES[@]}"; do
    [[ -n ${bucket[$s]:-} ]] || continue
    n=$(grep -c . <<<"${bucket[$s]}")
    printf '\n== %s: %d item(s)\n' "$(apply_stage_title "$s")" "$n"
    while IFS= read -r sel; do
      [[ -n $sel ]] || continue
      id=$(apply_f "$sel" .id)
      [[ -z ${warn_of[$id]:-} ]] || printf '  warning: %s: %s\n' "$id" "${warn_of[$id]}"
    done <<<"${bucket[$s]}"
    st=$(jq -sc '.' <<<"${bucket[$s]}")
    "apply_stage_$s" "$st" || rc=1
  done

  apply_summary || rc=1
  return "$rc"
}

# apply_summary : counts per status; 1 when anything failed
apply_summary() {
  local c
  printf '\nSummary:'
  for c in installed present planned skipped failed; do
    printf ' %s %d;' "$c" "$(awk -F'\t' -v s="$c" '$2 == s' "$APPLY_RES" | grep -c .)"
  done
  printf '\n'
  ((APPLY_DRY)) && printf '(dry run: nothing was installed)\n'
  backup_summary
  ! grep -q $'\tfailed\t' "$APPLY_RES"
}

cmd_apply() {
  local file="" only="" tmp="" rc
  APPLY_DRY=0 APPLY_YES=0 APPLY_PEER="" APPLY_ALLOW_PLUGINS=0 APPLY_ALLOW_MACHINE=0 APPLY_ALLOW_UNITS=0 APPLY_ALLOW_UNPINNED=0
  while (($#)); do
    case $1 in
      -h | --help) echo "$APPLY_USAGE"; return 0 ;;
      --dry-run) APPLY_DRY=1 ;;
      --yes | -y) APPLY_YES=1 ;;
      --allow-plugins) APPLY_ALLOW_PLUGINS=1 ;;
      --allow-machine-specific) APPLY_ALLOW_MACHINE=1 ;;
      --allow-units) APPLY_ALLOW_UNITS=1 ;;
      --allow-unpinned) APPLY_ALLOW_UNPINNED=1 ;;
      --from-peer | --only)
        (($# >= 2)) || die -c 2 "apply: $1 needs a value"
        if [[ $1 == --only ]]; then only=$2; else APPLY_PEER=$2; fi
        shift ;;
      -*) die -c 2 "apply: unknown option: $1" ;;
      *) [[ -z $file ]] || die -c 2 "apply: more than one manifest given"; file=$1 ;;
    esac
    shift
  done
  [[ -n $file || -n $APPLY_PEER ]] || { echo "$APPLY_USAGE" >&2; return 2; }
  [[ -z $file || -z $APPLY_PEER ]] || die -c 2 "apply: give a manifest file or --from-peer, not both"
  require_cmd jq

  backup_reset
  APPLY_RES=$(mktemp) || return 1
  tmp=$(mktemp) || return 1
  if [[ -n $APPLY_PEER ]]; then
    # peers_fetch exits through die on failure, so it runs in a subshell and its status is passed on.
    (peers_fetch "$APPLY_PEER") >"$tmp" || { rc=$?; rm -f "$APPLY_RES" "$tmp"; return "$rc"; }
    file=$tmp
  fi
  (apply_load_manifest "$file") || { rc=$?; rm -f "$APPLY_RES" "$tmp"; return "$rc"; }
  apply_main "$file" "$only"
  rc=$?
  apply_cleanup
  rm -f "$APPLY_RES" "$tmp"
  return "$rc"
}
