# metadata-apply example

## Overview

`metadata-apply.sh` restores filesystem metadata recorded by
[`metastore`](https://github.com/gurjeet/undistract-me#metastore) after merges,
rewrites, or checkouts. Use it to preserve permissions, owners, and other
attributes that Git does not track.

## Stage It

```bash
.githooks/install.sh stage add examples --name 'metadata-apply'
```

The script targets `post-merge`, `post-rewrite`, and `post-checkout` hooks via
its metadata declaration.

## Provide a Manifest

- By default the manifest is `.metadata` at the repository root.
- Override with `METASTORE_FILE`. Relative paths are resolved from the repo
  root; absolute paths are respected as-is.

The manifest must exist before the hook runs; the script exits quietly if it is
missing.

## metastore Command

Ensure `git` and `metastore` are installed and available on `PATH`. The hook
constructs and executes:

```bash
metastore -a -f <manifest> <repo-root>
```

Append extra flags by setting `METASTORE_APPLY_ARGS`, for example:

```bash
export METASTORE_APPLY_ARGS='-v'
```

## Optional Mark File

Set `GITHOOKS_METADATA_APPLY_MARK` to capture the hook status:

```bash
export GITHOOKS_METADATA_APPLY_MARK=.git/hooks/metadata-apply.mark
```

The mark records the hook name, whether the manifest was applied, and the
manifest location. If `metastore` is missing the mark reflects that the step was
skipped.
