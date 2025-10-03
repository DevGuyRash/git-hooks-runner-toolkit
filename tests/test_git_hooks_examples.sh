#!/bin/sh
# TAP aggregator for git hook example tests using modular per-example scripts.

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
EXAMPLE_TEST_DIR="${TEST_DIR}/examples"
COMMON_LIB="${EXAMPLE_TEST_DIR}/common.sh"

if [ ! -f "${COMMON_LIB}" ]; then
  printf 'Bail out! missing common example library at %s\n' "${COMMON_LIB}" >&2
  exit 127
fi

# shellcheck source=tests/examples/common.sh
. "${COMMON_LIB}"

example_tests_init

EXAMPLE_TEST_RUN_MODE=aggregate

for script in "${EXAMPLE_TEST_DIR}"/*.sh; do
  case $(basename "${script}") in
    common.sh) continue ;;
  esac
  if [ ! -f "${script}" ]; then
    continue
  fi
  # shellcheck source=tests/examples/dependency_sync.sh
  EXAMPLE_CURRENT_SCRIPT="${script}"
  . "${script}"
done

unset EXAMPLE_CURRENT_SCRIPT

tap_plan "$(example_registered_count)"
example_run_registered_tests
if example_finish; then
  exit 0
fi
exit 1
