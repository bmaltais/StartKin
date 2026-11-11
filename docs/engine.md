# Engine

The engine is bash + jq (decision: no compiled language; revisit only if it outgrows that). Entry point: `bin/startkin`.

## Layout

| Path | Role |
|---|---|
| `bin/startkin` | Dispatcher: `scan`, `export`, `apply`, `peers`, `--version`, `--help`. `--version`, `--help`, `scan --json`, `export`, `adopt`, `track install`, `peers` and `apply` (packages and tools) are real; the rest print `not implemented` and exit 2. |
| `lib/common.sh` | Shared helpers: `log`, `warn`, `die [-c CODE]`, `require_cmd`, `version`, `now_utc`. |
| `lib/drift.sh` | Omarchy version drift: `drift_compare_versions`, `drift_compare_machines`, `drift_warn`, `drift_check_manifest` (see "Version drift"). |
| `lib/target.sh` | Target-awareness: `target_check_manifest`, `target_filter_manifest`, `machine_libc` (see "Target awareness"). |
| `lib/machine.sh` | Machine info for the manifest header (hostname, Omarchy version from pacman, arch, GPU vendors from `lspci`, form factor). |
| `lib/scan.sh` | Scanner discovery and manifest assembly. |
| `lib/registry.sh` | User-confirmed provenance registry and the scan overlay (`docs/adopt.md`). |
| `lib/export.sh` | `export` subcommand: live manifest or saved snapshot to stdout or a file. |
| `lib/adopt.sh`, `lib/track.sh`, `lib/ui.sh` | `adopt` and `track install` subcommands; gum/`read` prompts. |
| `lib/apply.sh` | `apply` subcommand: stage framework, reconcile, packages / registry tools / repo tools (see "Apply"). |
| `lib/peers.sh` | `peers` subcommand: Tailscale peer list and manifest fetch over SSH. |
| `lib/scan/<name>.sh` | One scanner per file (see below). |
| `VERSION` | Engine version. |

## Scanner contract

The dispatcher auto-discovers every `lib/scan/*.sh` (sorted by file name). To add a scanner, add a file; do not touch the dispatcher.

1. File `lib/scan/<name>.sh` defines a function `scan_<name>` (dashes in `<name>` become underscores: `lib/scan/cargo-tools.sh` defines `scan_cargo_tools`).
2. The function prints a JSON array of items on stdout and nothing else on stdout. Diagnostics go to stderr (`warn`, `log` from `lib/common.sh` are available).
3. Item shape is defined by `schema/manifest.schema.json` and `docs/manifest.md`. An empty result is `[]`.
4. Each scanner runs in its own subshell, with `lib/common.sh` helpers loaded and `STARTKIN_ROOT` set. Do not rely on state from other scanners. The file is sourced, so it must not run anything at top level.
5. Failure: exit non-zero, a missing function, or output that is not a JSON array. The dispatcher warns on stderr, skips that scanner, still prints the manifest with the other scanners' items, and exits 3. Before printing, the manifest goes through the secrets gate (`docs/secrets-policy.md`, rule 4): on a finding nothing is printed to stdout and the exit code is 4.

`STARTKIN_SCAN_DIR` overrides the scanner directory (used by tests).

## Manifest header

`startkin scan --report` prints how well the untracked binaries and app dirs (`repo-tool` items) were traced: `items N: exact E, heuristic H, unknown U` (exact = confidence 0.9 or more, heuristic = between 0 and 0.9, unknown = method `none`) and one `  METHOD: COUNT` line per provenance method (`prov_report` in `lib/provenance.sh`; the registry overlay is applied first, so adopted items count as exact). It exits 3 when a scanner failed, like `--json`.

`startkin scan --json` prints `{schema_version: "1.0", generated_at, machine{hostname, omarchy_version, arch, gpu[], form_factor}, items[]}`, validated by `schema/manifest.schema.json` (`scripts/validate-manifest`). `omarchy_version` is the pacman version of `omarchy` (or `omarchy-dev`), `"unknown"` if neither is installed. `gpu` has one vendor string per GPU (`intel`, `amd`, `nvidia`, `other`). `form_factor` is `vm` when `systemd-detect-virt --vm` says so, otherwise from the DMI chassis type: `desktop`, `laptop`, `server`, `other`. If the schema changes, the schema wins and `lib/scan.sh`/`lib/machine.sh` follow.

## Export and snapshots

`startkin export [--out FILE] [--from SNAPSHOT]` (docs/design.md, Saved snapshots). Without options it prints the live manifest, exactly like `scan --json`. `--out FILE` writes it to FILE instead (mode 600, via a temp file in the same directory and a rename, so a failed export never truncates an existing snapshot). `--from SNAPSHOT` uses a saved manifest instead of scanning: it must be a JSON object with `schema_version` and an `items` array (else exit 1). Exit codes: 0 ok, 1 error, 2 usage, 3 a scanner failed (manifest still written), 4 withheld by the secrets gate. The gate (`docs/secrets-policy.md`, rule 4) runs on every path: live output through `scan_manifest`, snapshots through `export_gate_snapshot`. On a finding nothing is printed or written; kind and JSON location go to stderr.

