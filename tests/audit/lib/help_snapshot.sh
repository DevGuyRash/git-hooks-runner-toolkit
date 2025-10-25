#!/bin/sh
# Capture and verify githooks help surfaces for audit fixtures.

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)
PROJECT_ROOT=$(CDPATH='' cd "${SCRIPT_DIR}/../../.." && pwd -P)

REPO_HELPER="${PROJECT_ROOT}/tests/helpers/git_repo.sh"
CLI_ENTRY="${PROJECT_ROOT}/install.sh"
FIXTURE_DIR="${PROJECT_ROOT}/tests/audit/output/help"

if [ ! -f "${CLI_ENTRY}" ]; then
  printf '%s\n' "help-snapshot: missing CLI entry at ${CLI_ENTRY}" >&2
  exit 1
fi

if [ ! -f "${REPO_HELPER}" ]; then
  printf '%s\n' "help-snapshot: missing repository helper at ${REPO_HELPER}" >&2
  exit 1
fi

# Ensure git repo helpers use project-relative roots even when invoked outside Bats.
GIT_REPO_PROJECT_ROOT="${PROJECT_ROOT}"
export GIT_REPO_PROJECT_ROOT

# shellcheck disable=SC1090
. "${REPO_HELPER}"

HELP_SNAPSHOT_REPO_READY=0

help_snapshot_cleanup() {
  if [ "${HELP_SNAPSHOT_REPO_READY}" -eq 1 ]; then
    git_repo_teardown || true
    HELP_SNAPSHOT_REPO_READY=0
  fi
}

trap help_snapshot_cleanup EXIT INT TERM HUP

help_snapshot_require_repo() {
  if [ "${HELP_SNAPSHOT_REPO_READY}" -eq 1 ]; then
    return 0
  fi
  if ! git_repo_setup; then
    printf '%s\n' "help-snapshot: unable to set up sandbox repository" >&2
    exit 1
  fi
  if ! git_repo_init; then
    printf '%s\n' "help-snapshot: failed to initialise sandbox repository" >&2
    exit 1
  fi
  HELP_SNAPSHOT_REPO_READY=1
}

HELP_SNAPSHOT_DATA='global-flag|global-flag|--help
global-command|global-command|help
help-help|help-help|help help
install-flag|install-flag|install --help
install-help|install-help|install help
install-topic|install-topic|help install
install-ephemeral-flag|install-ephemeral-flag|install --mode ephemeral --help
stage-flag|stage-flag|stage --help
stage-command|stage-command|help stage
stage-help-topic|stage-help-topic|stage help
stage-add-flag|stage-add-flag|stage add --help
stage-add-topic|stage-add-topic|help stage add
stage-help-add|stage-help-add|stage --help add
stage-unstage-flag|stage-unstage-flag|stage unstage --help
stage-unstage-topic|stage-unstage-topic|help stage unstage
stage-help-unstage|stage-help-unstage|stage --help unstage
stage-remove-flag|stage-remove-flag|stage remove --help
stage-remove-topic|stage-remove-topic|help stage remove
stage-help-remove|stage-help-remove|stage --help remove
stage-list-flag|stage-list-flag|stage list --help
stage-list-topic|stage-list-topic|help stage list
stage-help-list|stage-help-list|stage --help list
hooks-flag|hooks-flag|hooks --help
hooks-command|hooks-command|help hooks
hooks-help-list|hooks-help-list|hooks --help list
hooks-list-flag|hooks-list-flag|hooks list --help
hooks-list-topic|hooks-list-topic|help hooks list
config-flag|config-flag|config --help
config-command|config-command|help config
config-help-show|config-help-show|config help show
config-show-flag|config-show-flag|config show --help
config-show-topic|config-show-topic|help config show
config-show-inline|config-show-inline|config show help
config-help-set|config-help-set|config help set
config-set-flag|config-set-flag|config set --help
config-set-topic|config-set-topic|help config set
config-set-inline|config-set-inline|config set help hooks-path
uninstall-flag|uninstall-flag|uninstall --help
uninstall-topic|uninstall-topic|help uninstall
legacy-init-flag|legacy-init-flag|init --help
legacy-add-flag|legacy-add-flag|add --help
legacy-remove-flag|legacy-remove-flag|remove --help'

