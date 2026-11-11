#!/usr/bin/env bash
# Secrets policy library (docs/secrets-policy.md). Source this; it defines functions and tables only.
#   secrets_path_denied PATH   : is this path never exported/applied by default? (prints the category)
#   secrets_scan_text          : scan stdin for secret patterns (prints "KIND<TAB>LINE", never the secret)
#   secrets_scan_file FILE     : same, for a file
# Needs only bash and awk. Matched secret text is never printed, logged or put in an error message.
# shellcheck shell=bash

# --- path policy -------------------------------------------------------------------------------

# Exceptions: matched against the path itself, checked before the denylist. Public or template material only.
_SECRETS_PATH_ALLOW=(
  '*.pub' '*.example' '*.sample' '*.template'
  '*/.ssh/config' '*/.gnupg/gpg.conf' '*/.gnupg/gpg-agent.conf' '*/.gnupg/dirmngr.conf'
)

# CATEGORY:GLOB, first match wins, so order matters (keyring before gnupg: ~/.password-store holds *.gpg; gnupg before ssh-key: both claim *.key under .gnupg).
# Globs are matched against the path and against the path plus a trailing "/" (so directory globs like
# */.ssh/* match "~/.ssh" itself). "*" crosses "/". Home paths use a leading */ so "~/", $HOME and relative
# paths all match.
_SECRETS_PATH_DENY=(
  'keyring:*/.local/share/keyrings/*' 'keyring:*/.password-store/*' 'keyring:*.keyring' 'keyring:*.kdbx'
  'keyring:*/.local/share/kwalletd/*' 'keyring:*/.config/Bitwarden/*' 'keyring:*/.config/1Password/*'
  'gnupg:*/.gnupg/*' 'gnupg:*/.local/share/gnupg/*' 'gnupg:*.gpg' 'gnupg:*.kbx'
  'ssh-key:*/.ssh/*' 'ssh-key:*/id_rsa' 'ssh-key:*/id_dsa' 'ssh-key:*/id_ecdsa' 'ssh-key:*/id_ed25519'
  'ssh-key:*.pem' 'ssh-key:*.key' 'ssh-key:*.ppk' 'ssh-key:*.p12' 'ssh-key:*.pfx'
  'token:*/.config/gh/hosts.yml' 'token:*/.config/glab-cli/*' 'token:*/.npmrc' 'token:*/.pypirc' 'token:*/.netrc'
  'token:*/.git-credentials' 'token:*/.docker/config.json' 'token:*/.cargo/credentials*' 'token:*/.config/op/*'
  'token:*/.config/rclone/rclone.conf' 'token:*/.claude/.credentials.json' 'token:*.token'
  'token:*/.env' 'token:*/.env.*' 'token:/var/lib/tailscale/*'
  'credentials:*/.aws/*' 'credentials:*/.azure/*' 'credentials:*/.config/gcloud/*' 'credentials:*/.kube/config'
  'credentials:*/.config/doctl/*' 'credentials:*/credentials' 'credentials:*/credentials.json'
  'credentials:*/client_secret*.json' 'credentials:*/secrets.*'
  'credentials:/etc/NetworkManager/system-connections/*' 'credentials:*/.config/NetworkManager/system-connections/*'
  'credentials:/etc/wireguard/*' 'credentials:/etc/shadow' 'credentials:/etc/gshadow'
  'shell-history:*_history' 'shell-history:*/.histfile' 'shell-history:*/.lesshst' 'shell-history:*/.viminfo'
  'shell-history:*/.local/share/zsh/history' 'shell-history:*/.local/share/atuin/*'
  'shell-history:*/.zsh_sessions/*' 'shell-history:*/.local/share/mcfly/*'
  'browser-profile:*/.mozilla/*' 'browser-profile:*/.librewolf/*' 'browser-profile:*/.zen/*'
  'browser-profile:*/.cache/mozilla/*' 'browser-profile:*/.config/google-chrome*/*'
  'browser-profile:*/.config/chromium/*' 'browser-profile:*/.config/BraveSoftware/*'
  'browser-profile:*/.config/vivaldi*/*' 'browser-profile:*/.config/microsoft-edge*/*'
  'browser-profile:*/.config/opera/*' 'browser-profile:*/.var/app/org.mozilla.firefox/*'
  'hardware:*/.config/hypr/monitors.conf' 'hardware:*/.config/kanshi/*' 'hardware:/etc/fstab'
  'hardware:/etc/crypttab' 'hardware:/etc/machine-id' 'hardware:/var/lib/dbus/machine-id'
  'hardware:/etc/hostname' 'hardware:/etc/X11/xorg.conf*' 'hardware:/etc/udev/rules.d/*'
  'hardware:/etc/modprobe.d/*' 'hardware:/var/lib/bluetooth/*'
)

