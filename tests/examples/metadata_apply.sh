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

example_test_metadata_apply() {
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

  example_cleanup_metadata_apply() {
    ghr_cleanup_sandbox "$base"
  }
  trap example_cleanup_metadata_apply EXIT

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
    if ! cp "$EXAMPLES_DIR/metadata-apply.sh" "$parts_dir/30-metadata-apply.sh"; then
      TEST_FAILURE_DIAG='failed to copy metadata-apply example'
      rc=1
    else
      chmod 755 "$parts_dir/30-metadata-apply.sh"
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    mkdir -p "$repo/bin"
    cat <<'SH' >"$repo/bin/metastore"
#!/bin/sh
printf '%s\n' "$*" >> "${GITHOOKS_REPO_ROOT}/metastore.log"
exit 0
SH
    chmod 755 "$repo/bin/metastore"
    printf 'MODE=0755\n' >"$repo/.metadata"
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_git "$repo" "$home" checkout -b feature >/dev/null 2>&1; then
      TEST_FAILURE_DIAG='failed to create feature branch'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    printf 'change\n' >>"$repo/README.md"
    ghr_git "$repo" "$home" add README.md
    ghr_git "$repo" "$home" commit -q -m 'feat: trigger hook'
    ghr_git "$repo" "$home" checkout "$base_branch" >/dev/null 2>&1
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_in_repo "$repo" "$home" PATH="$repo/bin:$PATH" GITHOOKS_METADATA_APPLY_MARK=".git/meta.mark" git merge --no-ff feature -q -m 'merge feature'; then
      TEST_FAILURE_DIAG='git merge failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    mark="$repo/.git/meta.mark"
    meta_log="$repo/metastore.log"
    if [ ! -f "$mark" ]; then
      TEST_FAILURE_DIAG='metadata mark file missing after merge'
      rc=1
    else
      mark_contents=$(ghr_read_or_empty "$mark")
      case "$mark_contents" in
        *'status=applied'*) : ;;
        *) TEST_FAILURE_DIAG='metadata mark missing applied status'; rc=1 ;;
      esac
    fi
    if [ "$rc" -eq 0 ]; then
      expected="-a -f $repo/.metadata $repo"
      if [ ! -f "$meta_log" ]; then
        TEST_FAILURE_DIAG='metastore stub did not execute'
        rc=1
      else
        meta_contents=$(ghr_read_or_empty "$meta_log")
        case "$meta_contents" in
          *"$expected"*) : ;;
          *) TEST_FAILURE_DIAG='metastore stub log missing expected invocation'; rc=1 ;;
        esac
      fi
    fi
  fi

  trap - EXIT
  ghr_cleanup_sandbox "$base"
  return "$rc"
}

example_register 'metadata-apply example runs metastore and records status' example_test_metadata_apply

if [ "${EXAMPLE_TEST_RUN_MODE:-standalone}" = "standalone" ]; then
  if example_run_self; then
    exit 0
  fi
  exit 1
fi