help_snapshot_entries() {
  printf '%s\n' "${HELP_SNAPSHOT_DATA}"
}

help_snapshot_lookup() {
  _lookup_id=$1
  if [ -z "${_lookup_id}" ]; then
    return 1
  fi
  help_snapshot_entries | while IFS= read -r _snapshot_entry; do
    case "${_snapshot_entry}" in
      "${_lookup_id}|"*)
        printf '%s\n' "${_snapshot_entry}"
        return 0
        ;;
    esac
  done
  return 1
}

HELP_SNAPSHOT_ID=''
HELP_SNAPSHOT_FIXTURE=''
HELP_SNAPSHOT_COMMAND=''

help_snapshot_parse_entry() {
  _parse_entry=$1
  if [ -z "${_parse_entry}" ]; then
    return 1
  fi
  _old_ifs=${IFS}
  IFS='|'
  # shellcheck disable=SC2034
  read -r HELP_SNAPSHOT_ID HELP_SNAPSHOT_FIXTURE HELP_SNAPSHOT_COMMAND <<EOF
${_parse_entry}
EOF
  IFS=${_old_ifs}
  if [ -z "${HELP_SNAPSHOT_ID}" ] || [ -z "${HELP_SNAPSHOT_FIXTURE}" ]; then
    return 1
  fi
  return 0
}

help_snapshot_sanitize_stream() {
  _stream_path=$1
  if [ ! -s "${_stream_path}" ]; then
    return 0
  fi
  sed -e 's/\r$//' -e 's/[[:space:]]\+$//' "${_stream_path}"
}

help_snapshot_print_capture() {
  _command_display=$1
  _status_code=$2
  _stdout_path=$3
  _stderr_path=$4

  printf '# command\n'
  printf 'githooks'
  if [ -n "${_command_display}" ]; then
    printf ' %s' "${_command_display}"
  fi
  printf '\n'
  printf '# status\n'
  printf '%s\n' "${_status_code}"
  printf '# stdout\n'
  help_snapshot_sanitize_stream "${_stdout_path}"
  printf '# stderr\n'
  help_snapshot_sanitize_stream "${_stderr_path}"
}

help_snapshot_capture_surface() {
  _capture_id=$1
  _entry=$(help_snapshot_lookup "${_capture_id}" || true)
  if [ -z "${_entry}" ]; then
    printf '%s\n' "help-snapshot: unknown surface '${_capture_id}'" >&2
    return 1
  fi
  if ! help_snapshot_parse_entry "${_entry}"; then
    printf '%s\n' "help-snapshot: malformed entry for '${_capture_id}'" >&2
    return 1
  fi

  help_snapshot_require_repo

  _stdout_tmp=$(mktemp "${TMPDIR:-/tmp}/help-snapshot.stdout.XXXXXX") || {
    printf '%s\n' "help-snapshot: unable to create stdout temp file" >&2
    return 1
  }
  _stderr_tmp=$(mktemp "${TMPDIR:-/tmp}/help-snapshot.stderr.XXXXXX") || {
    rm -f "${_stdout_tmp}"
    printf '%s\n' "help-snapshot: unable to create stderr temp file" >&2
    return 1
  }

  _status=0
  set +e
  if [ -n "${HELP_SNAPSHOT_COMMAND}" ]; then
    set -f
    set -- ${HELP_SNAPSHOT_COMMAND}
    set +f
    git_repo_exec "${CLI_ENTRY}" "$@" >"${_stdout_tmp}" 2>"${_stderr_tmp}"
  else
    git_repo_exec "${CLI_ENTRY}" >"${_stdout_tmp}" 2>"${_stderr_tmp}"
  fi
  _status=$?
  set -e

  help_snapshot_print_capture "${HELP_SNAPSHOT_COMMAND}" "${_status}" "${_stdout_tmp}" "${_stderr_tmp}"

  rm -f "${_stdout_tmp}" "${_stderr_tmp}"

  return 0
}

