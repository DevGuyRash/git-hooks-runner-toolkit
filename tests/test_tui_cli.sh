#!/bin/sh
# TAP tests for the TUI wrapper.

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${TEST_DIR}/.." && pwd)
TUI="${REPO_ROOT}/tui/githooks-tui.sh"
INSTALLER="${REPO_ROOT}/install.sh"

if [ ! -x "${INSTALLER}" ]; then
  printf '1..0\n'
  printf '# Bail out! missing installer at %s\n' "${INSTALLER}" >&2
  exit 127
fi
if [ ! -x "${TUI}" ]; then
  printf '1..0\n'
  printf '# Bail out! missing TUI at %s\n' "${TUI}" >&2
  exit 127
fi

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

capture_output() {
  "$@" 2>/dev/null || return $?
}

test_help_output() {
  TEST_FAILURE_DIAG=''
  output=$(capture_output "${TUI}" --help) || {
    TEST_FAILURE_DIAG='failed to run TUI help'
    return 1
  }
  printf '%s' "$output" | grep -q 'Git Hooks Runner Toolkit - TUI' || {
    TEST_FAILURE_DIAG='help output missing expected header'
    return 1
  }
  printf '%s' "$output" | grep -q 'Usage:' || {
    TEST_FAILURE_DIAG='help output missing Usage section'
    return 1
  }
  return 0
}

test_version_matches_installer() {
  TEST_FAILURE_DIAG=''
  tui_version=$(capture_output "${TUI}" --version) || {
    TEST_FAILURE_DIAG='failed to run TUI --version'
    return 1
  }
  installer_version=$(capture_output "${INSTALLER}" -V) || {
    TEST_FAILURE_DIAG='failed to run install.sh -V'
    return 1
  }
  if [ "${tui_version}" != "${installer_version}" ]; then
    TEST_FAILURE_DIAG=$(printf 'version mismatch: tui=%s installer=%s' "${tui_version}" "${installer_version}")
    return 1
  fi
  return 0
}

test_menu_accepts_carriage_return() {
  TEST_FAILURE_DIAG=''
  output=$(printf '9\r\n' | "${TUI}" 2>/dev/null || true)
  printf '%s' "$output" | grep -q 'Goodbye.' || {
    TEST_FAILURE_DIAG='menu did not accept carriage-return input to exit'
    return 1
  }
  return 0
}

test_help_pages_do_not_exit_early() {
  TEST_FAILURE_DIAG=''
  output=$(printf '7\n1\n\n8\n9\n' | "${TUI}" 2>/dev/null || true)
  printf '%s' "$output" | grep -q 'Quick start (beginner)' || {
    TEST_FAILURE_DIAG='quick start help page did not render'
    return 1
  }
  printf '%s' "$output" | grep -q 'Goodbye.' || {
    TEST_FAILURE_DIAG='TUI did not return to main menu and exit cleanly'
    return 1
  }
  return 0
}

test_tui_targets_cwd_repo() {
  TEST_FAILURE_DIAG=''
  base_tmp=${TMPDIR:-/tmp}
  sandbox=$(mktemp -d "${base_tmp%/}/tui-target.XXXXXX") || {
    TEST_FAILURE_DIAG='failed to create sandbox'
    return 1
  }
  repo_dir="${sandbox}/repo"
  home_dir="${sandbox}/home"
  mkdir -p "${repo_dir}" "${home_dir}"

  if ! git -C "${repo_dir}" init -q; then
    TEST_FAILURE_DIAG='git init failed for sandbox'
    rm -rf "${sandbox}"
    return 1
  fi
  git -C "${repo_dir}" config user.name 'TUI Tester'
  git -C "${repo_dir}" config user.email 'tui@example.invalid'
  printf 'seed\n' >"${repo_dir}/README.md"
  git -C "${repo_dir}" add README.md
  git -C "${repo_dir}" commit -q -m 'feat: seed repo'

  # Drive the install flow using defaults, then exit.
  tui_input=$(printf '1\n\n\n\n\n9\n')
  printf '%s' "${tui_input}" | (cd "${repo_dir}" && "${TUI}" >/dev/null 2>&1 || true)

  if [ ! -f "${repo_dir}/.git/hooks/_runner.sh" ]; then
    TEST_FAILURE_DIAG='expected runner to be installed in cwd target repo'
    rm -rf "${sandbox}"
    return 1
  fi

  rm -rf "${sandbox}"
  return 0
}

tap_plan 5
run_test 'TUI help output includes header and usage' test_help_output
run_test 'TUI --version matches installer version' test_version_matches_installer
run_test 'TUI accepts carriage-return input for menu selection' test_menu_accepts_carriage_return
run_test 'TUI help pages return to menus' test_help_pages_do_not_exit_early
run_test 'TUI runs install commands in the current working directory' test_tui_targets_cwd_repo

if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