# secrets_path_denied PATH : print the category and return 0 if PATH must not be exported/applied by default;
# print nothing and return 1 if it is fine; return 2 on bad usage. PATH need not exist.
# "hardware" is lifted by STARTKIN_SECRETS_ALLOW_HARDWARE=1; no other category can be lifted.
secrets_path_denied() {
  (($# == 1)) || { printf 'secrets_path_denied: usage: secrets_path_denied PATH\n' >&2; return 2; }
  local p=$1 g entry cat
  [[ $p == /* ]] || p=/$p
  for g in "${_SECRETS_PATH_ALLOW[@]}"; do
    # shellcheck disable=SC2254 # $g is a glob on purpose
    case $p in $g) return 1 ;; esac
  done
  for entry in "${_SECRETS_PATH_DENY[@]}"; do
    cat=${entry%%:*} g=${entry#*:}
    [[ $cat == hardware && ${STARTKIN_SECRETS_ALLOW_HARDWARE:-} == 1 ]] && continue
    # shellcheck disable=SC2254 # $g is a glob on purpose
    case $p in $g) printf '%s\n' "$cat"; return 0 ;; esac
    # shellcheck disable=SC2254
    case $p/ in $g) printf '%s\n' "$cat"; return 0 ;; esac
  done
  return 1
}

# --- content scanner ---------------------------------------------------------------------------

# KIND and ERE, parallel arrays, matched case-sensitively per line.
_SECRETS_KINDS=(private-key github-token github-token api-key api-key aws-access-key slack-token jwt credential-url)
_SECRETS_RES=(
  '-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY( BLOCK)?-----'
  '(^|[^A-Za-z0-9_])gh[pousr]_[A-Za-z0-9]{30,}'
  '(^|[^A-Za-z0-9_])github_pat_[A-Za-z0-9_]{30,}'
  '(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}'
  '(^|[^A-Za-z0-9_-])AIza[A-Za-z0-9_-]{35}'
  '(^|[^A-Za-z0-9])(AKIA|ASIA)[0-9A-Z]{16}([^A-Za-z0-9]|$)'
  'xox[abeoprs]-[A-Za-z0-9-]{10,}'
  'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+'
  '[A-Za-z][A-Za-z0-9+.-]*://[^/[:space:]:@]+:[^/[:space:]@]+@'
)

# KEY ending in a secret word, then : or =, then the value (matched on the lowercased line).
_SECRETS_ASSIGN_RE='(password|passwd|passphrase|secret|token|api[_-]?key|access[_-]?key|private[_-]?key)"?'"'"'?[[:space:]]*[:=][[:space:]]*["'"'"']?([^[:space:]"'"'"',;]*)'
# Any KEY = VALUE where VALUE is a long run of key-ish characters.
_SECRETS_ENTROPY_RE='[A-Za-z_][A-Za-z0-9_.-]*"?'"'"'?[[:space:]]*[:=][[:space:]]*["'"'"']?([A-Za-z0-9+/_=-]{20,})'
_SECRETS_ENTROPY_MIN=3.8

# _secrets_entropy VALUE : Shannon entropy in bits per character (value goes over stdin, not argv)
_secrets_entropy() {
  printf '%s' "$1" | awk '{ n = length($0); for (i = 1; i <= n; i++) c[substr($0, i, 1)]++
    for (k in c) { p = c[k] / n; h -= p * log(p) / log(2) } printf "%.2f", h }'
}

# _secrets_placeholder_value LOWERCASED_VALUE : true if the value is empty, short, numeric, a reference or a placeholder
_secrets_placeholder_value() {
  local v=$1
  ((${#v} < 6)) && return 0
  [[ $v =~ ^[0-9._-]+$ ]] && return 0
  [[ $v == [\$\<\{%\*\(\[@/~.-]* ]] && return 0
  [[ $v == *redacted* ]] && return 0
  [[ $v =~ ^(none|null|true|false|changeme|example|empty|unset|undefined|bearer|basic|secret|password|token|x+)$ ]] && return 0
  return 1
}

# _secrets_pathlike VALUE : a relative path such as "libreoffice/4/user/x.xml": has a "/" and at least 60% lowercase
# letters (random base64 is about 40%). Keeps manifest ids and names from tripping high-entropy.
_secrets_pathlike() {
  local lower=${1//[^a-z]/}
  [[ $1 == */* ]] && ((${#lower} * 10 >= ${#1} * 6))
}

# _secrets_line_kinds LINE : sets the array _SECRETS_FOUND to the kinds found in LINE
_secrets_line_kinds() {
  local line=$1 lc=${1,,} rest i v m
  _SECRETS_FOUND=()
  for i in "${!_SECRETS_RES[@]}"; do
    if [[ $line =~ ${_SECRETS_RES[i]} ]]; then
      [[ " ${_SECRETS_FOUND[*]} " == *" ${_SECRETS_KINDS[i]} "* ]] || _SECRETS_FOUND+=("${_SECRETS_KINDS[i]}")
    fi
  done
  rest=$lc
  while [[ $rest =~ $_SECRETS_ASSIGN_RE ]]; do
    v=${BASH_REMATCH[2]} m=${BASH_REMATCH[0]}
    if ! _secrets_placeholder_value "$v"; then _SECRETS_FOUND+=(secret-assignment); break; fi
    rest=${rest#*"$m"}
  done
  rest=$line
  while [[ $rest =~ $_SECRETS_ENTROPY_RE ]]; do
    v=${BASH_REMATCH[1]} m=${BASH_REMATCH[0]}
    if [[ $v != [/~.]* && ! $v =~ ^[0-9a-fA-F]+$ && $v =~ [0-9] && $v =~ [A-Za-z] ]] && ! _secrets_pathlike "$v" &&
      awk -v h="$(_secrets_entropy "$v")" -v m="$_SECRETS_ENTROPY_MIN" 'BEGIN { exit !(h >= m) }'; then
      _SECRETS_FOUND+=(high-entropy)
      break
    fi
    rest=${rest#*"$m"}
  done
}

# secrets_scan_text : read stdin, print one "KIND<TAB>LINE" per finding (1-based line, never the matched text).
# Returns 0 if clean, 1 if anything was found. Takes no arguments.
# Kinds: private-key github-token api-key aws-access-key slack-token jwt credential-url secret-assignment high-entropy
secrets_scan_text() {
  local line n=0 k found=0
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    _secrets_line_kinds "$line"
    for k in "${_SECRETS_FOUND[@]}"; do printf '%s\t%d\n' "$k" "$n"; found=1; done
  done
  return "$found"
}

# secrets_scan_file FILE : secrets_scan_text over FILE. Returns 2 if FILE is not a readable file.
secrets_scan_file() {
  (($# == 1)) || { printf 'secrets_scan_file: usage: secrets_scan_file FILE\n' >&2; return 2; }
  [[ -f $1 && -r $1 ]] || { printf 'secrets_scan_file: cannot read: %s\n' "$1" >&2; return 2; }
  secrets_scan_text <"$1"
}
