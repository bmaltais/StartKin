#!/usr/bin/env bash
# `startkin apply` stages for plugins, config and services (#14). Contract: docs/engine.md "Apply".
# Needs lib/apply.sh (the driver and its helpers), lib/backup.sh and lib/secrets.sh. Source this after apply.sh.
# shellcheck shell=bash
# shellcheck disable=SC2034 # APPLY_CODE and APPLY_CONSENT are read by apply_run_items in lib/apply.sh

# shellcheck source=secrets.sh
source "$STARTKIN_ROOT/lib/secrets.sh"

# ---- plugins -------------------------------------------------------------------------------------------------------

apply_plugins_dir() { echo "${STARTKIN_PLUGINS_DIR:-$HOME/.config/omarchy/plugins}"; }

# apply_plan_plugin ITEM_JSON : `omarchy plugin add URL --yes`, then `git checkout REV` when a rev was recorded, then
# `omarchy plugin enable ID` when it was enabled on the source. Enabling comes last so unpinned code never runs: a failed
# checkout stops the chain (the item is `failed`) and the plugin stays installed but disabled. Plugins are unsandboxed code
# (docs/omarchy-plugins.md section 5), so the URL is shown and each install needs its own consent (--allow-plugins).
apply_plan_plugin() {
  local id src rev a dir
  id=$(apply_f "$1" .install.plugin_id) src=$(apply_f "$1" .install.source)
  { apply_name_ok "$id" && [[ $id != */* ]]; } || { apply_bad plugin_id; return; }
  apply_git_url_ok "$src" || { apply_bad source; return; }
  dir=$(apply_plugins_dir)/$id
  if [[ -e $dir ]]; then APPLY_NOTE="plugin folder exists"; return 10; fi
  command -v "$(apply_omarchy)" >/dev/null 2>&1 || { APPLY_NOTE="omarchy not found on PATH"; return 11; }
  a=("$(apply_omarchy)" plugin add "$src" --yes)
  APPLY_CODE=1 APPLY_CONSENT=plugins
  APPLY_CMDS=("$(apply_q "${a[@]}")")
  rev=$(jq -r '.provenance.evidence // [] | map(select(startswith("rev "))) | first // "" | ltrimstr("rev ")' <<<"$1")
  if [[ $rev =~ ^[0-9a-fA-F]{40}$ ]]; then
    APPLY_CMDS+=("$(apply_q git -C "$dir" checkout "$rev")")
  else
    APPLY_NOTE="no revision recorded: installs the default branch"
  fi
  if jq -e '.provenance.evidence // [] | index("enabled in shell.json")' <<<"$1" >/dev/null; then
    APPLY_CMDS+=("$(apply_q "$(apply_omarchy)" plugin enable "$id")")
  fi
  APPLY_NOTE+="${APPLY_NOTE:+; }needs the Omarchy shell running"
}

# Plugin items: git installs are added from their URL; plain copies are fetched from the peer like config; the rest skipped.
apply_stage_plugins() {
  local item
  while IFS= read -r -u 4 item; do
    case $(apply_f "$item" .install.type) in
      copy)
        apply_copy_item "$item" "$(apply_plugins_dir)" plugins
        apply_record "$(apply_f "$item" .id)" "$APPLY_COPY_RESULT" "$APPLY_COPY_DETAIL"
        ;;
      *) apply_run_items "[$item]" ;;
    esac
  done 4< <(jq -c '.[]' <<<"$1")
}

# ---- copying files from the peer, with preview and backup ------------------------------------------------------------
# Config items carry no content in the manifest (docs/design.md "AI boundary", docs/secrets-policy.md): the file is read from
# the source machine at apply time, with scp over the peers transport (--from-peer). Nothing is fetched in a dry run.

# Result of the last apply_copy_item: installed | present | planned | skipped | failed, and a reason.
APPLY_COPY_RESULT="" APPLY_COPY_DETAIL=""

# apply_copy_end RESULT [DETAIL] : set the result
apply_copy_end() { APPLY_COPY_RESULT=$1 APPLY_COPY_DETAIL=${2:-}; return 0; }

# apply_secrets_check STAGED BASE : the secrets policy over fetched content. Every path (as it would sit under BASE) against
# the path categories (hardware is a consent matter handled by the caller) and every file against the content patterns.
# Prints kind and line only, never content. Returns 1 when anything was found.
apply_secrets_check() {
  local dir=$1 base=$2 f rel cat kind line bad=0
  while IFS= read -r -d '' f; do
    rel=${f#"$dir"}
    if cat=$(secrets_path_denied "$base$rel") && [[ $cat != hardware ]]; then
      printf 'denied path (%s)\n' "$cat"
      bad=1
      continue
    fi
    while IFS=$'\t' read -r kind line; do
      [[ -n $kind ]] || continue
      printf '%s at line %s\n' "$kind" "$line"
      bad=1
    done < <(secrets_scan_file "$f")
  done < <(find "$dir" -type f -print0)
  return "$bad"
}

# apply_diff_preview DEST STAGED LABEL : the changes, capped; paths shown as ~ and peer:LABEL, never absolute home paths
apply_diff_preview() {
  local out n max=120
  out=$(diff -ru -- "$1" "$2" 2>&1 | sed "s|$2|peer:$3|g")
  out=$(tilde_text "$out")
  n=$(grep -c '' <<<"$out")
  head -n "$max" <<<"$out" | sed 's/^/    /'
  if ((n > max)); then printf '    ... %d more line(s)\n' "$((n - max))"; fi
  return 0
}

# apply_machine_reasons ITEM_JSON REL : print why a file is machine-specific, one reason per line
apply_machine_reasons() {
  jq -r '.provenance.evidence // [] | .[] | select(startswith("machine-specific: ")) | ltrimstr("machine-specific: ")' <<<"$1"
  if [[ $(jq -r '.private // false' <<<"$1") == true ]] && ! jq -e '.provenance.evidence // [] | any(startswith("machine-specific: "))' <<<"$1" >/dev/null; then
    echo "marked private"
  fi
  case ${2##*/} in monitors.* | kanshi*) echo "monitor layout" ;; esac
  return 0
}

# apply_copy_item ITEM_JSON ROOT [CLASS] : apply one `copy` item whose destination must be inside ROOT; sets APPLY_COPY_RESULT.
# CLASS is a consent class --yes does not cover (plugins, units; see apply_confirm_for), added to machine when that applies.
# Flow: validate, policy checks, fetch from the peer, secrets check, diff, consent, backup, install.
apply_copy_item() {
  local item=$1 root=$2 class=${3:-} id src dest rel host hopt stage cat="" machine=0 why=() flagged r found preview=1
  id=$(apply_f "$item" .id)
  src=$(apply_f "$item" .install.path) dest=$(apply_f "$item" '.install.dest // .install.path')
  [[ $src == "$APPLY_TILDE/"* ]] || { apply_copy_end skipped "source path is not under the source home"; return 0; }
  rel=${src#"$APPLY_TILDE/"}
  apply_relpath_ok "$rel" || { apply_copy_end skipped "invalid path in manifest"; return 0; }
  dest=$(apply_path "$dest")
  if ! apply_home_path_ok "$dest" || [[ $dest != "$root"/* ]] || ! apply_resolved_under "$dest" "$root"; then
    apply_copy_end skipped "destination must be inside $(tilde_text "$root")/"
    return 0
  fi
  [[ ! -L $dest ]] || { apply_copy_end skipped "destination is a symlink"; return 0; }

  # Keys, tokens and the like are never applied (secrets-policy.md rule 1, no override). Hardware files (monitors) and files
  # the scanner marked private need explicit consent: --allow-machine-specific or a typed yes; --yes does not cover them.
  if cat=$(secrets_path_denied "$dest") || cat=$(secrets_path_denied "$HOME/$rel"); then
    if [[ $cat == hardware ]]; then why+=("hardware file"); else apply_copy_end skipped "denied by the secrets policy ($cat)"; return 0; fi
  fi
  flagged=$(jq -r '.provenance.evidence // [] | map(select(startswith("content flagged"))) | length' <<<"$item")
  if ((flagged)); then apply_copy_end skipped "the scan flagged secret-like content in it; move it by hand"; return 0; fi
  while IFS= read -r r; do [[ -n $r ]] && why+=("$r"); done < <(apply_machine_reasons "$item" "$rel")
  if ((${#why[@]})); then machine=1; fi

  if [[ -z $APPLY_PEER ]]; then
    apply_copy_end skipped "the manifest holds no file contents; apply with --from-peer to fetch them from the source machine"
    return 0
  fi
  host=$(apply_peer_host "$APPLY_PEER") || { apply_copy_end skipped "cannot resolve peer $APPLY_PEER"; return 0; }
  hopt=$(peers_scp_opts "$host")

  printf '  %s%s\n' "$id" "$([[ -e $dest ]] && echo ' [replaces an existing file]')"
  if ((machine)); then printf '    machine-specific (%s): needs its own consent\n' "$(IFS=,; echo "${why[*]}")"; fi
  if ((APPLY_DRY)); then
    printf '    would fetch %s from %s, show the diff, back up %s, then install\n' "$src" "$APPLY_PEER" "$(tilde_text "$dest")"
    apply_copy_end planned
    return 0
  fi

  apply_tmpdir || { apply_copy_end failed "no temp dir"; return 0; }
  stage=$(mktemp -d "$APPLY_TMP/stage.XXXXXX") || { apply_copy_end failed "no temp dir"; return 0; }
  if ! "${STARTKIN_SCP:-scp}" -r -p -o BatchMode=yes ${hopt:+"$hopt"} -- "$host:$rel" "$stage/f" >/dev/null 2>&1 || [[ ! -e $stage/f ]]; then
    apply_copy_end failed "could not fetch $src from $APPLY_PEER"
    return 0
  fi
  if [[ -L $stage/f || -n $(find "$stage/f" -type l -print -quit) ]]; then
    apply_copy_end skipped "fetched content holds a symlink"
    return 0
  fi
  if [[ -e $dest ]] && { [[ -d $dest && ! -d $stage/f ]] || [[ ! -d $dest && -d $stage/f ]]; }; then
    apply_copy_end skipped "a file and a directory of the same name"
    return 0
  fi
  if ! found=$(apply_secrets_check "$stage/f" "$dest"); then
    apply_copy_end skipped "fetched content failed the secrets check: $(paste -sd';' <<<"$found" | sed 's/;/; /g')"
    return 0
  fi

  if [[ -e $dest ]]; then
    if diff -rq -- "$dest" "$stage/f" >/dev/null 2>&1; then apply_copy_end present "identical"; return 0; fi
    # A diff prints the old text too: when the file already on this machine holds secret-like content, show no diff.
    if ! apply_secrets_check "$dest" "$dest" >/dev/null || { [[ -f $dest ]] && ! secrets_scan_file "$dest" >/dev/null; }; then preview=0; fi
  fi
  if [[ ! -e $dest ]]; then
    printf '    new: %s\n' "$(tilde_text "$dest")"
    if [[ -d $stage/f ]]; then (cd "$stage/f" && find . -type f | LC_ALL=C sort | head -n 20 | sed 's|^\./|      + |'); fi
  elif ((preview)); then
    apply_diff_preview "$dest" "$stage/f" "$rel"
  else
    printf '    the file on this machine holds secret-like content: diff withheld\n'
    machine=1
  fi

  ((machine)) && class+="${class:+ }machine"
  if ! apply_confirm_for "$class" "Install this?"; then
    apply_copy_end skipped "not confirmed"
    return 0
  fi
  backup_save "$dest" || { apply_copy_end failed "could not write the backup; nothing changed"; return 0; }
  backup_mkdir_p "$(dirname -- "$dest")" || { apply_copy_end failed "could not create the directory; undo with startkin rollback $(backup_id)"; return 0; }
  if [[ -d $stage/f && -d $dest ]]; then
    cp -a -- "$stage/f/." "$dest/" || { apply_copy_end failed "copy failed; undo with startkin rollback $(backup_id)"; return 0; }
  else
    cp -a -- "$stage/f" "$dest" || { apply_copy_end failed "copy failed; undo with startkin rollback $(backup_id)"; return 0; }
  fi
  backup_note_after "$dest"
  apply_copy_end installed
}

# ---- config --------------------------------------------------------------------------------------------------------

apply_stage_config() {
  local item
  while IFS= read -r -u 4 item; do
    apply_copy_item "$item" "$HOME/.config"
    apply_record "$(apply_f "$item" .id)" "$APPLY_COPY_RESULT" "$APPLY_COPY_DETAIL"
  done 4< <(jq -c '.[]' <<<"$1")
}

# ---- services ------------------------------------------------------------------------------------------------------
# A service item is an enabled systemd unit. `pacman` means a package provides the unit: apply installs that package when it
# is missing (one `omarchy pkg add` for all of them), then enables and starts the unit. `copy` is a user unit file: fetched
# from the peer like config (with diff and backup), then daemon-reload and enable. System units go through sudo (visible
# terminal when there is no tty), user units do not. Units this run newly enabled are recorded in the backup set (`services`) so `startkin rollback` can disable them.

apply_unit_ok() { [[ $1 =~ ^[A-Za-z0-9:_.@-]+\.(service|socket|timer|path)$ ]]; }

# apply_services_packages ITEMS_JSON : install the packages behind the pacman-backed units that are missing, in one batch.
# The batch reports under the unit ids; those lines are shown but not counted (each unit gets its own record afterwards).
apply_services_packages() {
  local item pkg missing=() real=$APPLY_RES scratch
  while IFS= read -r item; do
    pkg=$(apply_f "$item" .install.package)
    apply_name_ok "$pkg" && [[ $pkg != */* ]] || continue
    pacman -Qq -- "$pkg" >/dev/null 2>&1 && continue
    missing+=("$(jq -nc --arg i "$(apply_f "$item" .id)" --arg p "$pkg" '{id: $i, install: {type: "pacman", package: $p}}')")
  done < <(jq -c '.[] | select(.install.type == "pacman")' <<<"$1")
  ((${#missing[@]})) || return 0
  scratch=$(mktemp) || return 1
  APPLY_RES=$scratch
  apply_pkg_batch pacman "$(printf '%s\n' "${missing[@]}" | jq -sc 'unique_by(.install.package)')"
  APPLY_RES=$real
  rm -f "$scratch"
}

apply_stage_services() {
  local item id scope unit type pkg ctl reload cmds c ok was
  apply_services_packages "$1"
  while IFS= read -r -u 4 item; do
    id=$(apply_f "$item" .id) type=$(apply_f "$item" .install.type) reload=0
    scope="" unit=""
    if [[ $id =~ ^service:(system|user):(.+)$ ]]; then scope=${BASH_REMATCH[1]} unit=${BASH_REMATCH[2]}; fi
    if [[ -z $unit ]] || ! apply_unit_ok "$unit"; then
      apply_record "$id" skipped "invalid unit in manifest"
      continue
    fi
    case $type in
      pacman)
        pkg=$(apply_f "$item" .install.package)
        if ! { apply_name_ok "$pkg" && [[ $pkg != */* ]]; }; then apply_record "$id" skipped "invalid package in manifest"; continue; fi
        if ! ((APPLY_DRY)) && ! pacman -Qq -- "$pkg" >/dev/null 2>&1; then
          apply_record "$id" skipped "package $pkg is not installed"
          continue
        fi
        ;;
      copy)
        if [[ $scope != user ]]; then apply_record "$id" skipped "only user unit files are copied"; continue; fi
        apply_copy_item "$item" "$HOME/.config/systemd/user" units
        case $APPLY_COPY_RESULT in
          installed) reload=1 ;;
          present | planned) ;;
          *) apply_record "$id" "$APPLY_COPY_RESULT" "$APPLY_COPY_DETAIL"; continue ;;
        esac
        ;;
      *)
        apply_record "$id" skipped "no install method recorded; enable it yourself ($(apply_f "$item" .install.hint))"
        continue
        ;;
    esac

    ctl=(systemctl)
    [[ $scope == user ]] && ctl+=(--user)
    was=0
    "${ctl[@]}" is-enabled --quiet "$unit" 2>/dev/null && was=1
    if ((!reload && was)); then
      apply_record "$id" present "already enabled"
      continue
    fi
    cmds=()
    ((reload)) && cmds+=("$(apply_q "${ctl[@]}" daemon-reload)")
    if [[ $scope == system ]]; then cmds+=("$(apply_q sudo "${ctl[@]}" enable --now "$unit")"); else cmds+=("$(apply_q "${ctl[@]}" enable --now "$unit")"); fi
    printf '  %s%s\n' "$id" "$([[ $type == copy ]] && echo ' [runs a unit file from another machine]')"
    for c in "${cmds[@]}"; do apply_show "$([[ $scope == system ]] && apply_priv_line "$c" || echo "$c")"; done
    if ((APPLY_DRY)); then apply_record "$id" planned ""; continue; fi
    if ! apply_confirm_for "$([[ $type == copy ]] && echo units)" "Run this?"; then apply_record "$id" skipped "not confirmed"; continue; fi
    for c in "${cmds[@]}"; do
      if [[ $scope == system ]]; then apply_priv_exec "$c" || true; else bash -c "$c" || true; fi
    done
    ok=0
    "${ctl[@]}" is-enabled --quiet "$unit" 2>/dev/null && ok=1
    if ((ok)); then
      # Only a unit that was not enabled before is recorded, so rollback never disables what the user already had.
      ((was)) || backup_record_service "$scope" "$unit"
      apply_record "$id" installed "enabled and started"
    else
      apply_record "$id" failed "not enabled afterwards"
      [[ $scope == system ]] && apply_terminal_failure
    fi
  done 4< <(jq -c '.[]' <<<"$1")
}
