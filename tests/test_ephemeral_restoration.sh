#!/bin/sh
# Real commits prove restoration, not just manifest/config string comparisons.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd -P)
INSTALLER=${INSTALLER:-${ROOT}/install.sh}
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/githooks-restoration.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$SANDBOX/global-config"
export GIT_AUTHOR_NAME=Test GIT_COMMITTER_NAME=Test
export GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_EMAIL=test@example.invalid
export TRACE="$SANDBOX/trace"
REAL_MV=$(command -v mv)
export REAL_MV
mkdir "$SANDBOX/bin"
# Fail only publication of the manifest, after core.hooksPath was changed.
cat > "$SANDBOX/bin/mv" <<'SH'
#!/bin/sh
case $* in
  *manifest.sh.tmp.*) echo 'injected manifest publication failure' >&2; exit 73 ;;
esac
exec "$REAL_MV" "$@"
SH
chmod +x "$SANDBOX/bin/mv"

hook() {
  mkdir -p "$1"
  printf '#!/bin/sh\nprintf "%%s\\n" "%s" >> "$TRACE"\nexit 42\n' "$2" > "$1/pre-commit"
  chmod +x "$1/pre-commit"
}
setup() {
  kind=$1
  repo="$SANDBOX/$2"
  : > "$GIT_CONFIG_GLOBAL"
  git init -q "$repo"
  git -C "$repo" commit --allow-empty -qm seed
  original_value=''
  original_set=0
  hook "$repo/.git/hooks" original
  case $kind in
    unset) ;;
    custom)
      original_value=".git/custom 'hooks"
      original_set=1
      hook "$repo/$original_value" original
      git -C "$repo" config --local core.hooksPath "$original_value"
      ;;
    global|empty)
      global_value="$repo/global hooks"
      hook "$global_value" global
      git config --global core.hooksPath "$global_value"
      if [ "$kind" = empty ]; then
        original_set=1
        git -C "$repo" config --local core.hooksPath ''
      fi
      ;;
  esac
}
installer() {
  (cd "$repo" && "$INSTALLER" "$@" --mode ephemeral) > "$SANDBOX/installer.log" 2>&1 || {
    cat "$SANDBOX/installer.log" >&2
    return 1
  }
}
assert_config() {
  local_set=0
  if local_value=$(git -C "$repo" config --local --get core.hooksPath); then
    local_set=1
  fi
  [ "$local_set" = "$1" ] && [ "$local_value" = "$2" ] || {
    printf 'Expected config presence/value <%s>/<%s>, got <%s>/<%s>\n' "$1" "$2" "$local_set" "$local_value" >&2
    exit 1
  }
}
assert_commit() {
  : > "$TRACE"
  before=$(git -C "$repo" rev-parse HEAD)
  status=0
  git -C "$repo" commit --allow-empty -qm probe > "$SANDBOX/commit.log" 2>&1 || status=$?
  if [ "$1" = disabled ]; then
    [ "$status" -eq 0 ] && [ ! -s "$TRACE" ]
  else
    [ "$status" -ne 0 ] && [ "$(cat "$TRACE")" = "$1" ] &&
      [ "$(git -C "$repo" rev-parse HEAD)" = "$before" ]
  fi || {
    cat "$SANDBOX/commit.log" >&2
    printf 'Hook outcome wrong: expected %s, status %s, trace <%s>\n' "$1" "$status" "$(cat "$TRACE")" >&2
    exit 1
  }
}
assert_original() {
  assert_config "$original_set" "$original_value"
  case $kind in
    empty) assert_commit disabled ;;
    global) assert_commit global ;;
    *) assert_commit original ;;
  esac
  case $kind in
    global|empty) [ "$(git config --global --get core.hooksPath)" = "$global_value" ] ;;
  esac
}
active_hook() {
  hook "$repo/.git/.githooks/parts/pre-commit.d" active
  mv "$repo/.git/.githooks/parts/pre-commit.d/pre-commit" "$repo/.git/.githooks/parts/pre-commit.d/10-active.sh"
}

