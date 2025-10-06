# dependency-sync example

## Overview

`dependency-sync.sh` watches for dependency manifest changes after merges,
rewrites, checkouts, or commits. When it detects updated lockfiles it invokes
the corresponding package manager so dependencies stay in sync.

## Stage It

```bash
.githooks/install.sh stage add examples --name 'dependency-sync'
```

The script declares `post-merge`, `post-rewrite`, `post-checkout`, and
`post-commit` in its `# githooks-stage` metadata, so staging once wires it into
all four hooks automatically.

## What It Detects

For each run the script compares the previous and current revisions:

- Node (npm / yarn / pnpm / bun) lockfiles
- Composer, Pip (requirements.txt), Poetry, Pipenv, uv, and Ruby Bundler
- Go (`go.mod`, `go.sum`) and Rust (`Cargo.toml`, `Cargo.lock`)
- Elixir (`mix.lock`)

When a matching file changes and the associated tool is available on `PATH`,
the script executes the appropriate install/sync command. Missing tools are
reported but do not fail the hook.

## Optional Mark File

Set `GITHOOKS_DEPENDENCY_SYNC_MARK_FILE` (or the legacy
`GITHOOKS_CHANGE_MARK_FILE`) to capture a small audit file whenever commands
run:

```bash
export GITHOOKS_DEPENDENCY_SYNC_MARK_FILE=.git/hooks/dependency-sync.mark
```

The mark file lists the hook name, each triggered tool, and the paths that
changed.

## Tips

- Combine with `watch-configured-actions` for bespoke automation in addition to
  dependency installers.
- Use the optional mark file to confirm which lockfiles triggered a run when
  troubleshooting.
