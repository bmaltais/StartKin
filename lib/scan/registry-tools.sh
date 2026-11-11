#!/usr/bin/env bash
# Scanner: tools installed through language registries: cargo, uv, pipx, global npm, mise, Go binaries.
# Contract: docs/engine.md. Each source is optional; a missing or failing tool is skipped, never fatal.
# shellcheck shell=bash

# rt_items MGR FIELD EVIDENCE [CONFIDENCE] [METHOD] : read TSV rows on stdin, print a JSON array of items.
# Columns: install value (crate/package/module/tool), version, display name, kind, mise backend. Empty = default.
rt_items() {
  jq -R -s -c --arg mgr "$1" --arg field "$2" --arg ev "$3" \
    --argjson conf "${4:-0.95}" --arg method "${5:-registry}" '
    split("\n") | map(select(length > 0) | split("\t")) | map(
      {value: .[0], version: (.[1] // ""), backend: (.[4] // ""),
       name: (if (.[2] // "") == "" then .[0] else .[2] end),
       kind: (if (.[3] // "") == "" then "cli" else .[3] end)}
      | {id: ($mgr + ":" + .value), name, kind, category: "registry-tool", risk: "low",
         install: ({type: $mgr} + {($field): .value} + (if .backend != "" then {backend: .backend} else {} end)),
         version: (if .version == "" then null else .version end),
         provenance: {method: $method, confidence: $conf, evidence: [$ev]},
         private: false})'
}

# rt_run TOOL ARGS... : run TOOL if installed; on failure warn and print nothing. stdout is the tool's output.
rt_run() {
  local tool=$1 out
  command -v "$tool" >/dev/null 2>&1 || { log "registry-tools: $tool not installed, skipping"; return 1; }
  if ! out=$("$@" 2>/dev/null); then
    warn "registry-tools: '$*' failed, skipping"
    return 1
  fi
  printf '%s\n' "$out"
}

# Registry crates only. Git and path installs carry "(source)" and are not reproducible from the crate name.
rt_cargo() {
  local out line re='^([^[:space:]]+) v([^[:space:]:]+)( \(.*\))?:$'
  out=$(rt_run cargo install --list) || return 0
  while IFS= read -r line; do
    [[ $line =~ $re ]] || continue
    if [[ -n ${BASH_REMATCH[3]} ]]; then
      log "registry-tools: cargo ${BASH_REMATCH[1]} is not from a registry, skipping"
      continue
    fi
    printf '%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  done <<<"$out" | rt_items cargo crate "cargo install --list"
}

rt_uv() {
  local out line re='^([A-Za-z0-9._-]+) v([^[:space:]]+)'
  out=$(rt_run uv tool list) || return 0
  while IFS= read -r line; do
    if [[ $line =~ $re ]]; then printf '%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; fi
  done <<<"$out" | rt_items uv package "uv tool list"
}

rt_pipx() {
  local out name ver
  out=$(rt_run pipx list --short) || return 0
  while read -r name ver _; do
    if [[ -n $name ]]; then printf '%s\t%s\n' "$name" "$ver"; fi
  done <<<"$out" | rt_items pipx package "pipx list --short"
}

# npm and corepack ship with node, so they are not user installs.
rt_npm() {
  local out
  out=$(rt_run npm ls -g --json --depth=0) || return 0
  jq -r '(.dependencies // {}) | to_entries[] | select(.key != "npm" and .key != "corepack") | [.key, (.value.version // "")] | @tsv' <<<"$out" |
    rt_items npm package "npm ls -g"
}

# mise: one item per tool, at the version the user's config pins. Omarchy's own tools (declared under /etc/mise)
# and leftover installs that no config requests (old versions of auto-updating tools) are dropped.
rt_mise() {
  local out
  out=$(rt_run mise ls --json) || return 0
  jq -r '
    def runtimes: ["node","go","rust","python","ruby","java","bun","deno","erlang","elixir","zig","php","dotnet","lua"];
    to_entries[]
    | . as $e
    | select([$e.value[].source.path // ""] | any(startswith("/etc/mise/")) | not)
    | ($e.value | map(select(.installed and .source))) as $s
    | select($s | length > 0)
    | ($s | (map(select(.active))[0] // .[0])) as $pick
    | [$e.key, $pick.version,
       ($e.key | sub("^[^:]*:"; "") | split("/") | last),
       (if (runtimes | index($e.key)) then "runtime" else "cli" end),
       (if ($e.key | contains(":")) then ($e.key | split(":")[0]) else "" end)]
    | @tsv' <<<"$out" | rt_items mise tool "mise ls --json"
}

# Go binaries in $GOBIN or $GOPATH/bin (default ~/go/bin). `go version -m` yields the main package path and version.
rt_go() {
  local dir bin out path ver kind rest
  command -v go >/dev/null 2>&1 || { log "registry-tools: go not installed, skipping"; return 0; }
  dir=${GOBIN:-${GOPATH:+${GOPATH%%:*}/bin}}
  dir=${dir:-$HOME/go/bin}
  [[ -d $dir ]] || return 0
  for bin in "$dir"/*; do
    [[ -f $bin && -x $bin ]] || continue
    out=$(go version -m "$bin" 2>/dev/null) || continue
    path="" ver=""
    while IFS=$'\t' read -r kind rest; do
      case $kind in
        path) path=$rest ;;
        mod) ver=${rest#*$'\t'}; ver=${ver%%$'\t'*} ;;
      esac
    done <<<"$out"
    [[ -n $path ]] || continue
    [[ $ver == "(devel)" ]] && ver=""
    printf '%s\t%s\t%s\n' "$path" "$ver" "${bin##*/}"
  done | rt_items go module "go version -m $dir/*" 0.9 build-metadata
}

scan_registry_tools() {
  local part parts=()
  for part in rt_cargo rt_uv rt_pipx rt_npm rt_mise rt_go; do
    parts+=("$("$part")")
  done
  printf '%s\n' "${parts[@]}" | jq -s -c 'map(select(. != null)) | add // []'
}
