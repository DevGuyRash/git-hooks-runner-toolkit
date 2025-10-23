#!/bin/sh
# githooks-stage: pre-commit
# Example hook part: evaluate staged paths against YAML/JSON config and run actions.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
LIB_COMMON="${SCRIPT_DIR}/../lib/common.sh"
LIB_WATCH="${SCRIPT_DIR}/../lib/watch-configured-actions.sh"

if [ ! -f "${LIB_COMMON}" ] || [ ! -f "${LIB_WATCH}" ]; then
  printf '[hook-runner] ERROR: watch-configured-actions pre-commit missing required libraries\n' >&2
  exit 1
fi
# shellcheck source=../lib/common.sh
. "${LIB_COMMON}"
# shellcheck source=../lib/watch-configured-actions.sh
. "${LIB_WATCH}"

if githooks_is_bare_repo; then
  githooks_log_info "watch-configured-actions pre-commit not applicable to bare repositories"
  exit 0
fi

HOOK_NAME=${GITHOOKS_HOOK_NAME:-$(basename "${0:-watch-configured-actions-pre-commit}")}

: "${WATCH_INLINE_RULES_DEFAULT:=}"

watch_actions_run_pre_commit "${HOOK_NAME}" "$@"
exit $?
