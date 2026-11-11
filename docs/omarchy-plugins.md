# How Omarchy plugins are installed, enabled and privileged

Research for issue #1. Every claim names the file it was read from. Paths under `/usr/share/omarchy/` are the installed `omarchy-dev` package (`pacman -Ql omarchy-dev`); `~/omarchy` is the source checkout (its `shell/` and `docs/` mirror the package). "Unverified" marks anything not read or run.

## 1. Installing a plugin

A plugin is a directory `~/.config/omarchy/plugins/<id>/` with a `manifest.json` at its root. Three install paths exist; all end in the same layout.

| Path | What happens | Source |
|---|---|---|
| `omarchy plugin add <git-url> [--enable] [--yes]` | `git clone -- <url>` into a staging dir `.add.tmp.$$`, `omarchy-plugin-validate`, refuses if the `id` is already used, `mv` to `plugins/<id>`, then `omarchy-shell shell rescanPlugins`. Alias: `omarchy plugin install` | `/usr/share/omarchy/bin/omarchy-plugin-add` |
| Manual drop | Put the folder in `plugins/<id>/`, run `omarchy-shell shell rescanPlugins`, then `omarchy plugin enable <id>` | `~/omarchy/docs/omarchy-shell.md` ("You can still install by hand") |
| Symlink or plain copy (developer installs) | The scanner uses `find -L`, so a symlinked plugin dir is discovered. Three of the ten user plugins on this machine are symlinks (`startbar`, `superwhisper-panel`, `typecraft.oma-cast`) | `/usr/share/omarchy/bin/omarchy-plugin-catalog` (`find -L "$user_dir" -mindepth 2 -maxdepth 2 -name manifest.json`); `ls -la ~/.config/omarchy/plugins/` |

Install-time facts that matter for StartKin:

- `omarchy plugin add` takes a **git URL**, not a plugin id. There is no registry lookup in the CLI (`omarchy-plugin-add` usage text; `~/.config/omarchy/plugins/io.github.bmaltais.starthome/AGENTS.md` repeats this warning). The "marketplace" is referred to in `StartDrive/CONTRIBUTING.md` and `StartDrive/tests/manifest.test.js`, but nothing in `omarchy-plugin-*` queries one (see unverified list).
- `add` is non-interactive only with `--yes` ("refusing to continue without confirmation; pass --yes"). Without `--yes` it shows a warning and a `gum confirm` (`omarchy-plugin-add`). `--yes` is described as "the path for scripts and agents" (`~/omarchy/docs/omarchy-shell.md`).
- The clone is plain `git clone`, **no `--recurse-submodules`**. A plugin with a submodule (all Start* plugins use `scripts/devkit`) installs it empty. This is harmless for them because the submodule is dev tooling (`omarchy-plugin-devkit/docs/adopting.md`, "Why a submodule"), but a plugin that needs a submodule at runtime would break.
- The clone is the repo's default branch HEAD. There is no way in `omarchy-plugin-add` to pin a tag or commit. `omarchy plugin update` is `git fetch origin HEAD` then `merge --ff-only FETCH_HEAD`, then re-validates and rolls back with `reset --hard ORIG_HEAD` on failure (`omarchy-plugin-update`). It skips any plugin dir without `.git`.
- Removal: `omarchy plugin remove <id>`. A symlink is unlinked; a git checkout is `rm -rf`'d; a non-git copy is moved to a backup `.<id>.bak.<timestamp>` inside `plugins/` (`omarchy-plugin-remove`).

## 2. Enabling a plugin

Enabled means "the id is referenced in `~/.config/omarchy/shell.json`" (`/usr/share/omarchy/shell/services/PluginRegistry.qml`, `isEnabled`, comment at lines 135-148):

- bar widgets: an entry in `bar.layout.<section>` (`left|centerBegin|center|centerEnd|tray|right`);
- everything else (services, panels, overlays, menus): an entry in the top-level `plugins[]` array;
- a full bar: `bar.id`;
- first-party (`omarchy.*`) non-bar plugins are on unless listed in `disabledPlugins[]`.

Settings for a plugin live inline on that same entry, with no separate `config` object (`~/omarchy/docs/omarchy-shell.md`, "shell.json" rule 3). Example on this machine: the `io.github.bmaltais.startbar` entry in `~/.config/omarchy/shell.json` carries `pins`, `position`, etc.

Commands (all thin wrappers over shell IPC):

