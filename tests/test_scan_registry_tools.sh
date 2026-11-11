#!/usr/bin/env bash
# shellcheck disable=SC2031 # T_TMP/T_BIN are set per test by the harness, in the test's own subshell
# shellcheck disable=SC2016 # stub bodies are literal scripts for the stub to run, not expansions here
# shellcheck source=harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/scan/registry-tools.sh
source "$ROOT/lib/scan/registry-tools.sh"

# Every test runs with all six tools stubbed to "nothing installed", so the machine's real tools never leak in.
default_stubs() {
  local t
  for t in cargo uv pipx npm mise go; do stub "$t" 'exit 0'; done
  export HOME=$T_TMP/home GOBIN=$T_TMP/gobin
  mkdir -p "$HOME" "$GOBIN"
}

# stub_out TOOL TEXT : TOOL prints TEXT, whatever its arguments
stub_out() { printf '%s\n' "$2" >"$T_TMP/$1.out"; stub "$1" "cat '$T_TMP/$1.out'"; }

test_empty_machine() {
  default_stubs
  assert_json_eq '.' '[]' "$(scan_registry_tools)"
}

test_tools_missing_entirely() {
  mkdir -p "$T_TMP/only"
  ln -s "$(command -v jq)" "$T_TMP/only/jq"
  assert_json_eq '.' '[]' "$(PATH=$T_TMP/only scan_registry_tools 2>/dev/null)"
}

test_cargo() {
  default_stubs
  stub_out cargo 'bat v0.24.0:
    bat
cargo-nextest v0.9.149:
    cargo-nextest
gitty v1.0.0 (https://github.com/x/gitty#abc123):
    gitty
local v0.1.0 (/home/me/src/local):
    local'
  local out; out=$(scan_registry_tools 2>/dev/null)
  assert_json_eq 'map(.id)' '["cargo:bat","cargo:cargo-nextest"]' "$out"
  assert_json_eq '.[0].install' '{"type":"cargo","crate":"bat"}' "$out"
  assert_json_eq '.[0] | [.version,.kind,.category,.risk,.private,.provenance.method]' '["0.24.0","cli","registry-tool","low",false,"registry"]' "$out"
}

test_uv_ignores_executable_lines() {
  default_stubs
  stub_out uv 'browser-use v0.13.11
- browser
- bu
ruff v0.9.0'
  local out; out=$(scan_registry_tools 2>/dev/null)
  assert_json_eq 'map(.id)' '["uv:browser-use","uv:ruff"]' "$out"
  assert_json_eq '.[0] | [.install.package, .version]' '["browser-use","0.13.11"]' "$out"
}

test_pipx() {
  default_stubs
  stub_out pipx 'black 24.1.0
httpie 3.2.2'
  local out; out=$(scan_registry_tools 2>/dev/null)
  assert_json_eq 'map(.install)' '[{"type":"pipx","package":"black"},{"type":"pipx","package":"httpie"}]' "$out"
  assert_json_eq '.[1].version' '"3.2.2"' "$out"
}

test_npm_skips_npm_itself() {
  default_stubs
  stub_out npm '{"name":"lib","dependencies":{"npm":{"version":"11.2.0"},"corepack":{"version":"0.30.0"},"@scope/tool":{"version":"1.2.3"},"prettier":{"version":"3.0.0"}}}'
  local out; out=$(scan_registry_tools 2>/dev/null)
  assert_json_eq 'map(.id)' '["npm:@scope/tool","npm:prettier"]' "$out"
  assert_json_eq '.[0] | [.install.package, .name, .version]' '["@scope/tool","@scope/tool","1.2.3"]' "$out"
}

MISE_JSON='{
 "amp": [
  {"version":"0.1","installed":true,"active":false},
  {"version":"0.2","installed":true,"active":false},
  {"version":"0.3","requested_version":"latest","source":{"type":"mise.toml","path":"/etc/mise/conf.d/omarchy-tools.toml"},"installed":true,"active":true}],
 "node": [
  {"version":"24.0.0","requested_version":"latest","source":{"type":"mise.toml","path":"/etc/mise/conf.d/omarchy-tools.toml"},"installed":true,"active":true}],
 "go": [
  {"version":"1.26.0","installed":true,"active":false},
  {"version":"1.27.1","requested_version":"1.27.1","source":{"type":"mise.toml","path":"/home/u/.config/mise/config.toml"},"installed":true,"active":true}],
 "go:golang.org/x/tools/cmd/goimports": [
  {"version":"0.30.0","source":{"type":"mise.toml","path":"/home/u/.config/mise/config.toml"},"installed":true,"active":true}],
 "npm:@x/user-cli": [
  {"version":"2.0.0","source":{"type":"mise.toml","path":"/home/u/.config/mise/config.toml"},"installed":true,"active":true}],
 "leftover": [
  {"version":"1.0","installed":true,"active":false}],
 "not-installed": [
  {"version":"1.0","source":{"type":"mise.toml","path":"/home/u/.config/mise/config.toml"},"installed":false,"active":false}]
}'

