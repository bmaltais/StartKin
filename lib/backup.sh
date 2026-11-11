#!/usr/bin/env bash
# Backups and rollback for `startkin apply` (#14). Contract: docs/engine.md "Apply".
#   startkin rollback [ID|latest] [--yes] [--dry-run]     startkin rollback --list
# Every apply run that changes a file opens one backup set, $STARTKIN_STATE_DIR/backups/ID (default
# ~/.local/state/startkin/backups/ID, mode 700, ID is a UTC timestamp). It holds a journal ("replaced|created<TAB>path", in
# apply order) and a full copy of every file or directory that was replaced, under files/<path relative to home>.
# A "hashes" file records "journal line<TAB>hash" of what apply left at each path, so rollback can tell a file edited since.
# A "services" file lists the units apply newly enabled ("SCOPE<TAB>UNIT", scope user or system, one per line); a "dirs"
# file lists the directories it created. Both are separate from the journal so an older startkin reads the set unchanged.
# Rollback walks the journal backwards: restores what was replaced, removes what was created. It only touches paths inside home.
# Needs lib/common.sh, ui.sh. Source this.
# shellcheck shell=bash

BACKUP_DIR="" # the set opened by this apply run (empty until the first change)

backup_reset() { BACKUP_DIR=""; }
backup_root() { echo "${STARTKIN_STATE_DIR:-$HOME/.local/state/startkin}/backups"; }

# backup_begin : open this run's backup set (once)
backup_begin() {
  [[ -z $BACKUP_DIR ]] || return 0
  local root id n=1 d
  root=$(backup_root)
  id=$(date -u +%Y%m%dT%H%M%SZ)
  d=$root/$id
  while [[ -e $d ]]; do n=$((n + 1)); d=$root/$id-$n; done
  (umask 077 && mkdir -p -- "$d/files") || return 1
  chmod 700 "$root" "$d" 2>/dev/null
  BACKUP_DIR=$d
  : >"$BACKUP_DIR/journal"
}

# backup_id : the id of this run's set, empty when nothing was changed
backup_id() { [[ -n $BACKUP_DIR ]] && basename -- "$BACKUP_DIR"; return 0; }