- `omarchy plugin enable <id> [--section S] [--index N] [--before ID | --after ID]` calls `omarchy-shell shell enablePlugin <id> <placementJson>` and prints `ok` / `unknown` (`omarchy-plugin-enable`). Fails with "not known; run: omarchy-shell shell rescanPlugins" if the shell has not scanned it yet; `omarchy-plugin-add` polls `omarchy-plugin-list --json` up to 40x50ms for this.
- `omarchy plugin disable <id>` calls `omarchy-shell shell setPluginEnabled <id> false` (`omarchy-plugin-disable`).
- `omarchy plugin list [--json]` calls `omarchy-shell shell listPlugins` (`omarchy-plugin-list`).
- All of these need a **running shell**: `omarchy-shell` is an IPC client and fails when the shell is not running (`~/omarchy/docs/omarchy-shell.md`, intro).
- A non-bar, non-first-party plugin installed with `add` lands disabled unless `--enable` is passed (`omarchy-plugin-add`; docs: "plugins land disabled so you can review the code").
- Changes to a loaded plugin's QML need a full shell restart (`omarchy restart shell`) for a `keepLoaded` service; `manifest.json` edits need `rescanPlugins` first (`/home/bernard/StartFS/github/StartDrive/docs/omarchy-plugins.md`, table "What loads, and when"; from StartDrive's own reading of PluginRegistry, not re-run here).
- Disabling a bar-widget's icon removes only the layout entry, which also stops its **service**. StartDrive adds the id to `plugins[]` when it takes its icon off the bar to keep the service alive (`StartDrive/docs/omarchy-plugins.md`, "Enabled means listed"). Relevant if StartKin's plugin ever has a bar icon and a background service.

### `manifest.json`

Required (`omarchy-plugin-validate`, mirrored by `PluginRegistry.validateManifest`, lines 43-90):

| Field | Rule |
|---|---|
| `schemaVersion` | exactly the JSON number `1` (string `"1"` rejected) |
| `id` | `^[A-Za-z0-9][A-Za-z0-9._-]*$`, no `..`, must **not** start with `omarchy.` (reserved for first party). Convention in use: reverse-DNS, e.g. `io.github.bmaltais.startdrive` |
| `name`, `version` | must be present (no semver format check in the validator) |
| `kinds` | non-empty array. Kinds with a required entry point: `bar`->`bar`, `bar-widget`->`barWidget`, `menu`->`menu`, `overlay`->`overlay`, `panel`->`panel`, `service`->`service` |
| `entryPoints` | object; every value a relative path, no `..`, no newline, file must exist |
| (tree) | no symlinks anywhere in the folder (`.git` pruned) |

Optional keys seen in use: `author`, `license`, `description`, `homepage`, `keepLoaded`, `barWidget{displayName, description, category, aliases, allowMultiple, defaultSection, defaults, schema}` (`StartDrive/manifest.json`, `StartAppImage/manifest.json`, `~/omarchy/docs/omarchy-shell.md`). `barWidget.defaultSection` must be one of the six sections. A minimal valid service plugin is `StartBar/manifest.json` (kinds `["service"]`, `keepLoaded: true`, `entryPoints.service`).

`entryPoints` are QML `Item`s; the host injects `omarchyPath`, `shell`, `manifest` and registries on load. A StartKin plugin would most naturally be `kinds: ["service", "bar-widget"]` (or `["service"]` only), the shape used by StartDrive, StartAppImage and OmaDisplayLink (their `manifest.json` files).

## 3. Can a plugin run privileged installs?

Short answer: **yes technically, but only through the plugin's own subprocesses; the host gives it no privilege mechanism, and the working precedent is "open a visible terminal and let sudo ask".**

Evidence:

