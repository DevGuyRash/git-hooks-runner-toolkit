#!/bin/sh
# Universal Git hook runner that dispatches to per-hook parts in lexical order.
# Relies on scripts/git-hooks/lib/common.sh (copied alongside runner at install time).

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
LIB_PATH="${SCRIPT_DIR}/lib/common.sh"
if [ ! -f "${LIB_PATH}" ]; then
  printf '[hook-runner] ERROR: missing shared library at %s\n' "${LIB_PATH}" >&2
  exit 1
fi
# shellcheck source=scripts/git-hooks/lib/common.sh
. "${LIB_PATH}"

if [ "$#" -lt 1 ]; then
  githooks_die "runner invoked without stub path"
fi

HOOK_STUB=$1
shift

if [ "$#" -ge 1 ]; then
  HOOK_NAME=$1
  shift
else
  HOOK_NAME=$(basename "${HOOK_STUB}")
fi

if [ -z "${HOOK_NAME}" ]; then
  githooks_die "unable to determine hook name"
fi

STDIN_FILE=$(mktemp "${TMPDIR:-/tmp}/githooks-stdin.XXXXXX") || exit 1
runner_cleanup() {
  rm -f "${STDIN_FILE}"
}
trap runner_cleanup EXIT HUP INT TERM

cat >"${STDIN_FILE}" || true

export GITHOOKS_HOOK_NAME="${HOOK_NAME}"
export GITHOOKS_HOOK_PATH="${HOOK_STUB}"
export GITHOOKS_STDIN_FILE="${STDIN_FILE}"

if githooks_is_bare_repo; then
  export GITHOOKS_REPO_MODE="bare"
  export GITHOOKS_REPO_ROOT="$(githooks_repo_git_dir)"
else
  export GITHOOKS_REPO_MODE="worktree"
  export GITHOOKS_REPO_ROOT="$(githooks_repo_top)"
fi

PARTS_FILE=$(mktemp "${TMPDIR:-/tmp}/githooks-parts.XXXXXX") || exit 1
githooks_list_parts "${HOOK_NAME}" >"${PARTS_FILE}"

PART_COUNT=0
while IFS= read -r runner_part_path; do
  [ -n "${runner_part_path}" ] || continue
  PART_COUNT=$((PART_COUNT + 1))
done <"${PARTS_FILE}"

if [ "${PART_COUNT}" -eq 0 ]; then
  githooks_log_info "no parts registered for ${HOOK_NAME}; exiting"
  rm -f "${PARTS_FILE}"
  exit 0
fi

githooks_log_info "running ${PART_COUNT} part(s) for ${HOOK_NAME}"

runner_status=0
while IFS= read -r runner_part_path; do
  [ -n "${runner_part_path}" ] || continue
  githooks_log_info "→ ${HOOK_NAME}: $(basename "${runner_part_path}")"
  runner_status=0
  "${runner_part_path}" "$@" <"${STDIN_FILE}" || runner_status=$?
  if [ "${runner_status}" -ne 0 ]; then
    githooks_log_error "part failed (${runner_part_path}); exit ${runner_status}"
    rm -f "${PARTS_FILE}"
    exit "${runner_status}"
  fi
done <"${PARTS_FILE}"

rm -f "${PARTS_FILE}"
githooks_log_info "completed ${HOOK_NAME} with ${PART_COUNT} part(s)"
exit 0
