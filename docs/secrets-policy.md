# Secrets and sensitive data policy

What StartKin never exports or applies by default, and the checks that enforce it. Code: `lib/secrets.sh`, `scripts/check-manifest-secrets`. Tests: `tests/test_secrets.sh`, `tests/test_check_manifest_secrets.sh` (synthetic fake secrets only, assembled at run time).

## Rules

1. Secret categories (`ssh-key`, `gnupg`, `keyring`, `token`, `credentials`, `shell-history`, `browser-profile`) are never exported or applied. There is no override. A user who wants such a file on another machine moves it by hand.
2. `hardware` is machine-specific, not secret. It is skipped by default; a caller may lift it for a same-hardware target with `STARTKIN_SECRETS_ALLOW_HARDWARE=1`. No other category is affected by that variable.
3. Shell history is never exported as contents. It may be read locally as provenance evidence (`design.md`), but only the derived fact ("seen installing X") goes in a manifest, never the command lines.
4. A manifest must contain no secret pattern anywhere, evidence strings included. `scripts/check-manifest-secrets` runs before any export and in `./check` over the example manifests.
5. Nothing prints a matched secret: not stdout, stderr, logs, nor error messages. Findings are a kind plus a line number.
6. The scanners are a safety net, not a guarantee. Patterns miss things; the path policy and "never put file contents in a manifest" (`manifest.md`: evidence is never secrets or file contents) are the primary defence.

## Path categories

`secrets_path_denied` globs, first match wins (`*` crosses `/`). Home paths are matched with a leading `*/`, so `~/`, `$HOME` and relative paths all work.

| Category | Examples |
|---|---|
| `keyring` | `~/.local/share/keyrings/*`, `~/.password-store/*`, `*.kdbx`, kwallet, Bitwarden, 1Password |
| `gnupg` | `~/.gnupg/*`, `*.gpg`, `*.kbx` |
| `ssh-key` | `~/.ssh/*`, `id_rsa`/`id_ed25519`/..., `*.pem`, `*.key`, `*.ppk`, `*.p12`, `*.pfx` |
| `token` | `~/.config/gh/hosts.yml`, `.npmrc`, `.pypirc`, `.netrc`, `.git-credentials`, `.docker/config.json`, `.cargo/credentials*`, `.env`, `.env.*`, rclone, 1Password CLI, Tailscale state |
| `credentials` | `~/.aws/*`, `~/.azure/*`, gcloud, `~/.kube/config`, `credentials`, `client_secret*.json`, NetworkManager `system-connections/*` (Wi-Fi keys), `/etc/wireguard/*`, `/etc/shadow` |
| `shell-history` | `*_history`, `.histfile`, `.lesshst`, `.viminfo`, atuin, mcfly, zsh sessions |
| `browser-profile` | Firefox/LibreWolf/Zen, Chrome/Chromium, Brave, Vivaldi, Edge, Opera profiles |
| `hardware` | `hypr/monitors.conf`, kanshi, `/etc/fstab`, `/etc/crypttab`, `/etc/machine-id`, `/etc/hostname`, xorg.conf, udev rules, modprobe.d, `/var/lib/bluetooth/*` |

Allowlist (checked first, matched against the path itself): `*.pub`, `*.example`, `*.sample`, `*.template`, `~/.ssh/config`, `~/.gnupg/gpg.conf`, `gpg-agent.conf`, `dirmngr.conf`. These hold no private material. Anything else under a denied directory stays denied.

## Content patterns

Kinds returned by the scanner:

| Kind | Matches |
|---|---|
| `private-key` | `-----BEGIN ... PRIVATE KEY-----` (RSA, EC, OPENSSH, PGP BLOCK, ...) |
| `github-token` | `ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_` + 30 or more alphanumerics; `github_pat_...` |
| `api-key` | `sk-` + 20 or more key characters (OpenAI, Anthropic style); Google `AIza...` |
| `aws-access-key` | `AKIA`/`ASIA` + 16 uppercase alphanumerics |
| `slack-token` | `xox[abeoprs]-...` |
| `jwt` | three dot-separated base64url parts starting `eyJ` |
| `credential-url` | `scheme://user:pass@host` |
| `secret-assignment` | a key ending in `password`, `passwd`, `passphrase`, `secret`, `token`, `api_key`, `access_key`, `private_key` followed by `=` or `:` and a real value. Skipped: values under 6 chars, numeric, empty, `$VAR`/`$(cmd)`/`${..}` references, `<..>`/`{..}` placeholders, paths, anything containing `redacted`, and words like `none`, `true`, `bearer`. `max_tokens`, `token_type`, `password_file` do not match. |
| `high-entropy` | any `key = value` whose value is 20 or more key characters, mixes letters and digits, is not pure hex (hashes, `sha256` fields), is not a path, and has at least 3.8 bits per character of Shannon entropy |

Known gaps: multi-line secrets other than the PEM header line, secrets in binary files, short passwords, and values without a recognisable key name or prefix.

## Interface (`lib/secrets.sh`)

Source it; it defines functions and tables only, needs bash and awk, no `lib/common.sh`. Matched text never leaves the library.

```
secrets_path_denied PATH
```
Prints the category and returns 0 if PATH is denied by default. Prints nothing and returns 1 if allowed. Returns 2 on bad usage. PATH need not exist.

```
secrets_scan_text          # reads stdin
secrets_scan_file FILE
```
Print one `KIND<TAB>LINE` per finding (1-based line, kinds listed above, in a stable order within a line). Return 0 if clean, 1 if there were findings, 2 for an unreadable or missing FILE. Findings are never accompanied by the matched text, so output is safe to log and to show in a UI.

```
scripts/check-manifest-secrets MANIFEST
```
Runs `secrets_scan_file` over the whole manifest file, and `secrets_path_denied` over the `path` of every `copy` install descriptor. Prints `file:line: secret pattern (kind)` or `file: copy item path is denied ... (category): path` to stderr. Exit 0 clean, 1 findings, 2 usage, missing file or invalid JSON.

### For the config-diff scanner (#8)

Before including a config file in a manifest or diff:

1. `if cat=$(secrets_path_denied "$path")` then drop the file and record at most the category (as evidence like `skipped: shell-history`), never the content.
2. For files that pass, run `secrets_scan_file "$file"`. On return 1, do not embed any content from it; either emit the item with `private: true` and no content, or skip it. Use the kinds and line numbers only for a warning (`warn "$path: github-token at line 12"`).
3. Run each content snippet you do plan to embed through `secrets_scan_text <<<"$snippet"` too, since a diff hunk can be clean per file yet carry a secret.
4. Apply must use the same check on the target path before writing.

Extend the policy by adding an entry to `_SECRETS_PATH_DENY` (`category:glob`) or `_SECRETS_PATH_ALLOW`, or a kind and ERE to `_SECRETS_KINDS`/`_SECRETS_RES`, plus a test with a synthetic secret.
