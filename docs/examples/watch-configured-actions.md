# watch-configured-actions example

## Overview

`watch-configured-actions.sh` is a `post-merge` helper that inspects files
changed by a merge/rewrite/checkout/commit and runs custom commands described in
a YAML or JSON configuration file.

## Stage It

```bash
.githooks/install.sh stage add examples --name 'watch-configured-actions'
```

The script advertises the `post-merge` hook via metadata. You can also copy it
to other hooks if needed; it reads the current hook name from
`$GITHOOKS_HOOK_NAME`.

## Provide a Configuration File

On each run the script searches for, in order:

1. `GITHOOKS_WATCH_CONFIG` (environment variable)
2. `.githooks/watch-config.yml`
3. `.githooks/watch-config.yaml`
4. `.githooks/watch-config.json`

If no file is found and no inline rules are supplied, it reports
"no rules configured" and exits successfully.

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

### Inline Rules

Set `WATCH_INLINE_RULES` (or `WATCH_INLINE_RULES_DEFAULT`) to define rules
without a file. Blocks are separated by blank lines:

```
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

## Requirements

- Git must be available (used to collect changed paths).
- [`yq`](https://mikefarah.gitbook.io/yq/) for YAML configs, [`jq`](https://stedolan.github.io/jq/) for JSON.
- Rules that run commands rely on those commands being available on `PATH`.