1. **No sandbox, user-level power.** Plugins run as "unsandboxed code inside `omarchy-shell`" with "the same user-level file and process access as the shell" (`~/omarchy/docs/omarchy-shell.md`, "Installing a third-party plugin"; `omarchy-plugin-add` prints the same warning). So a plugin can `Process`-spawn anything the user can, including `sudo` and `omarchy pkg add`.
2. **No host privilege API for third parties.** Omarchy's polkit agent is a first-party plugin (`omarchy.polkit`, `/usr/share/omarchy/shell/plugins/README.md`, `plugins/polkit/PolkitAgent.qml` imports `Quickshell.Services.Polkit`). Third-party plugins get capability-scoped facades; "authentication capabilities are stamped from trusted first-party manifests" and authentication services are kept out of the host's public service map (`omarchy-shell.md`; `PluginRegistry.trustedCapabilities`, lines 92-103, returns `[]` for any non-first-party manifest). A third-party plugin therefore cannot call the polkit agent or any auth service. It can only start an external process that itself requests auth (`pkexec` would hit the polkit agent as any app would; unverified, no precedent found and `grep pkexec /usr/share/omarchy/bin` finds nothing).
3. **Precedent: StartDrive.** Its only privileged step is installing `rclone fuse3`, done by `omarchy-pkg-add rclone fuse3` (`StartDrive/lib/system.sh` line 18), documented as "**sudo**, once, through Omarchy's package helper. This is the only privileged step." (`StartDrive/docs/SECURITY.md`, "What it runs"). `omarchy-pkg-add` is tagged `omarchy:requires-sudo=true` and runs `sudo pacman -S --noconfirm --needed` (`/usr/share/omarchy/bin/omarchy-pkg-add`). Interactive steps such as sign-in run in a floating terminal via `omarchy-launch-floating-terminal-with-presentation "<cmd>"` (`StartDrive/lib/drive.sh` line 140; `/usr/share/omarchy/bin/omarchy-launch-floating-terminal-with-presentation`), which wraps the command with the Omarchy logo and a Done/Failed prompt.
4. **Precedent: OmaDisplayLink.** Rule in its `AGENTS.md`: "System files ... are installed by scripts with `sudo` in a visible terminal." `scripts/lib.sh` `need_sudo` checks `sudo -n true` and otherwise tells the user "This step needs sudo in a visible terminal"; `bin/omadisplaylink` line 350 launches `omarchy-launch-floating-terminal-with-presentation`. Its README: "Where a step needs administrator rights, the terminal asks for your password." (all under `~/.config/omarchy/plugins/io.github.bmaltais.omadisplaylink/`). Its AGENTS.md also prefers `omarchy pkg add` and `omarchy pkg aur add` over raw pacman/yay.
5. **Omarchy's own non-interactive escape hatch exists but is not for plugins.** `omarchy-sudo-passwordless` publishes a timed/permanent sudoers grant for a UID, with the user authenticating (`~/omarchy/docs/passwordless-sudo.md`). Silently depending on it, or enabling it from a plugin, would be a privilege escalation the user did not ask for; do not design around it. `omarchy-sudo-keepalive` also exists in `/usr/share/omarchy/bin` (contents not read; unverified what it does).
6. **StartAppImage and StartBar** need no privilege at all: grep for `sudo|pkexec|polkit` finds only dev/CI notes and an error message telling the user to run `sudo pacman -S --needed squashfs-tools` themselves (`StartAppImage/bin/startappimage` line 46, `StartAppImage/README.md` line 29).

Implication for StartKin's apply step (packages first, per `docs/design.md`): run `omarchy pkg add <pkgs...>` / `omarchy pkg aur add` in a floating terminal through `omarchy-launch-floating-terminal-with-presentation` so the password prompt, pacman output and failures are visible. Batch all repo packages into one `pkg add` call to keep it to one prompt. AUR builds run as the user and sudo only at install, but the build is arbitrary code; show it (not verified how `omarchy-pkg-aur-add` invokes the helper; script exists, not read). Do not try to run sudo from a headless `Process` inside the shell: without a TTY sudo fails unless a passwordless grant exists, and the host provides no askpass for plugins (inference from items 1-2, not tested).

## 4. Where an installed plugin's source URL and version can be read

| Datum | Where | Notes |
|---|---|---|
| Version | `<plugin>/manifest.json` `.version` (required field) | e.g. StartDrive `1.0.5`, StartAppImage `1.0.6`, mouse `1.2.0`. Free-form string, no enforced semver |
| Source URL, git installs | `git -C <plugin> remote get-url origin` (or `.git/config` `[remote "origin"] url`) | Read on this machine: `io.github.wouldja.mouse` -> `https://github.com/wouldja/omarchy-mouse.git`; `startappimage` -> `https://github.com/bmaltais/StartAppImage.git`; `starthome` -> `https://github.com/bmaltais/StartHome` (note: no `.git` suffix; both forms occur). Files: each plugin's `.git/config` under `~/.config/omarchy/plugins/` |
| Exact revision | `git -C <plugin> rev-parse HEAD`, plus branch from `.git/config` | `omarchy-plugin-update` relies on `origin` HEAD, so the branch is the remote default. Local config can show extra tracking branches (StartAppImage has `app-settings-window`, `release-1.0.1`), so the checked-out branch is not necessarily the default |
| Source URL, fallback | `manifest.json` `.homepage` (optional) | StartDrive, StartBar, StartAppImage, OmaDisplayLink set it; `io.github.wouldja.mouse` does not. It is a project page, not guaranteed clonable |
| Not available | `omarchy-shell shell listPlugins` / `omarchy plugin list --json` | Output keys are only `active, canDisable, clonedFrom, enabled, firstParty, id, kinds, name` (ran `omarchy-shell shell listPlugins`). **No version, no URL, no path.** `omarchy-plugin-catalog` (hidden command) does add `manifestPath` and `sourceDir`, still no version or URL, but is the right way to enumerate dirs |
| Not available | `shell.json` | Holds only enabled ids and settings (`~/.config/omarchy/shell.json`); no source record |
| Not available | any Omarchy install ledger | `omarchy-plugin-add` writes nothing besides the clone; unverified that no other state exists elsewhere (searched `omarchy-plugin-*` only) |

