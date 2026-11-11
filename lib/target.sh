#!/usr/bin/env bash
# Target-awareness: which manifest items cannot work on this machine (docs/engine.md "Target awareness").
# Pure comparison of a manifest against a target machine JSON; apply (#13/#14) and the UI consume the result.
# Needs jq and lib/drift.sh. Does not touch the network or the filesystem beyond the manifest file.
# shellcheck shell=bash

# machine_libc : glibc | musl | empty when ldd is missing. musl's ldd prints "musl libc" (and exits 1).
machine_libc() {
  local out
  out=$(ldd --version 2>&1) || true
  case $out in
    *musl*) echo musl ;;
    *"GNU libc"* | *GLIBC* | *glibc*) echo glibc ;;
  esac
  return 0
}

# machine_json_with_libc : machine_json plus a "libc" field (target-side only; the manifest schema has no libc)
machine_json_with_libc() {
  machine_json | jq --arg l "$(machine_libc)" '. + {libc: $l}'
}

# jq program: args $target (machine JSON with optional libc), $drift. Input: manifest.
# Item status: ok | warn (may not work or may be pointless) | incompatible (cannot work, apply must skip, UI hides).
# shellcheck disable=SC2016 # jq program, not shell
_TARGET_JQ='
def norm_arch: if . == "arm64" then "aarch64" elif . == "amd64" then "x86_64" else . end;
def key: ((.install.package // .name // "") | ascii_downcase | sub("\\.(service|socket|timer)$"; ""));
def r(code; msg): {code: code, message: msg};

# Packages bound to one GPU vendor.
def gpu_vendor:
  key as $k
  | if ($k | test("^(lib32-)?(nvidia|cuda|cudnn|libva-nvidia|egl-wayland|opencl-nvidia)") or ($k | test("-nvidia($|-)"))) then "nvidia"
    elif ($k | test("^(lib32-)?(vulkan-radeon|xf86-video-(amdgpu|ati)|amdvlk|radeontop|rocm-|hip-|opencl-mesa|lact$|corectrl$)")) then "amd"
    elif ($k | test("^(lib32-)?(vulkan-intel|intel-media-driver|libva-intel-driver|xf86-video-intel|intel-gpu-tools|intel-compute-runtime)")) then "intel"
    else null end;

def laptop_only: key | test("^(tlp|tlp-rdw|auto-cpufreq|brightnessctl|iio-sensor-proxy|libinput-gestures|laptop-mode-tools)$");

def arch_bound:
  .install.type as $t
  | ($t == "release-binary" or $t == "appimage")
    or ($t == "copy" and .category == "repo-tool" and (.kind == "cli" or .kind == "gui-app" or .kind == "runtime"));

def checks($src; $tgt):
  [
    (if ($src.arch | norm_arch) != ($tgt.arch | norm_arch) then
       if arch_bound then {s: "incompatible", r: r("arch"; "built for \($src.arch), target is \($tgt.arch)")}
       elif (.install.type == "pacman" or .install.type == "aur") then {s: "warn", r: r("arch"; "package may not exist for \($tgt.arch)")}
       else empty end
     else empty end),
    (if arch_bound and ($tgt.libc // "") == "musl"
        and (((.install.url // "") + (.install.path // "")) | test("musl"; "i") | not)
     then {s: "incompatible", r: r("libc"; "prebuilt binary is not known to be musl-compatible; target uses musl")} else empty end),
    (gpu_vendor as $v
     | if $v == null then empty
       elif ($tgt.gpu | index($v)) != null then empty
       elif ($tgt.gpu | length) == 0 then {s: "warn", r: r("gpu"; "needs \($v) GPU; target GPU not detected")}
       else {s: "incompatible", r: r("gpu"; "needs \($v) GPU; target has \($tgt.gpu | join(", "))")} end),
    (if laptop_only and $tgt.form_factor != "laptop" then {s: "warn", r: r("form-factor"; "laptop-oriented; target is a \($tgt.form_factor)")} else empty end)
  ];

.machine as $src
| (.items | map(
    checks($src; $target) as $cs
    | {id: .id,
       status: (if any($cs[]; .s == "incompatible") then "incompatible" elif ($cs | length) > 0 then "warn" else "ok" end),
       reasons: ($cs | map(.r))}
  )) as $items
| {target: $target,
   drift: $drift,
   summary: {ok: ($items | map(select(.status == "ok")) | length),
             warn: ($items | map(select(.status == "warn")) | length),
             incompatible: ($items | map(select(.status == "incompatible")) | length)},
   items: $items}
'

# target_check_manifest MANIFEST_FILE TARGET_MACHINE_JSON
# Prints {target, drift, summary{ok,warn,incompatible}, items[{id, status, reasons[{code,message}]}]}, one entry per manifest
# item, in manifest order. codes: arch, libc, gpu, form-factor. drift is drift_compare_machines (same|source-older|source-newer|unknown).
target_check_manifest() {
  local manifest=$1 target=$2 drift
  drift=$(drift_compare_machines "$(jq -c .machine "$manifest")" "$target") || return 1
  jq --argjson target "$target" --arg drift "$drift" "$_TARGET_JQ" "$manifest"
}

# target_filter_manifest MANIFEST_FILE TARGET_MACHINE_JSON
# Prints the manifest with incompatible items removed (warn items stay; consult target_check_manifest for the flags).
target_filter_manifest() {
  local checks
  checks=$(target_check_manifest "$1" "$2") || return 1
  jq --argjson c "$checks" '($c.items | map(select(.status == "incompatible") | .id)) as $bad
    | .items |= map(select(.id as $i | $bad | index($i) | not))' "$1"
}
