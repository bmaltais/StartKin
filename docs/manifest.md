# Manifest

The JSON document the engine emits: machine info plus the items found after the Omarchy baseline (see `design.md`).

- Schema: `schema/manifest.schema.json` (JSON Schema 2020-12)
- Examples: `schema/examples/` (`valid-*.json` must pass, `invalid-*.json` must fail)
- Validate: `scripts/validate-manifest <file>` (exit 0 valid, 1 invalid, 2 usage/tooling error)
- Tests: `schema/test.sh`

## Validator backend

First available wins: `check-jsonschema` on PATH, then `uvx check-jsonschema` (uv is installed here; the first run downloads it), then `python3` with the `jsonschema` module. On this machine only `uvx` is present, so the first run needs network.

## Versioning

`schema_version` is a `"major.minor"` string. This schema accepts `1.x`. Minor bumps add optional things only; a breaking change bumps the major and ships a new schema file. Consumers should reject a major they do not know. All objects are closed (`additionalProperties: false`), so unknown fields fail validation: add fields by bumping the schema.

## Top level

| Field | Required | Notes |
|---|---|---|
| `schema_version` | yes | `"1.0"` |
| `generated_at` | no | RFC 3339 date-time |
| `machine` | yes | see below |
| `items` | yes | array of items, may be empty |

## machine

All required: `hostname`, `omarchy_version`, `arch` (e.g. `x86_64`), `gpu` (array of strings, empty if none), `form_factor` (`desktop|laptop|server|vm|other`).

## item

All required.

| Field | Values |
|---|---|
| `id` | no whitespace, unique within the manifest (not enforceable by the schema), e.g. `pacman:ripgrep` |
| `name` | display name |
| `kind` | `cli gui-app library runtime plugin script config service launcher other` |
| `category` | detection source: `package registry-tool plugin repo-tool config service launcher` |
| `risk` | `low medium high` |
| `install` | descriptor, below |
| `version` | string, or `null` if unknown |
| `provenance` | `{method, confidence, evidence}` |
| `private` | boolean; `true` means the item must not leave the machine without the user opting in |

### provenance

- `method`: `package-manager registry build-metadata version-flag adjacent-evidence shell-history name-search user fallback none`
- `confidence`: number from 0 to 1
- `evidence`: array of short strings (commands run, paths seen). Never secrets or file contents.

### install descriptor

Discriminated on `type`; each variant is closed and has its own fields (required in bold).

| type | fields |
|---|---|
| `pacman` | **package**, repo |
| `aur` | **package**, helper |
| `cargo` | **crate**, locked |
| `go` | **module** |
| `npm` | **package** |
| `uv` | **package** |
| `pipx` | **package** |
| `mise` | **tool**, backend |
| `plugin` | **plugin_id**, source (URL) |
| `git-build` | **url**, ref, build (array of commands) |
| `release-binary` | **url**, sha256, dest |
| `appimage` | **url**, sha256, dest |
| `script` | **url** or **path** (at least one), interpreter |
| `copy` | **path**, dest |
| `unknown` | path, hint |

## Rules the schema cannot express

- `id` uniqueness within a manifest.
- Whether `category` and `install.type` are consistent for an item.
- Examples and real manifests must not carry secrets; `private: true` items should be redacted before leaving the machine.
