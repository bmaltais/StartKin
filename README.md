# StartKin

Set up a new [Omarchy](https://omarchy.org) machine by picking pieces from another one.

StartKin finds the Omarchy machines on your Tailscale network, shows what each one has added since its Omarchy install (packages, tools installed from repos, plugins, config, services), and lets you cherry-pick what to install on this machine. Pick a profile (Minimal, Desktop, Development, Full, or your own) as a starting point, then add or remove items.

**Status: design stage.** Nothing is built yet. The work is tracked in the issues; the design is in [docs/design.md](docs/design.md).

## Shape

- **Engine**: a headless CLI that scans, diffs, exports and applies. Runs on the reference machine over SSH, and is the source of truth.
- **Plugin**: an Omarchy shell plugin (`io.github.bmaltais.startkin`) that is a thin front-end over the engine's JSON.

## Principles

- Detection and apply are deterministic. AI only proposes tags and explanations as data; it never runs commands.
- Every apply step is previewed, backed up and confirmed by the user.
- Secrets and machine-specific data are excluded or flagged by default.

MIT licensed.