test_mise_dedupes_and_skips_omarchy_and_stale() {
  default_stubs
  stub_out mise "$MISE_JSON"
  local out; out=$(scan_registry_tools 2>/dev/null)
  assert_json_eq 'map(.id)' '["mise:go","mise:go:golang.org/x/tools/cmd/goimports","mise:npm:@x/user-cli"]' "$out"
  assert_json_eq '.[0] | [.version,.kind,.install]' '["1.27.1","runtime",{"type":"mise","tool":"go"}]' "$out"
  assert_json_eq '.[1] | [.name,.kind,.install]' '["goimports","cli",{"type":"mise","tool":"go:golang.org/x/tools/cmd/goimports","backend":"go"}]' "$out"
  assert_json_eq '.[2] | [.name,.install.backend]' '["user-cli","npm"]' "$out"
}

test_go_binaries() {
  default_stubs
  printf 'x' >"$GOBIN/mytool"; chmod +x "$GOBIN/mytool"
  printf 'x' >"$GOBIN/notgo"; chmod +x "$GOBIN/notgo"
  stub go 'if [[ $1 == version && $2 == -m ]]; then
  case $3 in
    */mytool) printf "%s: go1.22.0\n\tpath\texample.com/org/mytool/cmd/mytool\n\tmod\texample.com/org/mytool\tv1.2.3\th1:abc\n\tdep\tfoo\tv1\n" "$3";;
    *) echo "$3: not a Go executable" >&2; exit 1;;
  esac
fi'
  local out; out=$(scan_registry_tools 2>/dev/null)
  assert_json_eq 'length' '1' "$out"
  assert_json_eq '.[0] | [.id,.name,.version,.install,.provenance.method]' \
    '["go:example.com/org/mytool/cmd/mytool","mytool","v1.2.3",{"type":"go","module":"example.com/org/mytool/cmd/mytool"},"build-metadata"]' "$out"
}

test_go_devel_version_is_null() {
  default_stubs
  printf 'x' >"$GOBIN/mytool"; chmod +x "$GOBIN/mytool"
  stub go 'printf "%s: go1.22.0\n\tpath\texample.com/mytool\n\tmod\texample.com/mytool\t(devel)\t\n" "$3"'
  assert_json_eq '.[0].version' 'null' "$(scan_registry_tools 2>/dev/null)"
}

test_one_failing_tool_does_not_hide_others() {
  default_stubs
  stub cargo 'echo boom >&2; exit 1'
  stub_out pipx 'black 24.1.0'
  assert_json_eq 'map(.id)' '["pipx:black"]' "$(scan_registry_tools 2>/dev/null)"
}

test_ids_unique_and_no_whitespace() {
  default_stubs
  stub_out cargo 'bat v1.0.0:
    bat'
  stub_out uv 'bat v2.0.0'
  stub_out mise "$MISE_JSON"
  assert_json_eq '(map(.id)|length) == (map(.id)|unique|length) and all(.[].id; test("^\\S+$"))' 'true' "$(scan_registry_tools 2>/dev/null)"
}

test_validates_against_schema() {
  default_stubs
  stub_out cargo 'bat v0.24.0:
    bat'
  stub_out uv 'ruff v0.9.0'
  stub_out pipx 'black 24.1.0'
  stub_out npm '{"dependencies":{"prettier":{"version":"3.0.0"}}}'
  stub_out mise "$MISE_JSON"
  printf 'x' >"$GOBIN/mytool"; chmod +x "$GOBIN/mytool"
  stub go 'printf "%s: go1.22.0\n\tpath\texample.com/mytool\n\tmod\texample.com/mytool\tv1.0.0\th1:x\n" "$3"'
  jq -n --argjson items "$(scan_registry_tools 2>/dev/null)" \
    '{schema_version:"1.0", machine:{hostname:"h",omarchy_version:"1",arch:"x86_64",gpu:[],form_factor:"desktop"}, items:$items}' >"$T_TMP/m.json"
  "$ROOT/scripts/validate-manifest" "$T_TMP/m.json" >/dev/null 2>"$T_TMP/err"
  local rc=$?
  if ((rc == 2)); then echo "    skipped: no schema validator available" >&2; return; fi
  assert_eq 0 "$rc" "manifest validates ($(<"$T_TMP/err"))"
}

run_tests
