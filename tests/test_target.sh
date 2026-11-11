#!/usr/bin/env bash
# shellcheck disable=SC2031 # T_TMP is set per test by the harness, in the test's own subshell
# shellcheck source=harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/drift.sh
source "$ROOT/lib/drift.sh"
# shellcheck source=../lib/machine.sh
source "$ROOT/lib/machine.sh"
# shellcheck source=../lib/target.sh
source "$ROOT/lib/target.sh"

SRC_M='{"hostname":"a","omarchy_version":"3.4.0-1","arch":"x86_64","gpu":["nvidia"],"form_factor":"laptop"}'

# manifest ITEM_JSON... : a manifest from SRC_M with the given items written to $T_TMP/m.json
manifest() {
  local items
  items=$(printf '%s\n' "$@" | jq -s .)
  jq -n --argjson m "$SRC_M" --argjson i "$items" '{schema_version:"1.0",machine:$m,items:$i}' >"$T_TMP/m.json"
}
pkg() { jq -nc --arg p "$1" '{id:("pacman:"+$p),name:$p,kind:"cli",category:"package",install:{type:"pacman",package:$p}}'; }
rbin() { jq -nc --arg t "$1" --arg u "$2" '{id:("rb:"+$u),name:$u,kind:"cli",category:"repo-tool",install:{type:$t,url:("https://e/"+$u)}}'; }
# tgt ARCH GPU_JSON FORM [LIBC] [VERSION]
tgt() {
  jq -nc --arg a "$1" --argjson g "$2" --arg f "$3" --arg l "${4-glibc}" --arg v "${5-3.4.0-1}" \
    '{hostname:"b",omarchy_version:$v,arch:$a,gpu:$g,form_factor:$f,libc:$l}'
}
status_of() { jq -r --arg id "$1" '.items[] | select(.id == $id) | .status' <<<"$2"; }

test_binary_across_arch_is_incompatible() {
  manifest "$(rbin release-binary x)"
  local out
  out=$(target_check_manifest "$T_TMP/m.json" "$(tgt aarch64 '["amd"]' desktop)")
  assert_eq incompatible "$(status_of rb:x "$out")"
  assert_eq arch "$(jq -r '.items[0].reasons[0].code' <<<"$out")"
}

test_binary_same_arch_ok() {
  manifest "$(rbin release-binary x)"
  assert_eq ok "$(status_of rb:x "$(target_check_manifest "$T_TMP/m.json" "$(tgt x86_64 '["nvidia"]' laptop)")")"
}

test_arm64_equals_aarch64() {
  SRC_M='{"hostname":"a","omarchy_version":"3.4.0-1","arch":"arm64","gpu":[],"form_factor":"laptop"}'
  manifest "$(rbin appimage x)"
  assert_eq ok "$(status_of rb:x "$(target_check_manifest "$T_TMP/m.json" "$(tgt aarch64 '[]' laptop)")")"
}

test_copied_binary_across_arch_incompatible_but_config_ok() {
  manifest '{"id":"rt:b","name":"b","kind":"cli","category":"repo-tool","install":{"type":"copy","path":"~/.local/bin/b"}}' \
    '{"id":"cfg:c","name":"c","kind":"config","category":"config","install":{"type":"copy","path":"~/.config/c"}}'
  local out
  out=$(target_check_manifest "$T_TMP/m.json" "$(tgt aarch64 '[]' laptop)")
  assert_eq incompatible "$(status_of rt:b "$out")"
  assert_eq ok "$(status_of cfg:c "$out")"
}

test_package_across_arch_warns() {
  manifest "$(pkg ripgrep)"
  assert_eq warn "$(status_of pacman:ripgrep "$(target_check_manifest "$T_TMP/m.json" "$(tgt aarch64 '[]' laptop)")")"
}

test_musl_target_rejects_glibc_binary() {
  manifest "$(rbin release-binary x-linux)" "$(rbin release-binary y-musl)"
  local out
  out=$(target_check_manifest "$T_TMP/m.json" "$(tgt x86_64 '["nvidia"]' laptop musl)")
  assert_eq incompatible "$(status_of rb:x-linux "$out")"
  assert_eq ok "$(status_of rb:y-musl "$out")"
}

