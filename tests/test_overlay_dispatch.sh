#!/bin/sh
# Real Git journeys through the installed ephemeral runner, not just its manifest.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd -P)
INSTALLER=${INSTALLER:-${ROOT}/install.sh}
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/githooks-overlay.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=Test GIT_COMMITTER_NAME=Test
export GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_EMAIL=test@example.invalid
export TRACE="${SANDBOX}/trace"

part() {
  mkdir -p "$1/$2.d"
  printf '#!/bin/sh\nprintf "%%s\\n" "%s" >> "$TRACE"\nexit %s\n' "$3" "${4:-0}" > "$1/$2.d/$3.sh"
  chmod +x "$1/$2.d/$3.sh"
}
expect() {
  actual=$(cat "$TRACE")
  if [ "$actual" != "$1" ]; then
    printf 'Expected <%s>, got <%s>\n' "$1" "$actual" >&2
    exit 1
  fi
}
commit() {
  : > "$TRACE"
  git -C "$repo" commit --allow-empty -qm test
}

repo="${SANDBOX}/repo name n"
git init -q "$repo"
for mode in ephemeral-first versioned-first merge; do
  (cd "$repo" && "$INSTALLER" install --mode ephemeral --hooks pre-commit --overlay "$mode")
  part "$repo/.git/.githooks/parts" pre-commit 10-ephemeral
  part "$repo/.githooks" pre-commit 20-versioned
  part "$repo/.githooks" pre-commit 10-versioned
  commit
  if [ "$mode" = versioned-first ]; then
    expect '10-versioned
20-versioned
10-ephemeral'
  else
    expect '10-ephemeral
10-versioned
20-versioned'
  fi
  printf 'ok - installed %s ordering\n' "$mode"
done

# Runtime overrides retain env > config > saved-install precedence.
git -C "$repo" config githooks.ephemeral.precedence versioned-first
commit
expect '10-versioned
20-versioned
10-ephemeral'
export GITHOOKS_EPHEMERAL_PRECEDENCE=ephemeral-first
commit
expect '10-ephemeral
10-versioned
20-versioned'
unset GITHOOKS_EPHEMERAL_PRECEDENCE
git -C "$repo" config --unset githooks.ephemeral.precedence
# A modified manifest is data, never executable shell input.
printf "PRECEDENCE_MODE='invalid'\ntouch '%s'\n" "$SANDBOX/manifest-executed" > "$repo/.git/.githooks/manifest.sh"
commit
expect '10-ephemeral
10-versioned
20-versioned'
[ ! -e "$SANDBOX/manifest-executed" ]
printf 'ok - precedence overrides and untrusted manifest data\n'

# Preserve literal backslashes (including escape-like sequences), spaces and n.
extra="${SANDBOX}/extra n \\notes"
part "$extra" pre-commit 30-extra
git -C "$repo" config --add githooks.ephemeral.extraRoot "$extra"
git -C "$repo" config --add githooks.ephemeral.extraRoot "$extra"
export GITHOOKS_EPHEMERAL_EXTRA_ROOTS="$extra:$repo/.githooks,$extra"
commit
expect '10-ephemeral
10-versioned
20-versioned
30-extra'
unset GITHOOKS_EPHEMERAL_EXTRA_ROOTS
printf 'ok - extra roots preserve names and deduplicate\n'

# Refresh existing installs must repair the missing overlay asset too.
rm "$repo/.git/.githooks/lib/ephemeral_overlay.sh"
(cd "$repo" && "$INSTALLER" update --mode ephemeral)
commit
expect '10-ephemeral
10-versioned
20-versioned
30-extra'
printf 'ok - update restores overlay library\n'

part "$extra" pre-commit 40-failure 23
part "$extra" pre-commit 50-must-not-run
before=$(git -C "$repo" rev-parse HEAD)
if commit; then
  printf 'Failing hook incorrectly allowed commit\n' >&2
  exit 1
fi
[ "$(git -C "$repo" rev-parse HEAD)" = "$before" ]
expect '10-ephemeral
10-versioned
20-versioned
30-extra
40-failure'
# Git normalizes a pre-commit failure to 1; direct dispatch preserves its code.
: > "$TRACE"
status=0
(cd "$repo" && .git/.githooks/pre-commit) || status=$?
[ "$status" -eq 23 ]
printf 'ok - failing hook blocks commit and preserves dispatcher status\n'

# Linked worktrees use their own Git directory rather than assuming .git is a dir.
main="$repo"
repo="${SANDBOX}/linked name"
git -C "$main" worktree add -qb linked "$repo"
(cd "$repo" && "$INSTALLER" install --mode ephemeral --hooks pre-commit)
gitdir=$(git -C "$repo" rev-parse --absolute-git-dir)
part "$gitdir/.githooks/parts" pre-commit 10-linked
part "$repo/.githooks" pre-commit 20-linked
# Extra roots are shared local config, so clear the prior fixture's failing root.
git -C "$repo" config --unset-all githooks.ephemeral.extraRoot
: > "$TRACE"
# The installer has a separate pre-existing linked-worktree hooksPath issue.
# Exercise this worktree's installed runner via an explicit per-command path.
git -C "$repo" -c core.hooksPath="$gitdir/.githooks" commit --allow-empty -qm test
expect '10-linked
20-linked'
printf 'ok - linked-worktree dispatcher with explicit hooksPath\n'

# Receive hook stdin remains intact while both roots run in a bare repository.
bare="${SANDBOX}/bare name.git"
git init --bare -q "$bare"
(cd "$bare" && "$INSTALLER" install --mode ephemeral --hooks pre-receive)
part "$bare/.githooks/parts" pre-receive 10-bare
part "$bare/hooks" pre-receive 20-bare
printf '#!/bin/sh\ncat > "$TRACE.stdin"\n' > "$bare/hooks/pre-receive.d/30-input.sh"
chmod +x "$bare/hooks/pre-receive.d/30-input.sh"
: > "$TRACE"
git -C "$repo" push -q "$bare" HEAD:refs/heads/main
expect '10-bare
20-bare'
grep -q ' refs/heads/main$' "$TRACE.stdin"
printf 'ok - installed bare receive dispatch and stdin\n'