assert_manifest() {
  grep -qx "PREVIOUS_CORE_HOOKS_PATH_SET='$original_set'" "$repo/.git/.githooks/manifest.sh"
  # Parse as data with the production reader; never source the manifest.
  value=$(cd "$repo" && GITHOOKS_TEST_ROOT="$ROOT" sh -c '
    . "$GITHOOKS_TEST_ROOT/lib/common.sh"
    . "$GITHOOKS_TEST_ROOT/lib/ephemeral_lifecycle.sh"
    ephemeral_manifest_get PREVIOUS_CORE_HOOKS_PATH
  ')
  [ "$value" = "$original_value" ]
}
fail_publication() {
  if (PATH="$SANDBOX/bin:$PATH"; export PATH; installer "$@"); then
    echo 'Manifest publication failure unexpectedly succeeded' >&2
    exit 1
  fi
  grep -q 'injected manifest publication failure' "$SANDBOX/installer.log"
}

# Every complete journey starts with a working original configuration, repeats
# either installation or refresh, then verifies an actual Git commit afterwards.
for kind in unset custom global empty; do
  for action in install update; do
    setup "$kind" "$kind-$action"
    assert_original
    installer install --hooks pre-commit
    installer "$action"
    installer "$action"
    assert_manifest
    installer uninstall
    [ ! -e "$repo/.git/.githooks" ]
    assert_original
    installer uninstall
    assert_original
    printf 'ok - %s after repeated %s and idempotent uninstall\n' "$kind" "$action"
  done
done

for kind in unset custom global empty; do
  setup "$kind" "$kind-failed-first-install"
  fail_publication install --hooks pre-commit
  [ ! -e "$repo/.git/.githooks" ]
  assert_original
  printf 'ok - failed first install restores %s\n' "$kind"

  for action in install update; do
    setup "$kind" "$kind-failed-$action"
    installer install --hooks pre-commit
    active_hook
    cp "$repo/.git/.githooks/manifest.sh" "$SANDBOX/saved-manifest"
    fail_publication "$action"
    assert_config 1 '.git/.githooks'
    cmp "$SANDBOX/saved-manifest" "$repo/.git/.githooks/manifest.sh"
    assert_commit active
    installer uninstall
    assert_original
    printf 'ok - failed %s keeps active runner then restores %s on uninstall\n' "$action" "$kind"
  done
done

# Rollback tracks intervening changes, rather than the original uninstall target.
for state in unset custom empty; do
  setup custom "intervening-$state"
  installer install --hooks pre-commit
  case $state in
    unset) git -C "$repo" config --local --unset core.hooksPath ;;
    custom) git -C "$repo" config --local core.hooksPath '.git/hooks' ;;
    empty) git -C "$repo" config --local core.hooksPath '' ;;
  esac
  fail_publication update
  case $state in
    unset) assert_config 0 '' ;;
    custom) assert_config 1 '.git/hooks' ;;
    empty) assert_config 1 '' ;;
  esac
  assert_manifest
  installer uninstall
  assert_original
  printf 'ok - failed refresh preserves intervening %s config\n' "$state"
done

# Old manifests have no presence field; never replace their original snapshot.
for kind in unset custom; do
  setup "$kind" "legacy-$kind"
  installer install --hooks pre-commit
  sed '/^PREVIOUS_CORE_HOOKS_PATH_SET=/d' "$repo/.git/.githooks/manifest.sh" > "$SANDBOX/legacy"
  cat "$SANDBOX/legacy" > "$repo/.git/.githooks/manifest.sh"
  installer update
  assert_manifest
  installer uninstall
  assert_original
  printf 'ok - legacy %s snapshot survives refresh\n' "$kind"
done

for kind in unset custom empty; do
  setup "$kind" "locked-uninstall-$kind"
  installer install --hooks pre-commit
  active_hook
  cp "$repo/.git/.githooks/manifest.sh" "$SANDBOX/saved-manifest"
  : > "$repo/.git/config.lock"
  if installer uninstall; then
    echo 'Uninstall with locked config unexpectedly succeeded' >&2
    exit 1
  fi
  assert_config 1 '.git/.githooks'
  cmp "$SANDBOX/saved-manifest" "$repo/.git/.githooks/manifest.sh"
  assert_commit active
  rm "$repo/.git/config.lock"
  installer uninstall
  assert_original
  printf 'ok - locked config preserves runner and allows uninstall retry (%s)\n' "$kind"
done

setup custom dry-run
installer install --dry-run --hooks pre-commit
[ ! -e "$repo/.git/.githooks" ]
assert_original
installer install --hooks pre-commit
cp "$repo/.git/.githooks/manifest.sh" "$SANDBOX/saved-manifest"
installer update --dry-run
installer uninstall --dry-run
assert_config 1 '.git/.githooks'
cmp "$SANDBOX/saved-manifest" "$repo/.git/.githooks/manifest.sh"
installer uninstall
assert_original
printf 'ok - dry runs preserve original and active snapshots\n'
