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

exit_code_helper="${REPO_ROOT}/examples/scripts/exit-code-from-output.sh"

example_test_exit_code_helper_exists() {
  if [ ! -x "${exit_code_helper}" ]; then
    TEST_FAILURE_DIAG="missing helper at ${exit_code_helper}"
    return 1
  fi
  return 0
}

example_test_exit_code_pass_stdin() {
  if ! printf 'PASS\n' | "${exit_code_helper}" >/dev/null 2>&1; then
    status=$?
    TEST_FAILURE_DIAG="expected exit 0 for PASS, got ${status}"
    return 1
  fi
  return 0
}

example_test_exit_code_fail_stdin() {
  if printf 'FAIL\n' | "${exit_code_helper}" >/dev/null 2>&1; then
    TEST_FAILURE_DIAG='expected non-zero exit for FAIL'
    return 1
  fi
  return 0
}

example_test_exit_code_unknown_stdin() {
  if printf 'MAYBE\n' | "${exit_code_helper}" >/dev/null 2>&1; then
    TEST_FAILURE_DIAG='expected non-zero exit when no PASS/FAIL present'
    return 1
  fi
  return 0
}

example_test_exit_code_file_input() {
  tmp_file=$(mktemp "${TMPDIR:-/tmp}/exit-code-helper.XXXXXX")
  printf 'PASS\n' >"${tmp_file}"
  if ! "${exit_code_helper}" --file "${tmp_file}" >/dev/null 2>&1; then
    status=$?
    rm -f -- "${tmp_file}"
    TEST_FAILURE_DIAG="expected exit 0 for PASS file, got ${status}"
    return 1
  fi
  rm -f -- "${tmp_file}"
  return 0
}

example_test_exit_code_cmd_input() {
  if "${exit_code_helper}" -- printf 'FAIL\n' >/dev/null 2>&1; then
    TEST_FAILURE_DIAG='expected non-zero exit for FAIL command output'
    return 1
  fi
  return 0
}

example_test_exit_code_custom_patterns() {
  if ! printf 'OK\n' | "${exit_code_helper}" --fail 'BLOCK' --pass 'OK' >/dev/null 2>&1; then
    status=$?
    TEST_FAILURE_DIAG="expected exit 0 for custom PASS, got ${status}"
    return 1
  fi
  if printf 'BLOCK\n' | "${exit_code_helper}" --fail 'BLOCK' --pass 'OK' >/dev/null 2>&1; then
    TEST_FAILURE_DIAG='expected non-zero exit for custom FAIL'
    return 1
  fi
  return 0
}

example_register 'exit-code helper exists' example_test_exit_code_helper_exists
example_register 'exit-code helper passes on PASS stdin' example_test_exit_code_pass_stdin
example_register 'exit-code helper fails on FAIL stdin' example_test_exit_code_fail_stdin
example_register 'exit-code helper fails on unknown stdin' example_test_exit_code_unknown_stdin
example_register 'exit-code helper supports --file' example_test_exit_code_file_input
example_register 'exit-code helper supports -- cmd' example_test_exit_code_cmd_input
example_register 'exit-code helper supports custom patterns' example_test_exit_code_custom_patterns

if [ "${EXAMPLE_TEST_RUN_MODE:-standalone}" = "standalone" ]; then
  if example_run_self; then
    exit 0
  fi
  exit 1
fi
