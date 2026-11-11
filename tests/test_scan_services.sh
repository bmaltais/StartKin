#!/usr/bin/env bash
# shellcheck disable=SC2016 # stub bodies are literal scripts, expanded when the stub runs
# shellcheck disable=SC2031 # T_TMP is set per test by the harness, in the test's own subshell
# shellcheck source=harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/scan/services.sh
source "$ROOT/lib/scan/services.sh"

# Fixture: an Omarchy tree whose install scripts enable cups, ufw, snapper (system) and bt-agent (user).
setup() {
  export STARTKIN_OMARCHY_DIR=$T_TMP/omarchy HOME=$T_TMP/home
  mkdir -p "$STARTKIN_OMARCHY_DIR/install/config" "$STARTKIN_OMARCHY_DIR/install/user" "$HOME/.config/systemd/user"
  cat >"$STARTKIN_OMARCHY_DIR/install/config/enable.sh" <<'S'
# systemctl enable commented.service
systemctl enable cups.service
systemctl enable ufw
systemctl enable NetworkManager.service
systemctl enable --now snapper-cleanup.timer limine-snapper-sync.service >/dev/null 2>&1 || true
S
  printf "# core\nowe\nhyprland\n" >"$STARTKIN_OMARCHY_DIR/install/omarchy-base.packages"
  cat >"$STARTKIN_OMARCHY_DIR/install/user/units.sh" <<'S'
for unit in \
  bt-agent.service \
  omarchy-sleep-lock.service; do
  systemctl --user enable --now "$unit"
done
S
  stub systemctl '
user=0; [[ $1 == --user ]] && { user=1; shift; }
case $1 in
  list-unit-files)
    if ((user)); then
      printf "bt-agent.service enabled enabled\nmyjob.service enabled enabled\npipewire.socket enabled enabled\nowe.service enabled enabled\nsuperwhisper.service enabled enabled\nbroken.service enabled enabled\n"
    else
      printf "NetworkManager-dispatcher.service enabled disabled\ncups.service enabled disabled\ncups.socket enabled disabled\ncups.path enabled disabled\nufw.service enabled disabled\nsnapper-cleanup.timer enabled disabled\ngetty@.service enabled enabled\nsshd.service enabled disabled\nmystery.service enabled disabled\n"
    fi ;;
  show)
    case ${!#} in
      sshd.service) echo /usr/lib/systemd/system/sshd.service ;;
      myjob.service) echo "$HOME/.config/systemd/user/myjob.service" ;;
      pipewire.socket) echo /usr/lib/systemd/user/pipewire.socket ;;
      owe.service) echo /usr/lib/systemd/user/owe.service ;;
      superwhisper.service) echo /usr/lib/systemd/user/superwhisper.service ;;
      *) echo "" ;;
    esac ;;
esac'
  stub pacman '
case $1 in
  -Qo)
    case $2 in
      */sshd.service) echo "$2 is owned by openssh 10.0p1-1"; exit 0 ;;
      */pipewire.socket) echo "$2 is owned by pipewire 1:1.6-1"; exit 0 ;;
      */owe.service) echo "$2 is owned by owe 0.2-1"; exit 0 ;;
      */superwhisper.service) echo "$2 is owned by superwhisper-bin 1.3-1"; exit 0 ;;
    esac
    echo "error: No package owns $2" >&2; exit 1 ;;
  -Qi)
    case $2 in
      pipewire) echo "Install Reason  : Installed as a dependency for another package" ;;
      *) echo "Install Reason  : Explicitly installed" ;;
    esac ;;
esac'
}

test_baseline_excluded_and_extras_found() {
  setup
  local out; out=$(scan_services)
  assert_json_eq '[.[].id] | sort' '["service:system:mystery.service","service:system:sshd.service","service:user:broken.service","service:user:myjob.service","service:user:superwhisper.service"]' "$out"
}

test_pacman_owned_system_unit() {
  setup
  local out; out=$(scan_services)
  assert_json_eq '.[] | select(.id=="service:system:sshd.service") | [.name,.kind,.category,.risk,.version,.private,.install.type,.install.package,.provenance.method]' \
    '["sshd.service","service","service","medium","10.0p1-1",false,"pacman","openssh","package-manager"]' "$out"
}

test_local_user_unit_is_copy() {
  setup
  local out; out=$(scan_services)
  assert_json_eq '.[] | select(.id=="service:user:myjob.service") | [.risk,.install.type,.install.path]' \
    "[\"low\",\"copy\",\"$HOME/.config/systemd/user/myjob.service\"]" "$out"
}

test_unowned_unit_is_unknown() {
  setup
  local out; out=$(scan_services)
  assert_json_eq '.[] | select(.id=="service:system:mystery.service") | [.install.type,.version,.provenance.method]' '["unknown",null,"fallback"]' "$out"
}

test_companion_units_of_baseline_service_excluded() {
  setup
  assert_json_eq 'map(select(.name | startswith("cups"))) | length' 0 "$(scan_services)"
}

test_output_validates() {
  setup
  jq -n --argjson items "$(scan_services)" '{schema_version:"1.0",machine:{hostname:"h",omarchy_version:"1",arch:"x86_64",gpu:[],form_factor:"desktop"},items:$items}' >"$T_TMP/m.json"
  assert_status 0 "$ROOT/scripts/validate-manifest" "$T_TMP/m.json"
}

test_missing_omarchy_dir_still_works() {
  setup
  export STARTKIN_OMARCHY_DIR=$T_TMP/nope
  local out; out=$(scan_services 2>/dev/null)
  assert_json_eq 'map(select(.name=="ufw.service")) | length' 1 "$out"
}

test_systemctl_failure_gives_empty() {
  setup
  stub systemctl 'exit 1'
  assert_eq '[]' "$(scan_services 2>/dev/null | jq -c .)"
}

run_tests
