# StartKin design (draft)

## What is detected
Everything added after the Omarchy install, by diffing against a baseline for the machine's own Omarchy version.

| Category | Source |
|---|---|
| Packages | `pacman -Qe` minus Omarchy's own set; `pacman -Qem` for AUR/foreign |
| Registry-backed tools | cargo, uv, pipx, npm, mise, go |
| Omarchy plugins | `~/.config/omarchy/plugins/<id>/` |
| Tools from repos | git clones under configured roots; binaries in `~/.local/bin`, `/usr/local/bin`, `~/.local/share` |
| Config | `~/.config/**` diffed against the shipped defaults (`/etc/skel`) |
| Services | enabled systemd units minus baseline |
| Webapps / launchers | `~/.local/share/applications` |

## Install descriptor
Each item carries how to reproduce it: `pacman`, `aur`, `cargo`, `go`, `npm`, `uv`, `pipx`, `mise`, `plugin`, `git-build`, `release-binary`, `appimage`, `script`, `copy`, `unknown`.

## Provenance for untracked binaries
Order: registry lookup, embedded build metadata (`go version -m`, `strings`), `--version`/`--help` (opt-in, `scan --probe`; never for GUI apps), adjacent evidence (git clone, symlink target, shell history), name search with user confirmation, fallback `copy`. Untraced items go through an "adopt" wizard once; the answer is stored.

## Tags and profiles
Items carry `category`, `kind`, `risk` tags. A profile is a tag query plus user overrides, saved as a small file. Tags come from rules first, AI second, manual override always wins; results are cached per manifest.

## AI boundary
AI classifies, groups, explains and flags target mismatches. It only handles items present in the manifest (output validated), never sees config file contents by default, and never runs commands. Local or cloud is a setting.

## Transport
`tailscale status --json` for peers; manifest fetched over SSH (Tailscale SSH). Saved manifests (snapshots) are supported alongside live peers: see Saved snapshots.

## Saved snapshots
Decided (#11): yes. A snapshot is just a manifest in a file, written by `startkin export --out FILE` (mode 600, replaced atomically). Cost is small because the manifest format is already the transport format: apply and peers fetch read the same JSON whether it came from a live peer or a file. `startkin export --from FILE` re-exports a snapshot after checking it is a manifest and running the same secrets gate, so a hand-edited or old file cannot smuggle a secret out. Snapshots hold no secrets by policy (`docs/secrets-policy.md`), but they still describe the whole machine (installed software, paths, hostname): keep them in a private repo, never a public one. A snapshot is stale the moment it is written; apply (#13/#14) must show its `generated_at` and `machine.omarchy_version` and compare them to the target (#15, #29).

## Apply order
Packages, then tools from repos, then plugins, then config, then services. Config applies per item with diff preview and backup (content is fetched from the peer at apply time; `startkin rollback` undoes a run; see docs/engine.md "Apply").

## Open questions
- ~~Online peer only, or also saved manifests?~~ Both: see Saved snapshots.
- Local vs cloud AI default.
- ~~Can a plugin run privileged installs (polkit/sudo)?~~ Answered in `docs/omarchy-plugins.md`: the host gives third-party plugins no privilege API (polkit is first-party only). Precedent (StartDrive, OmaDisplayLink) is `omarchy pkg add` inside a visible floating terminal (`omarchy-launch-floating-terminal-with-presentation`) so sudo prompts the user. Apply does the same; never `--yes` plugin installs blindly. Untested: `pkexec` from a plugin.
- ~~Where is a plugin's source URL and version?~~ Answered in `docs/omarchy-plugins.md`: version in `manifest.json`, URL from the checkout's `origin` remote (git installs) or `homepage` (fallback); `listPlugins` exposes neither. Symlinked and copied installs are not reproducible by `omarchy plugin add`.
- Personal use only, or Omarchy community release (raises the bar on secrets and baseline compatibility).
