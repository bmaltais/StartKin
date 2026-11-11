#!/usr/bin/env bash
# Machine info collection for the manifest header. Each function prints one plain value; machine_json prints the object.
# STARTKIN_DMI_DIR overrides /sys/class/dmi/id (tests).
# shellcheck shell=bash

machine_hostname() { hostname 2>/dev/null || uname -n; }

# Omarchy version from pacman (package "omarchy", or "omarchy-dev" on dev installs); empty when not installed.
machine_omarchy_version() {
  local pkg out
  for pkg in omarchy omarchy-dev; do
    if out=$(pacman -Q "$pkg" 2>/dev/null); then
      echo "${out#* }"
      return 0
    fi
  done
  return 0
}

machine_arch() { uname -m; }

# JSON array of GPU vendors, one entry per GPU: "intel" | "amd" | "nvidia" | "other". Empty array if none detected.
machine_gpu_json() {
  lspci -mm 2>/dev/null | awk -F'"' '
    $2 ~ /VGA compatible controller|3D controller|Display controller/ {
      v = tolower($4)
      if (v ~ /nvidia/) print "nvidia"
      else if (v ~ /advanced micro|amd|ati tech/) print "amd"
      else if (v ~ /intel/) print "intel"
      else print "other"
    }' | jq -R . | jq -sc .
}

# desktop | laptop | server | vm | other. A virtual machine wins; otherwise the SMBIOS chassis type.
machine_form_factor() {
  local f=${STARTKIN_DMI_DIR:-/sys/class/dmi/id}/chassis_type t virt
  if virt=$(systemd-detect-virt --vm 2>/dev/null) && [[ $virt != none ]]; then echo vm; return 0; fi
  [[ -r $f ]] || { echo other; return 0; }
  t=$(<"$f")
  case $t in
    3 | 4 | 5 | 6 | 7 | 13 | 15 | 16 | 24 | 34 | 35 | 36) echo desktop ;;
    8 | 9 | 10 | 11 | 12 | 14 | 31 | 32) echo laptop ;;
    17 | 23 | 25 | 28) echo server ;;
    *) echo other ;;
  esac
}

# machine_json : {"hostname","omarchy_version"("unknown" if Omarchy is not a package),"arch","gpu"[],"form_factor"}
machine_json() {
  jq -n \
    --arg hostname "$(machine_hostname)" \
    --arg omarchy "$(machine_omarchy_version)" \
    --arg arch "$(machine_arch)" \
    --argjson gpu "$(machine_gpu_json)" \
    --arg ff "$(machine_form_factor)" \
    '{hostname: $hostname,
      omarchy_version: (if $omarchy == "" then "unknown" else $omarchy end),
      arch: $arch, gpu: $gpu, form_factor: $ff}'
}