# backup_save DEST : journal and (when DEST exists) copy DEST into the set. Must succeed before DEST is touched.
backup_save() {
  local dest=$1 rel=${1#"$HOME"/}
  backup_begin || return 1
  if [[ -e $dest || -L $dest ]]; then
    (umask 077 && mkdir -p -- "$(dirname -- "$BACKUP_DIR/files/$rel")") || return 1
    cp -a -- "$dest" "$BACKUP_DIR/files/$rel" || return 1
    printf 'replaced\t%s\n' "$dest" >>"$BACKUP_DIR/journal"
  else
    printf 'created\t%s\n' "$dest" >>"$BACKUP_DIR/journal"
  fi
}

# backup_mkdir_p DIR : mkdir -p DIR, first recording in the set's "dirs" file (one path per line, shallowest first) every
# directory inside home that does not exist yet, so rollback can rmdir exactly those. Needs backup_save to have run.
backup_mkdir_p() {
  local d=$1 missing=() p
  while [[ $d == "$HOME"/* && ! -e $d && ! -L $d ]]; do
    missing=("$d" "${missing[@]}")
    d=$(dirname -- "$d")
  done
  if [[ -n $BACKUP_DIR ]]; then
    for p in "${missing[@]}"; do printf '%s\n' "$p" >>"$BACKUP_DIR/dirs"; done
  fi
  mkdir -p -- "$1"
}

# backup_record_service SCOPE UNIT : note a unit apply just enabled (it was not enabled before), so rollback can disable it
backup_record_service() {
  backup_begin || return 1
  printf '%s\t%s\n' "$1" "$2" >>"$BACKUP_DIR/services"
}

# backup_services SET : the recorded units, newest first, as "SCOPE<TAB>UNIT"; malformed records are dropped
backup_services() {
  local scope unit
  [[ -f $1/services ]] || return 0
  while IFS=$'\t' read -r scope unit; do
    [[ $scope == user || $scope == system ]] && apply_unit_ok "$unit" && printf '%s\t%s\n' "$scope" "$unit"
  done < <(tac "$1/services")
  return 0
}

# backup_disable_services SET : disable --now each recorded unit, then reset-failed, in its scope (system through the same
# sudo/terminal helpers apply uses). Only recorded units are touched.
backup_disable_services() {
  local scope unit ctl cmd
  while IFS=$'\t' read -r scope unit; do
    ctl=(systemctl)
    [[ $scope == user ]] && ctl+=(--user)
    if [[ $scope == system ]]; then
      cmd="$(apply_q sudo "${ctl[@]}" disable --now "$unit"); $(apply_q sudo "${ctl[@]}" reset-failed "$unit")"
      apply_priv_exec "$cmd" || true
    else
      "${ctl[@]}" disable --now "$unit" || true
      "${ctl[@]}" reset-failed "$unit" 2>/dev/null || true
    fi
    if "${ctl[@]}" is-enabled --quiet "$unit" 2>/dev/null; then
      printf '  could not disable %s %s; disable it yourself\n' "$scope" "$unit"
    else
      printf '  disabled %s %s\n' "$scope" "$unit"
    fi
  done < <(backup_services "$1")
  return 0
}

# backup_rmdirs SET : remove the directories apply created, deepest first, with rmdir only: a directory that is not empty
# (the user added files) or no longer a real directory is left alone. Sets without a dirs file (older ones) do nothing.
backup_rmdirs() {
  local dir
  [[ -f $1/dirs ]] || return 0
  while IFS= read -r dir; do
    apply_home_path_ok "$dir" && [[ -d $dir && ! -L $dir ]] || continue
    rmdir -- "$dir" 2>/dev/null && printf '  rmdir    %s\n' "$(tilde_text "$dir")"
  done < <(tac "$1/dirs")
  return 0
}

# backup_hash PATH : a content hash of a file or directory tree (empty when PATH is missing)
backup_hash() {
  [[ -e $1 || -L $1 ]] || return 0
  if [[ -d $1 && ! -L $1 ]]; then
    (cd "$1" && find . \( -type f -o -type l \) -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1)
  else
    sha256sum -- "$1" 2>/dev/null | cut -d' ' -f1
  fi
}

# backup_note_after DEST : record the hash of what apply just left at DEST (called after a successful install), keyed by
# the journal line of that change
backup_note_after() {
  [[ -n $BACKUP_DIR ]] || return 0
  printf '%s\t%s\n' "$(grep -c '' "$BACKUP_DIR/journal")" "$(backup_hash "$1")" >>"$BACKUP_DIR/hashes"
}

# backup_hash_of SET LINE : the hash recorded after apply for journal line LINE, empty when none
backup_hash_of() { [[ -f $1/hashes ]] && awk -F'\t' -v n="$2" '$1 == n { h = $2 } END { print h }' "$1/hashes"; return 0; }

# backup_restore SET DEST : put the backed-up copy back at DEST without ever leaving DEST half-done: copy next to it, then swap.
backup_restore() {
  local src=$1/files/${2#"$HOME"/} tmp="$2.startkin-restore.$$"
  [[ -e $src || -L $src ]] || return 1
  mkdir -p -- "$(dirname -- "$2")" || return 1
  rm -rf -- "$tmp"
  cp -a -- "$src" "$tmp" || { rm -rf -- "$tmp"; return 1; }
  if rm -rf -- "$2" && mv -- "$tmp" "$2"; then return 0; fi
  rm -rf -- "$tmp"
  return 1
}

# backup_sets : set ids, oldest first
backup_sets() {
  local root d
  root=$(backup_root)
  [[ -d $root ]] || return 0
  for d in "$root"/*/; do
    [[ -f $d/journal ]] && basename -- "$d"
  done | LC_ALL=C sort
  return 0
}

backup_list() {
  local id n state
  while IFS= read -r id; do
    n=$(grep -c . "$(backup_root)/$id/journal")
    state=""
    [[ -e $(backup_root)/$id/rolled-back ]] && state=" (rolled back)"
    printf '%s  %d change(s)%s\n' "$id" "$n" "$state"
  done < <(backup_sets | sort -r)
}

# backup_summary : the line apply prints when it made changes
backup_summary() {
  [[ -n $BACKUP_DIR ]] || return 0
  printf 'Backup %s: undo this run with: startkin rollback %s\n' "$(backup_id)" "$(backup_id)"
}

BACKUP_USAGE='Usage: startkin rollback [ID|latest] [--yes] [--dry-run]
       startkin rollback --list
  Undo a startkin apply run: restore the files it replaced from its backup, remove the files it created and the directories it made.
  latest (default) is the newest set not yet rolled back. It also disables (disable --now, reset-failed) the services that run enabled and that were not enabled before.
  Installed packages and plugins are not undone.'

# cmd_rollback [ID|latest] [--yes] [--dry-run] | --list
cmd_rollback() {
  local id="" yes=0 dry=0 list=0 set journal action dest want ln n=0 scope unit
  while (($#)); do
    case $1 in
      -h | --help) echo "$BACKUP_USAGE"; return 0 ;;
      --yes | -y) yes=1 ;;
      --dry-run) dry=1 ;;
      --list) list=1 ;;
      -*) die -c 2 "rollback: unknown option: $1" ;;
      *) [[ -z $id ]] || die -c 2 "rollback: more than one id given"; id=$1 ;;
    esac
    shift
  done
  if ((list)); then backup_list; return 0; fi
  if [[ -z $id || $id == latest ]]; then
    id=""
    while IFS= read -r set; do
      [[ -e $(backup_root)/$set/rolled-back ]] || id=$set
    done < <(backup_sets)
    [[ -n $id ]] || die "rollback: nothing to roll back"
  fi
  [[ $id =~ ^[0-9]{8}T[0-9]{6}Z(-[0-9]+)?$ ]] || die "rollback: no such backup: $id (see: startkin rollback --list)"
  set=$(backup_root)/$id
  journal=$set/journal
  [[ -f $journal ]] || die "rollback: no such backup: $id (see: startkin rollback --list)"
  [[ ! -e $set/rolled-back ]] || die "rollback: $id was already rolled back"

  printf 'Rolling back %s:\n' "$id"
  while IFS=$'\t' read -r action dest; do
    apply_home_path_ok "$dest" || die "rollback: refusing path outside home: $dest"
    if [[ $action == replaced && ! -e $set/files/${dest#"$HOME"/} && ! -L $set/files/${dest#"$HOME"/} ]]; then
      die "rollback: the backup copy of $(tilde_text "$dest") is missing from $set/files; nothing was changed"
    fi
    case $action in
      replaced) printf '  restore %s\n' "$(tilde_text "$dest")" ;;
      created) printf '  remove  %s\n' "$(tilde_text "$dest")" ;;
    esac
    n=$((n + 1))
  done <"$journal"
  while IFS=$'\t' read -r scope unit; do
    printf '  disable  %s %s\n' "$scope" "$unit"
    n=$((n + 1))
  done < <(backup_services "$set")
  ((dry)) && { echo "(dry run: nothing changed)"; return 0; }
  if ! ((yes)) && ! ui_confirm "Roll back $n change(s)?"; then return 1; fi

  backup_disable_services "$set"
  # Backwards, so a path touched twice ends as it was before the first change.
  while IFS=$'\t' read -r ln action dest; do
    want=$(backup_hash_of "$set" "$ln")
    if [[ -n $want && -e $dest && $(backup_hash "$dest") != "$want" ]]; then
      printf '  %s changed since apply wrote it\n' "$(tilde_text "$dest")"
      if ! ui_confirm "Overwrite $(tilde_text "$dest") anyway?"; then printf '  kept     %s\n' "$(tilde_text "$dest")"; continue; fi
    fi
    if [[ $action == replaced ]]; then
      backup_restore "$set" "$dest" || die "rollback: could not restore $(tilde_text "$dest") from $set/files; it was left as it was"
    else
      rm -rf -- "$dest"
    fi
  done < <(awk '{ print NR "\t" $0 }' "$journal" | tac)
  backup_rmdirs "$set"
  now_utc >"$set/rolled-back"
  printf 'Rolled back %s.\n' "$id"
}
