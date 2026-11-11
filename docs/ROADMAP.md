# StartKin roadmap and status

Source of truth for scope is the GitHub issues and milestones; this file records the path to completion and where the build stands. Update it when a ticket merges.

## Milestones and tickets
| Milestone | Tickets |
|---|---|
| M1 Scanner | #1 plugin research, #2 manifest schema, #3 engine scaffold, #4 packages, #5 registry tools, #6 plugins, #7 provenance (untracked binaries, git clones), #8 config diff, #9 services/launchers, #10 adopt wizard, #28 secrets policy |
| M2 Transport and apply | #11 export/snapshots, #12 Tailscale peers + fetch, #13 apply packages/tools, #14 apply plugins/config/services with backup+rollback, #15 target-awareness, #29 Omarchy version drift |
| M3 Profiles and tags | #16 tagging rules + profile format, #17 custom profiles, #18 dependency preview |
| M4 Plugin UI | #19 plugin scaffold, #20 peer list, #21 profile picker + checklist, #22 apply progress/diff/rollback, #23 bar widget + settings |
| M5 AI assist | #24 AI tagging, #25 explanations/suggestions, #26 provenance proposals, #27 local vs cloud + privacy |

## Dependencies
- #2, #3 are roots (done). #4, #5, #6, #7, #9, #28 need #2 + #3. #6 also used #1.
- #8 needs #28 (`lib/secrets.sh`). #10 needs #7.
- M2 needs the M1 manifest and scanners. #13/#14 use `omarchy pkg add` in a floating terminal (see docs/omarchy-plugins.md).
- M3 tags the items scanners emit. M4 is a thin front-end over the CLI's JSON. M5 is optional and layered on top.

## Status (update below)
Integration branch: `integration/m1-scanner`, draft PR #30 (closes the M1 tickets).

Merged into the integration branch: #1, #2, #3, #4, #5, #6, #9.
In progress at last update: #7, #28. Blocked: #8 (on #28), #10 (on #7).
After all M1 tickets merge: run `code-review` on the integration branch, fix findings in one pass, mark PR #30 ready, clean up worktrees, then start M2.

## Decisions
- Engine is bash + jq; scanners are `lib/scan/<name>.sh` defining `scan_<name>` (docs/engine.md).
- Plugin front-end is `io.github.bmaltais.startkin`; engine stays headless (docs/design.md).
- AI only proposes tags/explanations as data and never runs commands.
- Privileged installs go through `omarchy pkg add` in a visible floating terminal; plugins have no privilege API (docs/omarchy-plugins.md).

## Known follow-ups
- Package scanner emits system leftovers (`linux`, `intel-ucode`, `mkinitcpio`...) and only `library`/`other` kinds: fix in M3 tagging.
- Overlap between scanners (`pacman:rust` vs `mise:rust`, `uv`, launchers vs packages): reconcile in apply/export (#11, #13).
- libvirt sockets should group into one item; app-generated launchers (Docker, claude-code-url-handler) are noise.
- `omadisplaylink` plugin origin is a local path, not cloneable elsewhere.
- Schema validator needs `uvx`, `check-jsonschema` or python `jsonschema`; first uvx run needs network.
- Creating several agent worktrees at once can race; launch them in smaller batches.
