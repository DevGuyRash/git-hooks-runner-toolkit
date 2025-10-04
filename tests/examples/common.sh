#!/bin/sh
# Common helpers for git hook example tests (POSIX sh).
# shellcheck shell=sh

EXAMPLE_COMMON_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)

if [ -z "${EXAMPLE_TEST_DIR:-}" ]; then
  EXAMPLE_TEST_DIR="${EXAMPLE_COMMON_DIR}"
fi

example_tests_init() {
  if [ "${EXAMPLE_TESTS_INITIALIZED:-0}" = "1" ]; then
    return 0
  fi

  EXAMPLE_TESTS_INITIALIZED=1

  TEST_DIR=$(CDPATH= cd -- "${EXAMPLE_TEST_DIR}/.." && pwd)

  candidate_root=$(CDPATH= cd -- "${TEST_DIR}/.." && pwd)
  if [ -f "${candidate_root}/install.sh" ] && [ -d "${candidate_root}/examples" ]; then
    REPO_ROOT=${candidate_root}
    INSTALLER="${REPO_ROOT}/install.sh"
    EXAMPLES_DIR="${REPO_ROOT}/examples"
    LIB_PATH="${REPO_ROOT}/tests/lib/git_test_helpers.sh"
  else
    REPO_ROOT=$(CDPATH= cd -- "${TEST_DIR}/../../.." && pwd)
    INSTALLER="${REPO_ROOT}/scripts/.githooks/install.sh"
    EXAMPLES_DIR="${REPO_ROOT}/scripts/.githooks/examples"
    LIB_PATH="${REPO_ROOT}/scripts/.githooks/tests/lib/git_test_helpers.sh"
    if [ ! -f "${LIB_PATH}" ]; then
      LIB_PATH="${REPO_ROOT}/tests/lib/git_test_helpers.sh"
    fi
  fi

  if [ ! -d "${EXAMPLE_TEST_DIR}" ]; then
    printf 'Bail out! missing examples test directory at %s\n' "${EXAMPLE_TEST_DIR}" >&2
    exit 127
  fi

  if [ ! -f "${LIB_PATH}" ]; then
    printf 'Bail out! missing helper library at %s\n' "${LIB_PATH}" >&2
    exit 127
  fi
  if [ ! -x "${INSTALLER}" ]; then
    printf 'Bail out! missing installer at %s\n' "${INSTALLER}" >&2
    exit 127
  fi

  # shellcheck source=tests/lib/git_test_helpers.sh
  . "${LIB_PATH}"

  PASS=0
  FAIL=0
  TOTAL=0
  TEST_FAILURE_DIAG=''
  EXAMPLE_TEST_COUNT=0
  EXAMPLE_TEST_REGISTRY=''
}

diag() {
  printf '# %s\n' "$*"
}

ok() {
  PASS=$((PASS + 1))
  printf 'ok %d - %s\n' "${TOTAL}" "$1"
}

not_ok() {
  FAIL=$((FAIL + 1))
  printf 'not ok %d - %s\n' "${TOTAL}" "$1"
  if [ "${2:-}" != '' ]; then
    diag "$2"
  fi
}

tap_plan() {
  printf '1..%d\n' "$1"
}

run_test() {
  description=$1
  fn_name=$2
  TOTAL=$((TOTAL + 1))
  if "${fn_name}"; then
    ok "${description}"
  else
    not_ok "${description}" "${TEST_FAILURE_DIAG}"
  fi
  TEST_FAILURE_DIAG=''
}

example_register() {
  description=$1
  fn_name=$2

  if [ -z "${description}" ] || [ -z "${fn_name}" ]; then
    printf 'example_register requires <description> <function>\n' >&2
    exit 2
  fi

  EXAMPLE_TEST_COUNT=$((EXAMPLE_TEST_COUNT + 1))
  if [ -z "${EXAMPLE_TEST_REGISTRY}" ]; then
    EXAMPLE_TEST_REGISTRY="${fn_name}|${description}"
  else
    EXAMPLE_TEST_REGISTRY=$(printf '%s\n%s|%s' "${EXAMPLE_TEST_REGISTRY}" "${fn_name}" "${description}")
  fi
}

example_registered_count() {
  printf '%s' "${EXAMPLE_TEST_COUNT}"
}

example_run_registered_tests() {
  if [ "${EXAMPLE_TEST_COUNT:-0}" -eq 0 ]; then
    return 0
  fi

  while IFS='|' read -r fn desc; do
    [ -z "${fn}" ] && continue
    run_test "${desc}" "${fn}"
  done <<EOF
${EXAMPLE_TEST_REGISTRY}
EOF
}
example_finish() {
  diag "Pass=${PASS} Fail=${FAIL} Total=$((PASS+FAIL))"
  if [ "${FAIL}" -eq 0 ]; then
    return 0
  fi
  return 1
}

example_run_self() {
  tap_plan "$(example_registered_count)"
  example_run_registered_tests
  example_finish
}