help_snapshot_cmd_list() {
  help_snapshot_entries
}

help_snapshot_cmd_capture() {
  if [ "$#" -ne 1 ]; then
    printf '%s\n' "usage: $0 capture <surface-id>" >&2
    exit 1
  fi
  help_snapshot_capture_surface "$1"
}

help_snapshot_write_fixture() {
  _surface_id=$1
  _fixture_path=$2
  _fixture_tmp="${_fixture_path}.tmp"

  if ! help_snapshot_capture_surface "${_surface_id}" >"${_fixture_tmp}"; then
    rm -f "${_fixture_tmp}"
    return 1
  fi
  mv "${_fixture_tmp}" "${_fixture_path}"
  return 0
}

help_snapshot_unique_fixtures() {
  _filter_ids=$*
  help_snapshot_entries | while IFS= read -r _snapshot_entry; do
    if [ -n "${_filter_ids}" ]; then
      _include=0
      for _filter_id in ${_filter_ids}; do
        case "${_snapshot_entry}" in
          "${_filter_id}|"*)
            _include=1
            ;;
        esac
      done
      if [ "${_include}" -ne 1 ]; then
        continue
      fi
    fi
    help_snapshot_parse_entry "${_snapshot_entry}" || continue
    printf '%s|%s\n' "${HELP_SNAPSHOT_ID}" "${HELP_SNAPSHOT_FIXTURE}"
  done | awk -F '|' '!seen[$2]++ { print $1 "|" $2 }'
}

help_snapshot_cmd_update() {
  if [ ! -d "${FIXTURE_DIR}" ]; then
    if ! mkdir -p "${FIXTURE_DIR}"; then
      printf '%s\n' "help-snapshot: unable to create fixture directory ${FIXTURE_DIR}" >&2
      exit 1
    fi
  fi

  if [ "$#" -eq 0 ]; then
    help_snapshot_unique_fixtures | while IFS='|' read -r _surface_id _fixture_name; do
      _fixture_path="${FIXTURE_DIR}/${_fixture_name}.txt"
      if ! help_snapshot_write_fixture "${_surface_id}" "${_fixture_path}"; then
        printf '%s\n' "help-snapshot: failed to write fixture for ${_surface_id}" >&2
        exit 1
      fi
    done
    return 0
  fi

  help_snapshot_unique_fixtures "$@" | while IFS='|' read -r _surface_id _fixture_name; do
    _fixture_path="${FIXTURE_DIR}/${_fixture_name}.txt"
    if ! help_snapshot_write_fixture "${_surface_id}" "${_fixture_path}"; then
      printf '%s\n' "help-snapshot: failed to write fixture for ${_surface_id}" >&2
      exit 1
    fi
  done
}

help_snapshot_usage() {
  cat <<'USAGE'
usage: help_snapshot.sh <command> [args]

Commands:
  list                  List help surfaces and associated fixtures
  capture <id>          Capture a specific surface to stdout (sanitised)
  update [ids...]       Refresh fixtures for all or selected surfaces
USAGE
}

if [ "$#" -eq 0 ]; then
  help_snapshot_usage >&2
  exit 1
fi

COMMAND=$1
shift

case "${COMMAND}" in
  list)
    help_snapshot_cmd_list "$@"
    ;;
  capture)
    help_snapshot_cmd_capture "$@"
    ;;
  update)
    help_snapshot_cmd_update "$@"
    ;;
  *)
    help_snapshot_usage >&2
    exit 1
    ;;
esac
