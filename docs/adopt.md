# Adopt and tracked installs

Items the scanners could not trace (`provenance.method` `none`, install `unknown`) or only guessed (`confidence` below 0.9, e.g. name-search "needs confirmation") are confirmed once by the user. The answer is stored in a registry file and overlaid on every later scan, so the item is not asked about again. Code: `lib/registry.sh`, `lib/adopt.sh`, `lib/track.sh`, `lib/ui.sh`. Tests: `tests/test_registry.sh`, `test_adopt.sh`, `test_track.sh`, and `test_scan_overlays_registry` in `test_cli.sh`.

## Registry file

Default `${XDG_CONFIG_HOME:-~/.config}/startkin/registry.json`; `STARTKIN_REGISTRY_FILE` overrides it. Plain JSON, safe to keep in a dotfiles repo: entries are checked with `lib/secrets.sh` before writing (a secret pattern or a denied `copy` path refuses the write, kinds only in the message) and URL credentials are dropped.

```json
{
  "schema_version": "1.0",
  "entries": {
    "repo-tool:mytool": {
      "origin": "adopt",
      "install": {"type": "git-build", "url": "https://github.com/o/mytool", "ref": "v1", "build": ["make"]},
      "version": null,
      "recorded_at": "2026-11-11T10:00:00Z"
    }
  }
}
```

| Field | Notes |
|---|---|
| `entries` | Object keyed by manifest item `id` (scanner ids such as `repo-tool:NAME`, `cargo:NAME`). Tracked installs use `<method>:<name>`, or `track:git-build:<repo>`; `--id` overrides. |
| `origin` | `adopt` (user answered the wizard) or `track` (recorded by `startkin track install`). |
| `install` | An install descriptor exactly as in `docs/manifest.md`. |
| `version` | String or `null`. |
| `recorded_at` | UTC timestamp. |

A missing file is an empty registry. An unreadable one is never overwritten: scans warn and continue without it.

## Overlay

`scan_collect` (`lib/scan.sh`) pipes the merged scanner output through `registry_overlay`. An item whose `id` has an entry gets the entry's `install`, its `version` (the scanned one if the entry has none) and `provenance {method: "user", confidence: 1, evidence: ["confirmed by user (adopt) on DATE"]}`. Other items are untouched. `startkin adopt` reads the scanners without the overlay when it looks up the item to adopt, so `--copy` and `--confirm` still see the scanner's own path and guess.

## `startkin adopt`

```
startkin adopt --list [--json] [--all]  items needing confirmation (method none, or confidence < 0.9, after the overlay)
startkin adopt [--all]                walk through them interactively
startkin adopt ITEM_ID --git URL [--ref REF] [--build CMD]...
startkin adopt ITEM_ID --go MODULE | --cargo CRATE | --release URL [--sha256 HEX] | --script URL
startkin adopt ITEM_ID --copy         copy the local file (its path comes from the scan)
startkin adopt ITEM_ID --confirm      accept the scanner's guess as it is
```

By default the list leaves out items a package manager already vouches for (`package-manager` or `registry` method, e.g. an AUR package at 0.8): what is left is mostly untraced repo tools and heuristic guesses (name search, history, launchers, services). `--all` includes them. Interactive mode uses `gum` when it is installed and stdin/stdout are a terminal, plain `read` prompts otherwise (`STARTKIN_NO_GUM=1` forces plain). Prompts go to stderr. End of input stops the walk; already-recorded answers stay. Exit codes: 0 ok, 1 failed (unknown item, nothing to confirm, secret refused), 2 bad usage or value.

## `startkin track install`

```
startkin track install METHOD SPEC [--dry-run] [--yes] [--id ITEM_ID]
  cargo CRATE[@VER]      cargo install --locked
  go MODULE[@VER]        go install MODULE@VER (default latest)
  npm PKG[@VER]          npm install -g
  uv PKG[==VER]          uv tool install
  pipx PKG[==VER]        pipx install
  git-build URL --build CMD [--build CMD]... [--ref REF]
                         clone (or fetch) into ${STARTKIN_SRC_DIR:-~/.local/src}/<repo>, check out REF, run each CMD there
```

It prints the exact commands and what it will record, then asks `Run this? [y/N]` unless `--yes`. `--dry-run` stops after printing. If any command fails nothing is recorded. On success the registry gets the install descriptor, the version (from the spec, `cargo install --list` or the clone's HEAD), the method (the descriptor type), and the date. `pacman`/`aur` are refused: system packages go through `omarchy pkg add` (`docs/omarchy-plugins.md`). A tracked entry only changes a scan when its id matches a scanned item.