test_nvidia_package_on_amd_incompatible() {
  manifest "$(pkg nvidia-open-dkms)" "$(pkg lib32-nvidia-utils)" "$(pkg cuda)" "$(pkg nvtop)"
  local out
  out=$(target_check_manifest "$T_TMP/m.json" "$(tgt x86_64 '["amd"]' laptop)")
  assert_eq incompatible "$(status_of pacman:nvidia-open-dkms "$out")"
  assert_eq incompatible "$(status_of pacman:lib32-nvidia-utils "$out")"
  assert_eq incompatible "$(status_of pacman:cuda "$out")"
  assert_eq ok "$(status_of pacman:nvtop "$out")"
}

test_nvidia_package_on_nvidia_ok() {
  manifest "$(pkg nvidia-open-dkms)"
  assert_eq ok "$(status_of pacman:nvidia-open-dkms "$(target_check_manifest "$T_TMP/m.json" "$(tgt x86_64 '["intel","nvidia"]' laptop)")")"
}

test_gpu_unknown_target_warns() {
  manifest "$(pkg nvidia-utils)"
  assert_eq warn "$(status_of pacman:nvidia-utils "$(target_check_manifest "$T_TMP/m.json" "$(tgt x86_64 '[]' vm)")")"
}

test_amd_and_intel_packages() {
  manifest "$(pkg vulkan-radeon)" "$(pkg intel-media-driver)"
  local out
  out=$(target_check_manifest "$T_TMP/m.json" "$(tgt x86_64 '["nvidia"]' desktop)")
  assert_eq incompatible "$(status_of pacman:vulkan-radeon "$out")"
  assert_eq incompatible "$(status_of pacman:intel-media-driver "$out")"
}

test_laptop_package_on_desktop_warns() {
  manifest "$(pkg tlp)" '{"id":"service:tlp.service","name":"tlp.service","kind":"service","category":"service","install":{"type":"unknown"}}'
  local out
  out=$(target_check_manifest "$T_TMP/m.json" "$(tgt x86_64 '["nvidia"]' desktop)")
  assert_eq warn "$(status_of pacman:tlp "$out")"
  assert_eq warn "$(status_of service:tlp.service "$out")"
  out=$(target_check_manifest "$T_TMP/m.json" "$(tgt x86_64 '["nvidia"]' laptop)")
  assert_eq ok "$(status_of pacman:tlp "$out")"
}

test_summary_and_drift() {
  manifest "$(pkg ripgrep)" "$(pkg cuda)"
  local out
  out=$(target_check_manifest "$T_TMP/m.json" "$(tgt x86_64 '["amd"]' laptop glibc 3.5.0-1)")
  assert_eq source-older "$(jq -r .drift <<<"$out")"
  assert_eq '{"ok":1,"warn":0,"incompatible":1}' "$(jq -c .summary <<<"$out")"
  assert_eq b "$(jq -r .target.hostname <<<"$out")"
}

test_filter_hides_incompatible_keeps_warn() {
  manifest "$(pkg ripgrep)" "$(pkg cuda)" "$(pkg tlp)"
  local out
  out=$(target_filter_manifest "$T_TMP/m.json" "$(tgt x86_64 '["amd"]' desktop)")
  assert_eq '["pacman:ripgrep","pacman:tlp"]' "$(jq -c '[.items[].id]' <<<"$out")"
  assert_eq 3.4.0-1 "$(jq -r .machine.omarchy_version <<<"$out")"
}

test_libc_detection() {
  stub ldd 'echo "musl libc (x86_64)"; exit 1'
  assert_eq musl "$(machine_libc)"
  stub ldd 'echo "ldd (GNU libc) 2.40"'
  assert_eq glibc "$(machine_libc)"
}

test_machine_json_with_libc() {
  stub ldd 'echo "ldd (GNU libc) 2.40"'
  stub pacman 'echo "omarchy 3.4.0-1"'
  stub lspci 'true'
  stub systemd-detect-virt 'echo none; exit 1'
  assert_eq glibc "$(STARTKIN_DMI_DIR=$T_TMP/x machine_json_with_libc | jq -r .libc)"
}

run_tests
