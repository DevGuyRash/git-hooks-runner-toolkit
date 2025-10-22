#!/bin/sh
# Universal Git hook runner that dispatches to per-hook parts in lexical order.
# Relies on scripts/.githooks/lib/common.sh (copied alongside runner at install time).

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
LIB_PATH="${SCRIPT_DIR}/lib/common.sh"
if [ ! -f "${LIB_PATH}" ]; then
  printf '[hook-runner] ERROR: missing shared library at %s\n' "${LIB_PATH}" >&2
  exit 1
fi
# shellcheck source=scripts/.githooks/lib/common.sh
. "${LIB_PATH}"

OVERLAY_LIB_PATH="${SCRIPT_DIR}/lib/ephemeral_overlay.sh"
if [ -f "${OVERLAY_LIB_PATH}" ]; then
  # shellcheck source=lib/ephemeral_overlay.sh
  . "${OVERLAY_LIB_PATH}"
fi

if ! command -v ephemeral_root_dir >/dev/null 2>&1; then
  ephemeral_root_dir() {
    _runner_git_dir=$(githooks_repo_git_dir)
    printf '%s/.githooks\n' "${_runner_git_dir%/}"
  }
fi

if ! command -v ephemeral_precedence_mode >/dev/null 2>&1; then
  ephemeral_precedence_mode() {
    if [ -n "${GITHOOKS_EPHEMERAL_PRECEDENCE:-}" ]; then
      printf '%s\n' "${GITHOOKS_EPHEMERAL_PRECEDENCE}"
      return 0
    fi
    _runner_precedence_cfg=$(git config --local --get githooks.ephemeral.precedence 2>/dev/null || true)
    if [ -n "${_runner_precedence_cfg}" ]; then
      printf '%s\n' "${_runner_precedence_cfg}"
      return 0
    fi
    printf '%s\n' 'ephemeral-first'
  }
fi

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
PART_COUNT=0

runner_record_part() {
  _runner_record_root=$1
  _runner_record_part=$2
  if [ -z "${_runner_record_part}" ]; then
    return 0
  fi
  printf '%s\t%s\n' "${_runner_record_root}" "${_runner_record_part}" >>"${PARTS_FILE}"
  PART_COUNT=$((PART_COUNT + 1))
}

RUNNER_OVERLAY_ROOTS=""
RUNNER_USING_OVERLAY=0
if command -v ephemeral_overlay_resolve_roots >/dev/null 2>&1; then
  RUNNER_OVERLAY_ROOTS=$(ephemeral_overlay_resolve_roots 2>/dev/null || true)
  if [ -n "${RUNNER_OVERLAY_ROOTS}" ]; then
    RUNNER_USING_OVERLAY=1
    RUNNER_ROOTS_FILE=$(mktemp "${TMPDIR:-/tmp}/githooks-roots.XXXXXX") || exit 1
    printf '%s\n' "${RUNNER_OVERLAY_ROOTS}" >"${RUNNER_ROOTS_FILE}"
    RUNNER_ROOT_INDEX=0
    while IFS= read -r runner_overlay_root; do
      [ -n "${runner_overlay_root}" ] || continue
      RUNNER_ROOT_INDEX=$((RUNNER_ROOT_INDEX + 1))
      githooks_log_info "overlay root [${RUNNER_ROOT_INDEX}]: ${runner_overlay_root}"
      runner_hook_dir="${runner_overlay_root%/}/${HOOK_NAME}.d"
      if [ ! -d "${runner_hook_dir}" ]; then
        continue
      fi
      RUNNER_PART_LIST=$(mktemp "${TMPDIR:-/tmp}/githooks-root-parts.XXXXXX") || exit 1
      LC_ALL=C find "${runner_hook_dir}" -mindepth 1 -maxdepth 1 -type f -name '*.sh' -perm -u+x -print 2>/dev/null | LC_ALL=C sort >"${RUNNER_PART_LIST}"
      while IFS= read -r runner_part_candidate; do
        [ -n "${runner_part_candidate}" ] || continue
        runner_record_part "${runner_overlay_root}" "${runner_part_candidate}"
      done <"${RUNNER_PART_LIST}"
      rm -f "${RUNNER_PART_LIST}"
    done <"${RUNNER_ROOTS_FILE}"
    rm -f "${RUNNER_ROOTS_FILE}"
  fi
fi

if [ "${RUNNER_USING_OVERLAY}" -eq 0 ]; then
  RUNNER_DEFAULT_ROOT=$(githooks_shared_root)
  RUNNER_PART_LIST=$(mktemp "${TMPDIR:-/tmp}/githooks-default-parts.XXXXXX") || exit 1
  githooks_list_parts "${HOOK_NAME}" >"${RUNNER_PART_LIST}"
  while IFS= read -r runner_part_path; do
    [ -n "${runner_part_path}" ] || continue
    runner_record_part "${RUNNER_DEFAULT_ROOT}" "${runner_part_path}"
  done <"${RUNNER_PART_LIST}"
  rm -f "${RUNNER_PART_LIST}"
fi

if [ "${PART_COUNT}" -eq 0 ]; then
  githooks_log_info "no parts registered for ${HOOK_NAME}; exiting"
  rm -f "${PARTS_FILE}"
  exit 0
fi

githooks_log_info "running ${PART_COUNT} part(s) for ${HOOK_NAME}"

RUNNER_TAB=$(printf '\t')
runner_status=0
while IFS="${RUNNER_TAB}" read -r runner_root_path runner_part_path; do
  [ -n "${runner_part_path}" ] || continue
  runner_status=0
  if [ "${RUNNER_USING_OVERLAY}" -eq 1 ]; then
    githooks_log_info "→ ${HOOK_NAME}: $(basename "${runner_part_path}") [root: ${runner_root_path}]"
  else
    githooks_log_info "→ ${HOOK_NAME}: $(basename "${runner_part_path}")"
  fi
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
