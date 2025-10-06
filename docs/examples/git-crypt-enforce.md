# git-crypt-enforce example

## Overview

`git-crypt-enforce.sh` is a `pre-commit` hook part that prevents secrets from
being committed in plaintext when `.gitattributes` marks a path with a
`git-crypt` filter.

## Stage It

```bash
.githooks/install.sh stage add examples --name 'git-crypt-enforce'
```

The script wires into the `pre-commit` hook via its metadata header.

## What It Checks

1. Ensures `.gitattributes` changes are not committed alongside other files
   unless explicitly allowed.
2. Verifies every staged file mapped to `filter=git-crypt` (or `git-crypt-*`)
   begins with the git-crypt signature.
3. Optionally scans `HEAD` for unencrypted tracked files when strict mode is
   enabled.

Failures surface detailed remediation steps and the offending paths.

## Configuration Flags

Set these via environment variables or `git config` (preferred for persistence):

| Setting | Description | Default |
| --- | --- | --- |
| `GITCRYPT_ALLOW_MIXED_GITATTRIBUTES` / `gitcrypt.hook.allowMixedGitAttributes` | Allow `.gitattributes` changes to ship with other files. | `false` |
| `GITCRYPT_AUTO_FIX` / `gitcrypt.hook.autofix` | Attempt `git-crypt status -f` automatically before failing. | `false` |
| `GITCRYPT_STRICT_HEAD` / `gitcrypt.hook.strictHead` | Scan `HEAD` for plaintext copies of protected files. | `false` |

Example persistent setup:

```bash
git config gitcrypt.hook.autofix true
git config gitcrypt.hook.strictHead true
```

## Requirements

- [`git-crypt`](https://www.agwa.name/projects/git-crypt/) must be installed and
  the repository unlocked for encryption checks to pass.
- `.gitattributes` must assign `filter=git-crypt` (or a variant) to all secrets.
