# Engine

The engine is bash + jq (decision: no compiled language; revisit only if it outgrows that). Entry point: `bin/startkin`.

## Layout

| Path | Role |
|---|---|
| `bin/startkin` | Dispatcher: `scan`, `export`, `apply`, `peers`, `--version`, `--help`. `--version`, `--help`, `scan --json`, `adopt` and `track install` are real; the rest print `not implemented` and exit 2. |
| `lib/common.sh` | Shared helpers: `log`, `warn`, `die [-c CODE]`, `require_cmd`, `version`, `now_utc`. |
| `lib/machine.sh` | Machine info for the manifest header (hostname, Omarchy version from pacman, arch, GPU vendors from `lspci`, form factor). |
| `lib/scan.sh` | Scanner discovery and manifest assembly. |
| `lib/registry.sh` | User-confirmed provenance registry and the scan overlay (`docs/adopt.md`). |
| `lib/adopt.sh`, `lib/track.sh`, `lib/ui.sh` | `adopt` and `track install` subcommands; gum/`read` prompts. |
| `lib/scan/<name>.sh` | One scanner per file (see below). |
| `VERSION` | Engine version. |

## Scanner contract

The dispatcher auto-discovers every `lib/scan/*.sh` (sorted by file name). To add a scanner, add a file; do not touch the dispatcher.

1. File `lib/scan/<name>.sh` defines a function `scan_<name>` (dashes in `<name>` become underscores: `lib/scan/cargo-tools.sh` defines `scan_cargo_tools`).
2. The function prints a JSON array of items on stdout and nothing else on stdout. Diagnostics go to stderr (`warn`, `log` from `lib/common.sh` are available).
3. Item shape is defined by `schema/manifest.schema.json` and `docs/manifest.md`. An empty result is `[]`.
4. Each scanner runs in its own subshell, with `lib/common.sh` helpers loaded and `STARTKIN_ROOT` set. Do not rely on state from other scanners. The file is sourced, so it must not run anything at top level.
5. Failure: exit non-zero, a missing function, or output that is not a JSON array. The dispatcher warns on stderr, skips that scanner, still prints the manifest with the other scanners' items, and exits 3.

`STARTKIN_SCAN_DIR` overrides the scanner directory (used by tests).

## Manifest header

`startkin scan --json` prints `{schema_version: "1.0", generated_at, machine{hostname, omarchy_version, arch, gpu[], form_factor}, items[]}`, validated by `schema/manifest.schema.json` (`scripts/validate-manifest`). `omarchy_version` is the pacman version of `omarchy` (or `omarchy-dev`), `"unknown"` if neither is installed. `gpu` has one vendor string per GPU (`intel`, `amd`, `nvidia`, `other`). `form_factor` is `vm` when `systemd-detect-virt --vm` says so, otherwise from the DMI chassis type: `desktop`, `laptop`, `server`, `other`. If the schema changes, the schema wins and `lib/scan.sh`/`lib/machine.sh` follow.

## Tests

Plain bash, no bats: bats is not installed by default on Omarchy, and a 40-line runner plus `tests/assert.sh` covers what is needed. `tests/run.sh` runs each `tests/test_*.sh`; each file defines `test_*` functions and ends with `run_tests` (from `tests/harness.sh`), which runs every function in a subshell with a fresh `$T_TMP` and a stub dir `$T_BIN` first on `PATH` (create stubs with `stub NAME 'body'`). Assertions: `assert_eq`, `assert_contains`, `assert_status CODE CMD...` (sets `$T_OUT`, `$T_ERR`), `assert_json_eq JQ EXPECTED JSON`. Run a scanner's tests by stubbing the system tools it calls.

## Check and hooks

`./check` runs `bash -n`, `shellcheck` (config in `.shellcheckrc`) and `tests/run.sh` over the repo's own shell files (not `scripts/devkit`). `scripts/install-hooks` installs `.githooks/pre-commit`, which runs `./check`. Every shellcheck warning is fixed, not suppressed, unless a `disable` carries a reason.

## Devkit

`scripts/devkit` is the omarchy-plugin-devkit submodule pinned to a release tag; `devkit.conf` configures it. After cloning: `git submodule update --init`. Do not edit files inside it.
