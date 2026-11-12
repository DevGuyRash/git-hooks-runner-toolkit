#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd -P)
INSTALLER=${INSTALLER:-$ROOT/install.sh}
S=$(mktemp -d "${TMPDIR:-/tmp}/githooks-worktrees.XXXXXX")
trap 'rm -rf "$S"' EXIT HUP INT TERM
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=Test GIT_COMMITTER_NAME=Test
export GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_EMAIL=test@example.invalid
export TRACE="$S/trace"
REAL_MV=$(command -v mv)
export REAL_MV
mkdir "$S/bin"
cat > "$S/bin/mv" <<'SH'
#!/bin/sh
case $* in
  *manifest.sh.tmp.*) echo 'injected manifest failure' >&2; exit 73 ;;
esac
exec "$REAL_MV" "$@"
SH
chmod +x "$S/bin/mv"

hook() {
  mkdir -p "$(dirname "$1")"
  printf '#!/bin/sh\nprintf "%%s\\n" "%s" >> "$TRACE"\nexit 42\n' "$2" > "$1"
  chmod +x "$1"
}
setup() {
  base="$S/$1"
  main="$base/main"
  a="$base/linked A"
  b="$base/linked B"
  git init -q "$main"
  git -C "$main" commit --allow-empty -qm seed
  git -C "$main" worktree add -qb a "$a"
  git -C "$main" worktree add -qb b "$b"
  hook "$base/shared hooks/pre-commit" shared
  git -C "$main" config --local core.hooksPath "$base/shared hooks"
  git -C "$main" config extensions.worktreeConfig true
  cp "$main/.git/config" "$base/shared.config"
  target=$a
  original=shared
}
select_target() {
  target=$1
  gitdir=$(git -C "$target" rev-parse --absolute-git-dir)
  managed="$gitdir/.githooks"
}
prior() {
  case $1 in
    absent) original=shared ;;
    empty) git -C "$target" config --worktree core.hooksPath ''; original=disabled ;;
    custom)
      hook "$base/prior hooks/pre-commit" custom
      git -C "$target" config --worktree core.hooksPath "$base/prior hooks"
      original=custom
      ;;
  esac
}
run_installer() {
  (cd "$target" && "$INSTALLER" "$@" --mode ephemeral) > "$S/install.log" 2>&1 || {
    cat "$S/install.log" >&2
    return 1
  }
}
commit() {
  tree=$1
  want=$2
  : > "$TRACE"
  before=$(git -C "$tree" rev-parse HEAD)
  status=0
  git -C "$tree" commit --allow-empty -qm probe > "$S/commit.log" 2>&1 || status=$?
  if [ "$want" = disabled ]; then
    [ "$status" -eq 0 ] && [ ! -s "$TRACE" ]
  else
    [ "$status" -ne 0 ] && [ "$(cat "$TRACE")" = "$want" ] &&
      [ "$(git -C "$tree" rev-parse HEAD)" = "$before" ]
  fi || {
    cat "$S/commit.log" >&2
    printf 'Expected %s hook in %s; status=%s trace=<%s>\n' "$want" "$tree" "$status" "$(cat "$TRACE")" >&2
    exit 1
  }
}
all_commits() {
  for tree in "$main" "$a" "$b"; do
    want=shared
    if [ "$tree" = "$target" ]; then want=$1; fi
    commit "$tree" "$want"
  done
  cmp "$base/shared.config" "$main/.git/config"
}
activate() {
  run_installer install --hooks pre-commit
  hook "$managed/parts/pre-commit.d/10-block.sh" active
  [ "$(git -C "$target" config --worktree --get core.hooksPath)" = "$managed" ]
  grep -qx "CORE_HOOKS_PATH_SCOPE='worktree'" "$managed/manifest.sh"
}
original_config() {
  case $original in
    shared) ! git -C "$target" config --worktree --get core.hooksPath ;;
    disabled) [ "$(git -C "$target" config --worktree --get core.hooksPath)" = '' ] ;;
    custom) [ "$(git -C "$target" config --worktree --get core.hooksPath)" = "$base/prior hooks" ] ;;
  esac
}
fail_publication() {
  if (PATH="$S/bin:$PATH"; export PATH; run_installer "$@"); then
    echo 'Expected manifest failure' >&2
    exit 1
  fi
  grep -q 'injected manifest failure' "$S/install.log"
}

