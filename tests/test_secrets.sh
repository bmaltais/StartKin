#!/usr/bin/env bash
# shellcheck disable=SC2031 # T_TMP is set per test by the harness, in the test's own subshell
# Tests for lib/secrets.sh. Every secret here is synthetic and assembled at run time so this file
# itself never contains a string that looks like a real credential.
# shellcheck source=harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
# shellcheck source=../lib/secrets.sh
source "$ROOT/lib/secrets.sh"

rep() { local i out=""; for ((i = 0; i < $2; i++)); do out+=$1; done; printf '%s' "$out"; }
fake_ghp() { printf 'ghp_%s' "$(rep Ab1Cd2 6)"; }
fake_gho() { printf 'gho_%s' "$(rep Zy9Xw8 6)"; }
fake_sk() { printf 'sk-%s' "$(rep Qw3Er4 5)"; }
fake_akia() { printf 'AKIA%s' "$(rep ZXCV5678 2)"; }
fake_slack() { printf 'xoxb-%s-%s' 1234567890 "$(rep AbCd 4)"; }
fake_pem_header() { printf -- '-----BEGIN %s PRIVATE KEY-----' "${1:-OPENSSH}"; }

# --- path policy -------------------------------------------------------------------------------

test_path_denied_categories() {
  local pair path want got
  for pair in \
    "$HOME/.ssh/id_ed25519:ssh-key" "$HOME/.ssh/known_hosts:ssh-key" ".ssh/id_rsa:ssh-key" "/srv/deploy.pem:ssh-key" \
    "$HOME/.gnupg/private-keys-v1.d/x.key:gnupg" "$HOME/.gnupg:gnupg" \
    "$HOME/.local/share/keyrings/login.keyring:keyring" "$HOME/.password-store/a.gpg:keyring" "$HOME/v.kdbx:keyring" \
    "$HOME/.config/gh/hosts.yml:token" "$HOME/.npmrc:token" "$HOME/.netrc:token" "$HOME/.git-credentials:token" \
    "$HOME/proj/.env:token" "$HOME/proj/.env.local:token" "$HOME/.docker/config.json:token" \
    "$HOME/.aws/credentials:credentials" "$HOME/.kube/config:credentials" "$HOME/.config/gcloud/creds.db:credentials" \
    "/etc/NetworkManager/system-connections/home.nmconnection:credentials" \
    "$HOME/.bash_history:shell-history" "$HOME/.local/share/fish/fish_history:shell-history" \
    "$HOME/.zsh_history:shell-history" "$HOME/.local/share/atuin/history.db:shell-history" \
    "$HOME/.mozilla/firefox/abc.default/logins.json:browser-profile" \
    "$HOME/.config/google-chrome/Default/Cookies:browser-profile" \
    "$HOME/.config/chromium/Default/Login Data:browser-profile" \
    "$HOME/.config/hypr/monitors.conf:hardware" "/etc/fstab:hardware" "/etc/machine-id:hardware" \
    "/var/lib/bluetooth/AA/settings:hardware"; do
    path=${pair%:*} want=${pair##*:}
    got=$(secrets_path_denied "$path") || got="(allowed)"
    assert_eq "$want" "$got" "category of $path"
  done
}

test_path_allowed() {
  local p
  for p in "$HOME/.bashrc" "$HOME/.config/nvim/init.lua" "$HOME/.config/hypr/bindings.conf" \
    "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/config" "$HOME/proj/.env.example" "$HOME/.gnupg/gpg.conf" \
    "$HOME/.config/omarchy/plugins/x/manifest.json" "/usr/local/bin/tool" "$HOME/.local/bin/script" \
    "$HOME/notes/history-of-rome.md" "$HOME/.config/environment.d/10.conf"; do
    assert_status 1 secrets_path_denied "$p"
    assert_eq "" "$T_OUT" "no category printed for $p"
  done
}

test_path_denied_exit_status() {
  assert_status 0 secrets_path_denied "$HOME/.ssh/id_rsa"
  assert_status 2 secrets_path_denied
}

test_hardware_opt_in_does_not_unlock_secrets() {
  export STARTKIN_SECRETS_ALLOW_HARDWARE=1
  assert_status 1 secrets_path_denied "$HOME/.config/hypr/monitors.conf"
  assert_status 0 secrets_path_denied "$HOME/.ssh/id_rsa"
  assert_status 0 secrets_path_denied "$HOME/.bash_history"
}

# --- content scanner ---------------------------------------------------------------------------

# kinds_of TEXT : the sorted unique kinds reported for TEXT, space separated
kinds_of() { secrets_scan_text <<<"$1" | cut -f1 | sort -u | paste -sd' '; }

test_detects_private_key_header() {
  assert_eq "private-key" "$(kinds_of "$(fake_pem_header OPENSSH)")"
  assert_eq "private-key" "$(kinds_of "$(fake_pem_header RSA)")"
  assert_eq "private-key" "$(kinds_of "$(fake_pem_header)")"
  assert_eq "" "$(kinds_of "-----BEGIN PUBLIC KEY-----")"
}

test_detects_provider_tokens() {
  assert_eq "github-token" "$(kinds_of "note $(fake_ghp) end")"
  assert_eq "github-token" "$(kinds_of "$(fake_gho)")"
  assert_eq "api-key" "$(kinds_of "$(fake_sk)")"
  assert_eq "aws-access-key" "$(kinds_of "$(fake_akia)")"
  assert_eq "slack-token" "$(kinds_of "$(fake_slack)")"
}

test_detects_assignments() {
  assert_eq "secret-assignment" "$(kinds_of "password=hunter22")"
  assert_eq "secret-assignment" "$(kinds_of 'export API_TOKEN="plainvalue"')"
  assert_eq "secret-assignment" "$(kinds_of '  "token": "plainvalue"')"
  assert_eq "secret-assignment" "$(kinds_of "db_password: plainvalue")"
  assert_eq "secret-assignment" "$(kinds_of "client_secret = plainvalue")"
}

test_detects_credentials_in_url() {
  assert_eq "credential-url" "$(kinds_of "git clone https://user:pa55word@example.com/r.git")"
}

test_detects_high_entropy_assignment() {
  assert_eq "high-entropy" "$(kinds_of "build_id = q8Zx3Lm9Kp2Wv7Rt4Yh1Jb6")"
  assert_eq "high-entropy" "$(kinds_of '"blob": "q8Zx3Lm9Kp2Wv7Rt4Yh1Jb6"')"
}

test_clean_text_has_no_findings() {
  local line
  # shellcheck disable=SC2016 # literal shell syntax is the test input
  for line in \
    "password=" 'password=$(pass show x)' 'token=${TOKEN}' 'password = <redacted>' 'api_key: REDACTED' \
    "max_tokens: 4096" "token_type: bearer" "password_file=/etc/pw" 'passwordless = true' \
    '"sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"' \
    '"url": "https://github.com/example/example-tool/releases/download/v1.2.3/tool"' \
    "dest = /home/user/.local/bin/some-long-tool-name-here" \
    "name = my-very-long-descriptive-package-name" "plain prose about tokens and passwords" "AKIA short"; do
    assert_status 0 secrets_scan_text <<<"$line"
    assert_eq "" "$T_OUT" "findings for: $line"
  done
}

test_scan_reports_line_numbers_and_never_echoes_secret() {
  local tok text
  tok=$(fake_ghp)
  text=$(printf 'clean\n%s\nclean\npassword=Sup3rS3cretValue\n' "$tok")
  assert_status 1 secrets_scan_text <<<"$text"
  assert_eq $'github-token\t2\nsecret-assignment\t4' "$T_OUT"
  [[ $T_OUT != *"${tok:4:12}"* ]] || t_fail "token fragment leaked on stdout"
  [[ $T_OUT != *Sup3rS3cret* ]] || t_fail "password leaked on stdout"
  [[ $T_ERR != *"${tok:4:12}"* && $T_ERR != *Sup3rS3cret* ]] || t_fail "secret leaked on stderr"
}

test_one_line_many_kinds() {
  assert_eq "aws-access-key secret-assignment" "$(kinds_of "token=plainvalue $(fake_akia)")"
}

test_scan_file() {
  printf 'ok\n%s\n' "$(fake_gho)" >"$T_TMP/f"
  assert_status 1 secrets_scan_file "$T_TMP/f"
  assert_eq $'github-token\t2' "$T_OUT"
  printf 'nothing here\n' >"$T_TMP/clean"
  assert_status 0 secrets_scan_file "$T_TMP/clean"
  assert_eq "" "$T_OUT"
  assert_status 2 secrets_scan_file "$T_TMP/missing"
  assert_status 2 secrets_scan_file
}

test_last_line_without_newline() {
  printf 'password=plainvalue' >"$T_TMP/f"
  assert_status 1 secrets_scan_file "$T_TMP/f"
  assert_eq $'secret-assignment\t1' "$T_OUT"
}

run_tests
