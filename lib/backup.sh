#!/usr/bin/env bash
# Backups and rollback for `startkin apply` (#14). Contract: docs/engine.md "Apply".
#   startkin rollback [ID|latest] [--yes] [--dry-run]     startkin rollback --list
# Every apply run that changes a file opens one backup set, $STARTKIN_STATE_DIR/backups/ID (default
# ~/.local/state/startkin/backups/ID, mode 700, ID is a UTC timestamp). It holds a journal ("replaced|created<TAB>path", in
# apply order) and a full copy of every file or directory that was replaced, under files/<path relative to home>.
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
  local id="" yes=0 dry=0 list=0 set journal action dest rel n=0
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
    [[ $dest == "$HOME"/* && $dest != *"/../"* && $dest != */.. ]] || die "rollback: refusing path outside home: $dest"
    case $action in
      replaced) printf '  restore %s\n' "$(tilde_text "$dest")" ;;
      created) printf '  remove  %s\n' "$(tilde_text "$dest")" ;;
    esac
    n=$((n + 1))
  done <"$journal"
  ((dry)) && { echo "(dry run: nothing changed)"; return 0; }
  if ! ((yes)) && ! ui_confirm "Roll back $n change(s)?"; then return 1; fi

  # Backwards, so a path touched twice ends as it was before the first change.
  while IFS=$'\t' read -r action dest; do
    rel=${dest#"$HOME"/}
    rm -rf -- "$dest"
    if [[ $action == replaced ]]; then
      mkdir -p -- "$(dirname -- "$dest")"
      cp -a -- "$set/files/$rel" "$dest" || die "rollback: could not restore $(tilde_text "$dest") from $set/files/$rel"
    fi
  done < <(tac "$journal")
  now_utc >"$set/rolled-back"
  printf 'Rolled back %s.\n' "$id"
}