for location in main linked; do
  for state in absent empty custom; do
    setup "$location-$state"
    if [ "$location" = main ]; then select_target "$main"; else select_target "$a"; fi
    prior "$state"
    all_commits "$original"
    activate
    all_commits active
    run_installer install --hooks pre-commit
    all_commits active
    run_installer update
    all_commits active
    cp "$managed/manifest.sh" "$base/manifest"
    cp "$gitdir/config.worktree" "$base/worktree.config"
    run_installer update --dry-run
    run_installer uninstall --dry-run
    cmp "$base/manifest" "$managed/manifest.sh"
    cmp "$base/worktree.config" "$gitdir/config.worktree"
    all_commits active
    run_installer uninstall
    [ ! -e "$managed" ]
    original_config
    all_commits "$original"
    run_installer uninstall
    original_config
    all_commits "$original"
    printf 'ok - %s %s scope survives install/reinstall/update/uninstall without changing siblings\n' "$location" "$state"
  done
done

for state in absent empty custom; do
  setup "fail-$state"
  select_target "$a"
  prior "$state"
  fail_publication install --hooks pre-commit
  [ ! -e "$managed" ]
  original_config
  all_commits "$original"
  activate
  cp "$managed/manifest.sh" "$base/manifest"
  for action in install update; do
    fail_publication "$action"
    [ "$(git -C "$target" config --worktree --get core.hooksPath)" = "$managed" ]
    cmp "$base/manifest" "$managed/manifest.sh"
    all_commits active
  done
  : > "$gitdir/config.worktree.lock"
  for action in update uninstall; do
    if run_installer "$action"; then echo 'Expected locked config failure' >&2; exit 1; fi
    cmp "$base/manifest" "$managed/manifest.sh"
    all_commits active
  done
  rm "$gitdir/config.worktree.lock"
  run_installer uninstall
  original_config
  all_commits "$original"
  printf 'ok - %s scoped publication failure and config-lock retry\n' "$state"
done

for location in main linked; do
  setup "disabled-$location"
  if [ "$location" = main ]; then select_target "$main"; else select_target "$a"; fi
  git -C "$main" config --unset extensions.worktreeConfig
  cp "$main/.git/config" "$base/shared.config"
  if run_installer install --hooks pre-commit; then echo 'Unsafe shared install succeeded' >&2; exit 1; fi
  grep -q 'requires extensions.worktreeConfig=true' "$S/install.log"
  [ ! -e "$managed" ] && [ ! -e "$gitdir/config.worktree" ]
  all_commits shared
  printf 'ok - disabled extension refuses %s install without mutation\n' "$location"

  git -C "$main" config extensions.worktreeConfig true
  cp "$main/.git/config" "$base/shared.config"
  mkdir -p "$managed"
  printf "PREVIOUS_CORE_HOOKS_PATH=''\nMANAGED_HOOKS='pre-commit'\n" > "$managed/manifest.sh"
  cp "$managed/manifest.sh" "$base/manifest"
  for action in install update uninstall; do
    if run_installer "$action"; then echo 'Ambiguous legacy install accepted' >&2; exit 1; fi
    grep -q 'Legacy shared-scope' "$S/install.log"
    cmp "$base/manifest" "$managed/manifest.sh"
    [ ! -e "$managed/_runner.sh" ] && [ ! -e "$gitdir/config.worktree" ]
    all_commits shared
  done
  printf 'ok - legacy shared %s manifest refuses all lifecycle writes\n' "$location"
done

setup extension-removed
select_target "$a"
activate
git -C "$main" config --unset extensions.worktreeConfig
cp "$main/.git/config" "$base/shared.config"
cp "$managed/manifest.sh" "$base/manifest"
cp "$gitdir/config.worktree" "$base/worktree.config"
for action in install update uninstall; do
  if run_installer "$action"; then echo 'Disabled scoped installation accepted' >&2; exit 1; fi
  cmp "$base/manifest" "$managed/manifest.sh"
  cmp "$base/worktree.config" "$gitdir/config.worktree"
  all_commits shared
done
printf 'ok - disabling extension never falls back to shared config\n'

base="$S/separate"
target="$base/work"
mkdir -p "$base"
git init -q --separate-git-dir "$base/git metadata" "$target"
git -C "$target" commit --allow-empty -qm seed
select_target "$target"
hook "$gitdir/hooks/pre-commit" original
commit "$target" original
run_installer install --hooks pre-commit
hook "$managed/parts/pre-commit.d/10-block.sh" active
[ "$(git -C "$target" config --local --get core.hooksPath)" = "$managed" ]
commit "$target" active
run_installer update
commit "$target" active
run_installer uninstall
[ ! -e "$managed" ]
! git -C "$target" config --local --get core.hooksPath
! git -C "$target" config --get extensions.worktreeConfig
commit "$target" original
printf 'ok - separate Git directory uses an absolute path without enabling extensions\n'
