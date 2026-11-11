#!/usr/bin/env bash
# shellcheck disable=SC2031 # T_TMP is set per test by the harness, in the test's own subshell
# shellcheck source=harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/machine.sh
source "$ROOT/lib/machine.sh"

test_form_factor_mapping() {
  mkdir -p "$T_TMP/dmi"
  stub systemd-detect-virt 'echo none; exit 1'
  local pair
  for pair in 3:desktop 10:laptop 9:laptop 31:laptop 8:laptop 13:desktop 23:server 30:other 99:other; do
    echo "${pair%%:*}" >"$T_TMP/dmi/chassis_type"
    assert_eq "${pair##*:}" "$(STARTKIN_DMI_DIR=$T_TMP/dmi machine_form_factor)" "chassis ${pair%%:*}"
  done
}

test_form_factor_missing() {
  stub systemd-detect-virt 'exit 1'
  assert_eq other "$(STARTKIN_DMI_DIR=$T_TMP/nope machine_form_factor)"
}

test_form_factor_vm() {
  stub systemd-detect-virt 'echo kvm'
  assert_eq vm "$(STARTKIN_DMI_DIR=$T_TMP/nope machine_form_factor)"
}

test_gpu() {
  stub lspci 'printf "00:02.0 \"VGA compatible controller\" \"Intel Corporation\" \"X\"\n01:00.0 \"3D controller\" \"NVIDIA Corporation\" \"Y\"\n02:00.0 \"Ethernet controller\" \"Realtek\" \"Z\"\n"'
  assert_eq '["intel","nvidia"]' "$(machine_gpu_json)"
}

test_gpu_amd() {
  stub lspci 'printf "06:00.0 \"Display controller\" \"Advanced Micro Devices, Inc. [AMD/ATI]\" \"Z\"\n"'
  assert_eq '["amd"]' "$(machine_gpu_json)"
}

test_gpu_none() {
  stub lspci 'exit 1'
  assert_eq '[]' "$(machine_gpu_json)"
}

test_omarchy_version_from_pacman() {
  # shellcheck disable=SC2016 # the stub body expands when it runs
  stub pacman '[[ $1 == -Q && $2 == omarchy ]] && echo "omarchy 3.4.1-1" || exit 1'
  assert_eq "3.4.1-1" "$(machine_omarchy_version)"
}

test_omarchy_version_absent() {
  stub pacman 'exit 1'
  assert_eq "" "$(machine_omarchy_version)"
}

test_machine_json() {
  stub pacman 'exit 1'
  stub lspci 'exit 1'
  stub hostname 'echo testbox'
  local j
  j=$(STARTKIN_DMI_DIR=$T_TMP/nope machine_json)
  assert_json_eq '.hostname' '"testbox"' "$j"
  assert_json_eq '.omarchy_version' '"unknown"' "$j"
  assert_json_eq '.gpu' '[]' "$j"
  assert_json_eq '.arch' "\"$(uname -m)\"" "$j"
}

run_tests