Install-form classification, derivable on disk (this is the `plugin` install descriptor from `docs/design.md`):

| Form | Detect | Reproducible by `omarchy plugin add`? |
|---|---|---|
| git clone | `<dir>/.git` present, `origin` URL | Yes, using the origin URL. Record the commit for pinning; `add` cannot pin, so the apply step would `git checkout <rev>` after, which deviates from stock `omarchy plugin update` semantics (it ff-merges the default branch) |
| symlink | `<dir>` is a symlink (`readlink`) | No. Target is a developer checkout (e.g. `startbar` -> `/home/bernard/github/StartBar`, `typecraft.oma-cast` -> `.../oma-cast/plugin`). If the target is itself a git repo, resolve the repo root and read its origin; for `superwhisper-panel` the target is `/opt/superwhisper/assets/omarchy-plugin/...`, which belongs to a package (`pacman -Qo` would say; not run). Treat as `unknown`/package-owned |
| plain copy | no `.git`, not a symlink | Only if `homepage` gives a clonable URL; otherwise `copy`. StartDrive is installed this way on this machine (no `.git`; confirmed by `StartDrive/docs/omarchy-plugins.md`, "Installed copy versus clone", and a failed read of `.../startdrive/.git/config`) |
| cloned built-in | `manifest.omarchy.clonedFrom` set (id has the form `<user>.<name>`) | Not reproducible by add; it is `omarchy plugin clone` of a built-in plus edits (`omarchy-plugin-clone`) |

Per-plugin settings are in `shell.json`, not in the plugin dir, so a "plugin" item should carry the id's `plugins[]` / `bar.layout` entry too if settings are to travel. Those entries can hold machine-specific values (StartBar's `recentApps`, `pins`; `elsewhen` zones), so they should go through the same "no config contents by default" rule as other config (`docs/design.md`, AI boundary). The plugin directory itself can also hold state: unverified for each plugin; StartDrive keeps its state outside, in `~/.config/startdrive/` (`StartDrive/docs/SECURITY.md`, "Files it touches").

## 5. Consequences for the StartKin design

1. **Scanner (M1).** Enumerate `plugins/*/` (follow symlinks like the catalog does), read `manifest.json` (`id`, `version`, `homepage`), classify the form above, read `origin` and `HEAD` for git installs. Skip dot-directories (`.add.tmp.*`, `.clone.*`, `.<id>.bak.*` are ignored by the catalog's `! -path "$user_dir/.*/*"`, so the scanner must do the same). Detect enabled state from `shell.json` (id in `plugins[]` or any `bar.layout.*`), since `listPlugins` needs a live shell and omits URLs.
2. **Apply, plugin step.** `omarchy plugin add <url> --yes [--enable]`; it needs the shell running and `rescanPlugins` is done by `add`. Because `add` clones HEAD with no ref, a revision pin is a second step (and `omarchy plugin update` will later undo it).
3. **Trust.** `omarchy plugin add` warns that plugins are unsandboxed arbitrary code. A peer's manifest asking StartKin to install plugin URLs is therefore a remote-code-execution vector on the receiving machine. StartKin should show every plugin URL and require explicit confirmation per plugin, never pass `--yes` blindly. This also feeds the "community release" question in `docs/design.md`.
4. **Privilege.** StartKin's plugin cannot get privilege from the host. Use the StartDrive/OmaDisplayLink pattern (visible floating terminal, `omarchy pkg add`).
5. **Own manifest.** Use `id` `io.github.bmaltais.startkin` (not `omarchy.*`), `kinds: ["service"]` plus optional `bar-widget`, `keepLoaded: true`, `homepage`, and run `omarchy plugin validate .` plus a no-symlinks check before release (`StartDrive/CONTRIBUTING.md`, release paragraph). Avoid depending on a submodule at runtime.

## Unverified

- Whether a marketplace or catalog service exists that resolves plugin ids to URLs. `StartDrive/CONTRIBUTING.md` and `tests/manifest.test.js` mention "the Omarchy plugin marketplace's rules", but no installed `omarchy-plugin-*` command fetches from one, and no URL was visited.
- Whether `pkexec` works from a plugin subprocess under the Omarchy polkit agent. No plugin uses it.
- Whether sudo can prompt usefully without a terminal from a plugin `Process` (inferred it cannot).
- What `omarchy-sudo-keepalive` and `omarchy-pkg-aur-add` do exactly (not read).
- Whether any plugin keeps state inside its own folder that a faithful reinstall would lose (not audited for any plugin except via StartDrive's SECURITY.md).
- Behaviour on a machine whose `omarchy` version differs from this one (everything above was read from the `omarchy-dev` package installed here; `~/omarchy` was not diffed against it beyond the passages cited).
- I did not run `omarchy plugin add` against anything; the install flow is read from the script, not exercised.
