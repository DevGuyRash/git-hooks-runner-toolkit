# watch-configured-actions example

## Overview

`watch-configured-actions.sh` is a `post-merge` helper that inspects files
changed by a merge/rewrite/checkout/commit and runs custom commands described in
a YAML or JSON configuration file. A companion,
`watch-configured-actions-pre-commit.sh`, enforces the same rules against staged
changes before the commit is created.

## Stage It

```bash
.githooks/install.sh stage add examples --name 'watch-configured-actions'
```

Stage the pre-commit variant when you want feedback before a commit:

```bash
.githooks/install.sh stage add examples --hook pre-commit --name 'watch-configured-actions-pre-commit'
```

Either command also copies the shared configuration asset into the hooks-root
`config/` directory (e.g. `.githooks/config/watch-configured-actions.yml` for
persistent installs or `.git/.githooks/config/watch-configured-actions.yml` for
ephemeral mode) so both hooks read the same centralized rules. If staging spots
a legacy `.githooks/watch-config*.{yml,yaml,json}` file it emits a migration
warning before continuing with the copy.

The scripts advertise their primary hook via metadata. You can copy them to
other hooks if needed; each reads the current hook name from
`$GITHOOKS_HOOK_NAME`.

## Provide a Configuration File

On each run the hooks search for configuration in the following order:

1. `GITHOOKS_WATCH_CONFIG` (environment variable; accepts absolute or
   repository-relative paths).
2. The centralized hooks-root config directory staged above:
   - Persistent installs copy to `.githooks/config/watch-configured-actions.yml`.
   - Ephemeral installs copy to `.git/.githooks/config/watch-configured-actions.yml`.
   - Alternate filenames `watch-configured-actions.yaml` and
     `watch-configured-actions.json` are detected automatically.
3. Legacy repository paths under `.githooks/` (for example,
   `.githooks/watch-configured-actions.yml`). Selecting these continues to work
   but emits a warning encouraging migration to the `config/` directory.
4. Inline definitions supplied through `WATCH_INLINE_RULES` or
   `WATCH_INLINE_RULES_DEFAULT`.

If no file is found and no inline rules are supplied, the hooks report "no rules
configured" and exit successfully.

### YAML Schema

```yaml
- name: docs build
  patterns: ["docs/**/*.md", "docs/**/*.yaml"]
  commands:
    - "./scripts/build-docs"
  continue_on_error: false
- name: lint configs
  patterns: ["*.json"]
  commands:
    - "npm run lint-configs"
```

Each entry is an object with:

- `name` *(string)* — label used in logs and mark files.
- `patterns` *(array of globs)* — matches changed paths; supports `*`, `?`, and
  `**`.
- `commands` *(array of shell snippets)* — executed sequentially when a rule
  matches. If omitted, the match is logged but nothing runs.
- `continue_on_error` *(boolean, optional)* — continue to subsequent commands on
  failure while recording the exit code.

The JSON schema mirrors the YAML structure.

### JSON Schema

```json
[
  {
    "name": "docs build",
    "patterns": ["docs/**/*.md", "docs/**/*.yaml"],
    "commands": ["./scripts/build-docs"],
    "continue_on_error": false
  },
  {
    "name": "lint configs",
    "patterns": ["*.json"],
    "commands": ["npm run lint-configs"]
  }
]
```

### Inline Rules

Set `WATCH_INLINE_RULES` (or `WATCH_INLINE_RULES_DEFAULT`) to define rules
without a file. Blocks are separated by blank lines:

```bash
name=docs build
patterns=docs/**/*.md,docs/**/*.yaml
commands=./scripts/build-docs

name=lint configs
patterns=*.json
commands=npm run lint-configs
continue_on_error=true
```

## Optional Environment Variables

- `GITHOOKS_WATCH_DEBUG=1` — verbose logging of rule parsing and matches.
- `GITHOOKS_WATCH_MARK_FILE=path` — records the hook name, triggers, and changed
  paths to `path` (relative paths live under the repo root).
- `GITHOOKS_WATCH_PRESERVE_TMP=1` — retain temporary files for inspection.

## Runtime Hints and Warnings

- Missing config files trigger an info-level hint pointing at the centralized
  `config/` location and the hook exits 0 so you can wire in the sample YAML.
- Using legacy `.githooks/watch-config*.{yml,yaml,json}` paths logs a warning
  recommending migration while still loading the rules.
- YAML/JSON parse failures raise an error naming the offending file and direct
  you back to this guide.
- Permission or sandbox errors when reading config bubble up with the failing
  path and suggest confirming whether the install is persistent or ephemeral.

## Requirements

- Git must be available (used to collect changed paths).
- [`yq`](https://mikefarah.gitbook.io/yq/) for YAML configs, [`jq`](https://stedolan.github.io/jq/) for JSON.
- Rules that run commands rely on those commands being available on `PATH`.