## Version drift

Each manifest records the source's `machine.omarchy_version`; the scan baseline is always the scanning machine's own Omarchy, so a manifest only lists what was added on top of that version. When a manifest is applied on a machine with a different version, `lib/drift.sh` compares the two (`sort -V`: `same`, `source-older`, `source-newer`, `unknown`) and `drift_warn` warns once up front, never failing. Decision on items that became Omarchy defaults in a newer target version: they are not dropped or errored. Apply's normal "already present on the target" check treats them as satisfied and skips them, and when the versions differ the report says so ("now in Omarchy defaults or already installed"). Items from a newer source than the target warn that they may need things the target lacks. An `unknown` version on either side warns that defaults cannot be compared. Target-awareness (#15) reuses `drift_compare_machines`.

## Target awareness

`lib/target.sh` (#15) compares a manifest with the machine it would be applied on. `target_check_manifest MANIFEST TARGET_JSON` prints `{target, drift, summary{ok,warn,incompatible}, items[{id, status, reasons[{code,message}]}]}`, one entry per manifest item. `TARGET_JSON` is `machine_json_with_libc` (the manifest machine object plus `libc`: `glibc`, `musl` or empty; the manifest itself has no libc field). `drift` is `drift_compare_machines`. Status `incompatible` means it cannot work: apply must skip it and the UI hides it. `warn` means it may not work or is pointless: apply and the UI show it flagged. Reason codes:

- `arch`: release-binary, appimage and copied binaries (`repo-tool` copy of cli/gui-app/runtime) from another architecture are incompatible; pacman/aur packages warn. `arm64`/`aarch64` and `amd64`/`x86_64` are the same.
- `libc`: on a musl target, prebuilt binaries whose URL/path does not mention musl are incompatible.
- `gpu`: packages named for one vendor (`nvidia*`, `cuda*`, `vulkan-radeon`, `intel-media-driver`, ...) are incompatible when the target has no such GPU, warn when the target GPU list is empty (undetected).
- `form-factor`: laptop-oriented packages/services (`tlp`, `brightnessctl`, ...) warn on non-laptops.

Omarchy version drift is reported once in `drift`, not per item. `target_filter_manifest MANIFEST TARGET_JSON` prints the manifest minus the incompatible items. The rules are name and type heuristics; extend the lists in `lib/target.sh` as false negatives show up.

## Apply

`startkin apply MANIFEST | --from-peer PEER [--dry-run] [--yes] [--only IDS]` (#13; `lib/apply.sh`). The manifest comes from a file (a snapshot) or `peers_fetch`; it must be schema 1.x with unique item ids, else exit 15. Flow: `drift_check_manifest` warns once about Omarchy version drift; `--only` narrows by id; `target_check_manifest` (#15) marks incompatible items, which are skipped and reported with their reason (warn items are flagged and still applied); `apply_reconcile` collapses overlapping items from different scanners (`pacman:rust` vs `mise:rust`, a launcher vs its package): same normalized name, highest provenance confidence wins, tie broken by pacman > aur > mise > uv > pipx > cargo > go > npm, launchers always lose; the loser is reported as `duplicate of ID`. Then the stages run in `APPLY_STAGES` order (design.md "Apply order"), and a summary counts `installed / present / planned / skipped / failed`. Exit 0, 1 if any item failed, 2 usage, 15 bad manifest (peer fetch errors keep their `peers` codes).

Stages. `packages`: one batched `omarchy pkg add P...` and one `omarchy pkg aur add P...` (falls back to `sudo pacman -S --needed` / yay / paru when `omarchy` is absent). With no terminal on stdin the command goes through the visible floating terminal (`omarchy-launch-floating-terminal-with-presentation`, docs/omarchy-plugins.md section 3) so sudo can prompt; afterwards each package is checked with `pacman -Qq`, so an install that did not land is `failed` whatever the exit status said. `registry`: cargo (`--locked`, `--version`), go (`module@version`), npm, uv, pipx, mise, pinned to the manifest `version` when it has one; presence is checked first (`present`), a missing manager is `skipped`. `repos`: `git-build` clones into `$STARTKIN_SRC_DIR` (default `~/.local/src`), checks out the recorded `ref` (an item with no ref is called out as unpinned) and runs the recorded build commands; `release-binary` and `appimage` download raw binaries to `dest` (default `~/.local/bin/<file>`, always inside home), verify `sha256` when recorded (without one the output says the download is unverified) and `install -Dm755`; archives are skipped; `copy` of a file that only exists on the source is fetched with `scp` from the `--from-peer` peer, otherwise skipped; `script` and `unknown` are skipped with a reason.

Safety. Every command is shown (`$ ...`) before it runs. Nothing runs without a `Run this?` confirmation (once per package batch, once per registry/repo item; end of input is no); `--yes` pre-approves all of them, so read a `--dry-run` first. Items that run downloaded code are tagged `[runs downloaded code]`: AUR, git-build, downloads, copies. `--dry-run` runs only read-only presence checks and prints the commands. Manifest values that reach a command line (names, versions, refs, URLs, sha256, paths) are validated first (URLs must be https, git URLs https/ssh/git, destinations inside home); a failing item is `skipped (invalid ... in manifest)`. Items whose category has no stage yet (plugin, config, service, launcher) are reported as skipped.

Extension points for #14. `APPLY_STAGES` is the order: add `plugins`, `config`, `services` there. A stage is a function `apply_stage_NAME ITEMS_JSON` (a JSON array of its items) that reports every item with `apply_record ID STATUS DETAIL`; `apply_stage_of CATEGORY TYPE` routes items to stages (edit its `case`); `apply_stage_title` names it. A stage built on `apply_run_items` only needs per-type planners `apply_plan_<install type>` (dashes become underscores) that set `APPLY_CMDS`, `APPLY_CODE`, `APPLY_NOTE` and return 0 (run), 10 (already present) or 11 (skip, note says why). Helpers: `apply_q`, `apply_f`, `apply_confirm`, `apply_show`, `apply_priv_exec`/`apply_priv_line` (privileged, visible terminal), `apply_path`/`apply_home_path_ok`, `apply_name_ok`/`apply_url_ok`, run state `APPLY_DRY`, `APPLY_YES`, `APPLY_PEER`, `APPLY_DRIFT`. Tests override `STARTKIN_OMARCHY` and `STARTKIN_FLOAT_CMD` so they never reach the real helper or open a terminal.

## Tests

Plain bash, no bats: bats is not installed by default on Omarchy, and a 40-line runner plus `tests/assert.sh` covers what is needed. `tests/run.sh` runs each `tests/test_*.sh`; each file defines `test_*` functions and ends with `run_tests` (from `tests/harness.sh`), which runs every function in a subshell with a fresh `$T_TMP` and a stub dir `$T_BIN` first on `PATH` (create stubs with `stub NAME 'body'`). Assertions: `assert_eq`, `assert_contains`, `assert_status CODE CMD...` (sets `$T_OUT`, `$T_ERR`), `assert_json_eq JQ EXPECTED JSON`. Run a scanner's tests by stubbing the system tools it calls.

## Peers

`startkin peers [--json] [--no-probe]` runs `tailscale status --json`, keeps Linux peers (Omarchy is Linux) and, for each online one, runs `startkin --version` over SSH to see whether it has StartKin (`startkin` is null in `--json` when it does not answer). Offline peers are never contacted. `startkin peers fetch PEER` prints that peer's `startkin scan --json` after checking the engine version (major differs: error; otherwise a difference only warns) and the manifest (`schema_version` major must be 1). SSH runs with `BatchMode=yes` and `ConnectTimeout=10`, so it never prompts and relies on Tailscale SSH. Exit codes: 10 tailscale missing/stopped, 11 unknown peer, 12 peer offline, 13 SSH auth/connection failure, 14 startkin missing or failing on the peer, 15 version mismatch or invalid manifest. A peer whose scan exits 3 (scanner failure) still yields its manifest, with a warning. Tests use fake `tailscale` and `ssh` (`STARTKIN_TAILSCALE`, `STARTKIN_SSH`, `STARTKIN_REMOTE_CMD` override the commands).

## Check and hooks

`./check` runs `bash -n`, `shellcheck` (config in `.shellcheckrc`) and `tests/run.sh` over the repo's own shell files (not `scripts/devkit`). `scripts/install-hooks` installs `.githooks/pre-commit`, which runs `./check`. Every shellcheck warning is fixed, not suppressed, unless a `disable` carries a reason.

## Devkit

`scripts/devkit` is the omarchy-plugin-devkit submodule pinned to a release tag; `devkit.conf` configures it. After cloning: `git submodule update --init`. Do not edit files inside it.

## Read-only by default: probing is opt-in

A scan never executes anything it did not ship. Tracing an unowned binary can ask it for `--version` and `--help`, but that is off unless `STARTKIN_PROBE=1` is set or `startkin scan --probe` is given. With probing on, a binary is still never run when it looks like a GUI app: it has a matching `.desktop` `Exec=` (dirs in `STARTKIN_DESKTOP_DIRS`, default the user, `/usr/share` and `/usr/local/share` applications dirs), it links `libwayland`/`libX11`/`libxcb`/`libQt*`/`libgtk`/`libSDL`/GL/Vulkan (`readelf -d`; if the libraries cannot be read the binary counts as GUI), it is an AppImage, or it lives in a Qt/Quickshell/Electron app dir. Probes run with `env -i` plus `PATH` and `HOME` only (no display or session bus), stdin from `/dev/null`, in their own session, and the whole process group is killed after 3 seconds. Without probing, binaries are traced from build metadata (`go version -m`, `strings`), symlinks, sibling files, clones and history only, so fewer versions and `--help` URLs are found.
