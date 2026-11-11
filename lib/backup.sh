#!/usr/bin/env bash
# Backups and rollback for `startkin apply` (#14). Contract: docs/engine.md "Apply".
#   startkin rollback [ID|latest] [--yes] [--dry-run]     startkin rollback --list
# Every apply run that changes a file opens one backup set, $STARTKIN_STATE_DIR/backups/ID (default
# ~/.local/state/startkin/backups/ID, mode 700, ID is a UTC timestamp). It holds a journal ("replaced|created<TAB>path", in
# apply order) and a full copy of every file or directory that was replaced, under files/<path relative to home>.
# A "hashes" file records "journal line<TAB>hash" of what apply left at each path, so rollback can tell a file edited since.
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
  Undo a startkin apply run: restore the files it replaced from its backup and remove the files it created.
  latest (default) is the newest set not yet rolled back. Packages, plugins and enabled services are not undone.'

# cmd_rollback [ID|latest] [--yes] [--dry-run] | --list
cmd_rollback() {
  local id="" yes=0 dry=0 list=0 set journal action dest want ln n=0
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
  ((dry)) && { echo "(dry run: nothing changed)"; return 0; }
  if ! ((yes)) && ! ui_confirm "Roll back $n change(s)?"; then return 1; fi

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
  now_utc >"$set/rolled-back"
  printf 'Rolled back %s.\n' "$id"
}
