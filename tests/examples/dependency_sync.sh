#!/bin/sh
# shellcheck shell=sh

set -eu

if [ -n "${EXAMPLE_CURRENT_SCRIPT:-}" ]; then
  example_source="${EXAMPLE_CURRENT_SCRIPT}"
else
  example_source=$0
  if [ ! -f "${example_source}" ] && [ "$#" -gt 0 ] && [ -f "$1" ]; then
    example_source=$1
  fi
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "${example_source}")" && pwd)
# shellcheck source=tests/examples/common.sh
. "${SCRIPT_DIR}/common.sh"

example_tests_init

example_test_dependency_sync() {
  TEST_FAILURE_DIAG=''
  tuple=$(ghr_mk_sandbox) || {
    TEST_FAILURE_DIAG='failed to create sandbox'
    return 1
  }
  old_ifs=$IFS
  IFS='|'
  set -- ${tuple}
  IFS=$old_ifs
  base=$1
  repo=$2
  remote=$3
  home=$4

  example_cleanup_dependency_sync() {
    ghr_cleanup_sandbox "$base"
  }
  trap example_cleanup_dependency_sync EXIT

  rc=0

  if [ "$rc" -eq 0 ]; then
    if ! ghr_init_repo "$repo" "$home"; then
      TEST_FAILURE_DIAG='git init failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_install_runner "$repo" "$home" "$INSTALLER" 'post-merge'; then
      TEST_FAILURE_DIAG='runner install failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    base_branch=$(ghr_git "$repo" "$home" symbolic-ref --short HEAD)
    parts_dir="$repo/.githooks/post-merge.d"
    mkdir -p "$parts_dir"
    if ! cp "$EXAMPLES_DIR/dependency-sync.sh" "$parts_dir/20-dependency-sync.sh"; then
      TEST_FAILURE_DIAG='failed to copy dependency-sync example'
      rc=1
    else
      chmod 755 "$parts_dir/20-dependency-sync.sh"
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    mkdir -p "$repo/bin"
    cat <<'SH' >"$repo/bin/bun"
#!/bin/sh
printf '%s\n' "$*" >> "${GITHOOKS_REPO_ROOT}/bun.log"
exit 0
SH
    chmod 755 "$repo/bin/bun"
    cat <<'SH' >"$repo/bin/cargo"
#!/bin/sh
printf '%s\n' "$*" >> "${GITHOOKS_REPO_ROOT}/cargo.log"
exit 0
SH
    chmod 755 "$repo/bin/cargo"
    cat <<'SH' >"$repo/bin/uv"
#!/bin/sh
printf '%s\n' "$*" >> "${GITHOOKS_REPO_ROOT}/uv.log"
exit 0
SH
    chmod 755 "$repo/bin/uv"
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_git "$repo" "$home" checkout -b feature >/dev/null 2>&1; then
      TEST_FAILURE_DIAG='failed to create feature branch'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    printf 'v1\n' >"$repo/bun.lock"
    printf '[package]\nname = "example"\nversion = "0.1.0"\n' >"$repo/Cargo.toml"
    printf '[[package]]\nname = "example"\nversion = "0.1.0"\n' >"$repo/Cargo.lock"
    printf '{"version": "0.1.0"}\n' >"$repo/uv.lock"
    ghr_git "$repo" "$home" add bun.lock Cargo.toml Cargo.lock uv.lock
    ghr_git "$repo" "$home" commit -q -m 'feat: add dependency manifests'
    ghr_git "$repo" "$home" checkout "$base_branch" >/dev/null 2>&1
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_in_repo "$repo" "$home" PATH="$repo/bin:$PATH" GITHOOKS_DEPENDENCY_SYNC_MARK_FILE=".git/change.mark" git merge --no-ff feature -q -m 'merge feature'; then
      TEST_FAILURE_DIAG='git merge failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    mark="$repo/.git/change.mark"
    bun_log="$repo/bun.log"
    cargo_log="$repo/cargo.log"
    uv_log="$repo/uv.log"
    if [ ! -f "$mark" ]; then
      TEST_FAILURE_DIAG='dependency sync mark file missing after merge'
      rc=1
    else
      mark_contents=$(ghr_read_or_empty "$mark")
      case "$mark_contents" in
        *'trigger=bun install: bun.lock'*) : ;;
        *) TEST_FAILURE_DIAG='mark file missing bun install trigger entry'; rc=1 ;;
      esac
      if [ "$rc" -eq 0 ]; then
        case "$mark_contents" in
          *'trigger=cargo fetch: Cargo.lock'*) : ;;
          *) TEST_FAILURE_DIAG='mark file missing cargo fetch trigger entry'; rc=1 ;;
        esac
      fi
      if [ "$rc" -eq 0 ]; then
        case "$mark_contents" in
          *'trigger=uv sync: uv.lock'*) : ;;
          *) TEST_FAILURE_DIAG='mark file missing uv sync trigger entry'; rc=1 ;;
        esac
      fi
    fi
    if [ "$rc" -eq 0 ]; then
      if [ ! -f "$bun_log" ]; then
        TEST_FAILURE_DIAG='bun stub did not execute'
        rc=1
      else
        bun_contents=$(ghr_read_or_empty "$bun_log")
        case "$bun_contents" in
          *'install'*) : ;;
          *) TEST_FAILURE_DIAG='bun stub log missing install invocation'; rc=1 ;;
        esac
      fi
    fi
    if [ "$rc" -eq 0 ]; then
      if [ ! -f "$cargo_log" ]; then
        TEST_FAILURE_DIAG='cargo stub did not execute'
        rc=1
      else
        cargo_contents=$(ghr_read_or_empty "$cargo_log")
        case "$cargo_contents" in
          *'fetch'*) : ;;
          *) TEST_FAILURE_DIAG='cargo stub log missing fetch invocation'; rc=1 ;;
        esac
      fi
    fi
    if [ "$rc" -eq 0 ]; then
      if [ ! -f "$uv_log" ]; then
        TEST_FAILURE_DIAG='uv stub did not execute'
        rc=1
      else
        uv_contents=$(ghr_read_or_empty "$uv_log")
        case "$uv_contents" in
          *'sync'*) : ;;
          *) TEST_FAILURE_DIAG='uv stub log missing sync invocation'; rc=1 ;;
        esac
      fi
    fi
  fi

  trap - EXIT
  ghr_cleanup_sandbox "$base"
  return "$rc"
}

example_register 'dependency-sync example triggers installer and mark file' example_test_dependency_sync

if [ "${EXAMPLE_TEST_RUN_MODE:-standalone}" = "standalone" ]; then
  if example_run_self; then
    exit 0
  fi
  exit 1
fi
