# Ephemeral Mode

## Overview

Ephemeral Mode installs the Git Hooks Runner Toolkit inside `.git/.githooks/`
so you can enable hook automation without committing toolkit files. The
installation persists across `git pull`, `git reset --hard`, and other Git
operations that rewrite the worktree, making it ideal for vendor-managed or
third-party repositories.

The lifecycle captures the previous `core.hooksPath`, records managed hooks,
and keeps runner assets local to the repository. You can refresh the
installation at any time by re-running the installer and toggle precedence when
combining local automation with a tracked `.githooks/` directory.

## Prerequisites

- A writable Git repository (worktree or bare) where you want the hooks to run
- A POSIX-compliant shell (`/bin/sh`) and the Git CLI available on `PATH`
- A local copy of the toolkit (vendored into the repository or a separate
  checkout referenced via `install.sh`)

## Installation

Clone or update the toolkit on your machine if you have not done so already:

```sh
git clone https://github.com/DevGuyRash/git-hooks-runner-toolkit.git \
  "$HOME/.cache/git-hooks-runner-toolkit"
```

Inside the repository that should receive hooks, run the installer in Ephemeral
Mode. The current working directory determines which Git repository is updated,
so you can execute the script from a shared toolkit checkout:

```sh
cd /path/to/target-repo
"$HOME/.cache/git-hooks-runner-toolkit/install.sh" install --mode ephemeral \
  --hooks pre-commit,post-merge
```

Invoke `install.sh install --mode ephemeral --help` for a full overview of
available flags, precedence controls, and usage notes directly from the CLI.

Confirm the active configuration after installation:

```sh
"$HOME/.cache/git-hooks-runner-toolkit/install.sh" config show
```

The summary lists the hooks path, precedence ordering, and any manifest
metadata captured during the run, making it easier to spot mismatches before
sharing the repository with other contributors.

Key flags to remember:

- `--hooks` selects the Git hooks to manage. The installer reuses any manifest
  entries from previous installs when the flag is omitted.
- `--overlay` controls precedence when both ephemeral and versioned hook roots
  exist (see below).
- `--dry-run` previews the install without touching the filesystem.

After a successful run, the CLI prints the active hooks path and precedence
mode. Hooks live under `.git/.githooks/` and survive repository syncs.

## Precedence and Overlay Control

Ephemeral Mode defaults to `ephemeral-first` precedence so local parts run
before tracked hooks. Adjust the ordering when you need different behavior:

- `--overlay ephemeral-first` — run ephemeral parts before any versioned hooks
- `--overlay versioned-first` — prioritize staged hooks from `.githooks/` before
  ephemeral parts
- `--overlay merge` — keep both root sets active without changing their default
  ordering while still recording the relationship in the manifest

You can set the preference on the CLI, via the `GITHOOKS_EPHEMERAL_PRECEDENCE`
environment variable, or with `git config --local githooks.ephemeral.precedence`
to persist the choice.

After installation, run the same `install.sh` path with `config show` to inspect
the active hooks path and resolved overlay ordering:

```sh
"$HOME/.cache/git-hooks-runner-toolkit/install.sh" config show
```

## Compatibility Notes

- The installer never writes to tracked files; all runner assets stay under
  `.git/.githooks/` with restrictive permissions.
- Existing `.githooks/` directories remain untouched and continue to work via
  overlay precedence controls.
- Prior `core.hooksPath` values are captured in the manifest so uninstall can
  restore repository configuration exactly.
- Re-running `install.sh install --mode ephemeral` refreshes stubs and manifest
  contents idempotently, making it safe to update hooks after toolkit upgrades.
- Bare repositories and linked worktrees are supported—the installer resolves
  `.git/` indirection and provisions the ephemeral directory inside the shared
  Git metadata area.
- CLI help and diagnostics avoid leaking implementation details but surface the
  information needed to confirm precedence, manifest location, and uninstall
  commands.

## Uninstall

To remove the ephemeral installation and restore the previous configuration:

```sh
cd /path/to/target-repo
"$HOME/.cache/git-hooks-runner-toolkit/install.sh" uninstall --mode ephemeral
```

The command deletes `.git/.githooks/`, restores the saved `core.hooksPath`, and
cleans up the manifest. Combine with `--dry-run` to preview the removal.

Dry-run the uninstall when you want to confirm which files would be affected:

```sh
"$HOME/.cache/git-hooks-runner-toolkit/install.sh" uninstall --mode ephemeral --dry-run
```

After cleanup, invoke `install.sh config show` with the same path to ensure the
previous hooks path is back in place and precedence matches expectations.

## Troubleshooting

- Run `path/to/install.sh config show` (using the same path you invoke for
  install) to confirm the active hooks path when diagnosing precedence issues.
- Inspect `.git/.githooks/manifest.sh` to verify recorded hooks, precedence, and
  the prior `core.hooksPath` value if uninstall behaves unexpectedly.
- If another tool modifies `core.hooksPath`, rerun the installer with
  `--mode ephemeral` to refresh stubs and restore ephemeral precedence.
- Use the uninstall dry-run to identify stray files before removal, then rerun
  with `--mode ephemeral` when the output matches expectations.
- After uninstall completes, run the `config show` command again to validate the
  restored hooks path before re-enabling tracking tooling.
- Use `install.sh install --mode ephemeral --help` or
  `install.sh uninstall --mode ephemeral --help` for context-specific guidance
  when resolving CLI errors or reviewing the supported flag set.
