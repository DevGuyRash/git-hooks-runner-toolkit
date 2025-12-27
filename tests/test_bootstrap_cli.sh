#!/bin/sh
# TAP tests covering bootstrap command behavior.

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${TEST_DIR}/.." && pwd)
LIB_PATH="${REPO_ROOT}/tests/lib/git_test_helpers.sh"
INSTALLER="${REPO_ROOT}/install.sh"

if [ ! -f "${LIB_PATH}" ]; then
  printf '1..0\n'
  printf '# Bail out! missing helper library at %s\n' "${LIB_PATH}" >&2
  exit 127
fi
if [ ! -x "${INSTALLER}" ]; then
  printf '1..0\n'
  printf '# Bail out! missing installer at %s\n' "${INSTALLER}" >&2
  exit 127
fi

. "${LIB_PATH}"

PASS=0
FAIL=0
TOTAL=0
TEST_FAILURE_DIAG=''

diag() {
  printf '# %s\n' "$*"
}

ok() {
  PASS=$((PASS + 1))
  printf 'ok %d - %s\n' "$TOTAL" "$1"
}

not_ok() {
  FAIL=$((FAIL + 1))
  printf 'not ok %d - %s\n' "$TOTAL" "$1"
  if [ "${2:-}" != '' ]; then
    diag "$2"
  fi
}

tap_plan() {
  printf '1..%d\n' "$1"
}

parse_tuple() {
  tuple_value=$1
  old_ifs=$IFS
  IFS='|'
  set -- $tuple_value
  IFS=$old_ifs
  parsed_base=$1
  parsed_repo=$2
  parsed_remote=$3
  parsed_home=$4
}

cleanup_and_return() {
  cleanup_target=$1
  cleanup_status=$2
  trap - EXIT
  ghr_cleanup_sandbox "$cleanup_target"
  return "$cleanup_status"
}

test_bootstrap_creates_toolkit_copy() {
  TEST_FAILURE_DIAG=''
  tuple=$(ghr_mk_sandbox) || {
    TEST_FAILURE_DIAG='failed to create sandbox'
    return 1
  }
  parse_tuple "$tuple"
  trap 'ghr_cleanup_sandbox "$parsed_base"' EXIT
  rc=0

  if [ "$rc" -eq 0 ] && ! ghr_init_repo "$parsed_repo" "$parsed_home"; then
    TEST_FAILURE_DIAG='git init failed'
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" bootstrap; then
      TEST_FAILURE_DIAG='bootstrap command failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if [ ! -x "$parsed_repo/.githooks/install.sh" ]; then
      TEST_FAILURE_DIAG='expected vendored install.sh missing or not executable'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if [ ! -x "$parsed_repo/.githooks/tui/githooks-tui.sh" ]; then
      TEST_FAILURE_DIAG='expected vendored TUI script missing or not executable'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if [ -e "$parsed_repo/.git/hooks/_runner.sh" ]; then
      TEST_FAILURE_DIAG='bootstrap unexpectedly installed runner stubs'
      rc=1
    fi
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

test_bootstrap_requires_force_to_overwrite() {
  TEST_FAILURE_DIAG=''
  tuple=$(ghr_mk_sandbox) || {
    TEST_FAILURE_DIAG='failed to create sandbox'
    return 1
  }
  parse_tuple "$tuple"
  trap 'ghr_cleanup_sandbox "$parsed_base"' EXIT
  rc=0

  if [ "$rc" -eq 0 ] && ! ghr_init_repo "$parsed_repo" "$parsed_home"; then
    TEST_FAILURE_DIAG='git init failed'
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" bootstrap; then
      TEST_FAILURE_DIAG='initial bootstrap failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    printf 'sentinel\n' >"$parsed_repo/.githooks/.bootstrap-sentinel"
  fi

  if [ "$rc" -eq 0 ]; then
    if ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" bootstrap >/dev/null 2>&1; then
      TEST_FAILURE_DIAG='bootstrap succeeded without --force when target existed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if [ ! -f "$parsed_repo/.githooks/.bootstrap-sentinel" ]; then
      TEST_FAILURE_DIAG='bootstrap without --force removed existing toolkit'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" bootstrap --force; then
      TEST_FAILURE_DIAG='bootstrap --force failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if [ -f "$parsed_repo/.githooks/.bootstrap-sentinel" ]; then
      TEST_FAILURE_DIAG='bootstrap --force did not replace toolkit contents'
      rc=1
    fi
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

TOTAL_TESTS=2

tap_plan "$TOTAL_TESTS"

run_test() {
  description=$1
  fn_name=$2
  TOTAL=$((TOTAL + 1))
  if "$fn_name"; then
    ok "$description"
  else
    not_ok "$description" "$TEST_FAILURE_DIAG"
  fi
  TEST_FAILURE_DIAG=''
}

run_test 'bootstrap vendors the toolkit without installing hooks' test_bootstrap_creates_toolkit_copy
run_test 'bootstrap requires --force to overwrite existing toolkit' test_bootstrap_requires_force_to_overwrite

if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
