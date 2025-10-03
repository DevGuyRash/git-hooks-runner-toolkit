#!/bin/sh
# Example hook part: apply metastore metadata manifests on post-update hooks.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
LIB_PATH="${SCRIPT_DIR}/../lib/common.sh"
if [ ! -f "${LIB_PATH}" ]; then
  printf '[hook-runner] ERROR: metadata-apply helper missing common library at %s\n' "${LIB_PATH}" >&2
  exit 1
fi
# shellcheck source=scripts/git-hooks/lib/common.sh
. "${LIB_PATH}"

if githooks_is_bare_repo; then
  githooks_log_info "metadata apply skipped for bare repository"
  exit 0
fi

REPO_ROOT=$(githooks_repo_top)
cd "${REPO_ROOT}" || exit 1

MANIFEST_REL=${METASTORE_FILE:-.metadata}
if [ -z "${MANIFEST_REL}" ]; then
  githooks_log_warn "metadata apply: METASTORE_FILE empty; skipping"
  exit 0
fi

case "${MANIFEST_REL}" in
  /*) MANIFEST_PATH=${MANIFEST_REL} ;;
  *) MANIFEST_PATH="${REPO_ROOT%/}/${MANIFEST_REL}" ;;
esac

if [ ! -f "${MANIFEST_PATH}" ]; then
  githooks_log_info "metadata apply: manifest not found (${MANIFEST_PATH}); skipping"
  exit 0
fi

if ! command -v metastore >/dev/null 2>&1; then
  githooks_log_warn "metadata apply: optional tool 'metastore' missing; install to restore metadata"
  MARK_FILE=${GITHOOKS_METADATA_APPLY_MARK:-}
  if [ -n "${MARK_FILE}" ]; then
    case "${MARK_FILE}" in
      /*) ;;
      *) MARK_FILE="${REPO_ROOT%/}/${MARK_FILE}" ;;
    esac
    mkdir -p "$(dirname "${MARK_FILE}")"
    {
      printf 'hook=%s\n' "${GITHOOKS_HOOK_NAME:-unknown}"
      printf 'status=skipped-missing-metastore\n'
      printf 'manifest=%s\n' "${MANIFEST_PATH}"
    } >"${MARK_FILE}"
  fi
  exit 0
fi

set -- metastore -a -f "${MANIFEST_PATH}"
if [ -n "${METASTORE_APPLY_ARGS:-}" ]; then
  saved_ifs=$IFS
  IFS=' '
  set -f
  for extra_arg in ${METASTORE_APPLY_ARGS}; do
    set -- "$@" "${extra_arg}"
  done
  set +f
  IFS=$saved_ifs
fi
set -- "$@" "${REPO_ROOT}"

githooks_log_info "metadata apply: running $*"
if ! "$@"; then
  status=$?
  githooks_log_error "metadata apply: metastore exited with ${status}"
  exit "${status}"
fi

githooks_log_info "metadata apply: manifest applied from ${MANIFEST_PATH}"

MARK_FILE=${GITHOOKS_METADATA_APPLY_MARK:-}
if [ -n "${MARK_FILE}" ]; then
  case "${MARK_FILE}" in
    /*) ;;
    *) MARK_FILE="${REPO_ROOT%/}/${MARK_FILE}" ;;
  esac
  mkdir -p "$(dirname "${MARK_FILE}")"
  {
    printf 'hook=%s\n' "${GITHOOKS_HOOK_NAME:-unknown}"
    printf 'status=applied\n'
    printf 'manifest=%s\n' "${MANIFEST_PATH}"
  } >"${MARK_FILE}"
fi

exit 0
