#!/bin/sh
# Enumerate toolkit CLI permutations and emit NDJSON case records.

# shellcheck shell=sh

set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)
PROJECT_ROOT=$(CDPATH='' cd "${SCRIPT_DIR}/../.." && pwd -P)

JSON_HELPER="${SCRIPT_DIR}/lib/json_emit.sh"
REPO_HELPER="${PROJECT_ROOT}/tests/helpers/git_repo.sh"

if [ ! -f "${JSON_HELPER}" ]; then
  printf '%s\n' "cli-matrix: missing JSON helper at ${JSON_HELPER}" >&2
  exit 1
fi
if [ ! -f "${REPO_HELPER}" ]; then
  printf '%s\n' "cli-matrix: missing repository helper at ${REPO_HELPER}" >&2
  exit 1
fi

# Ensure git repo helpers resolve project-relative paths even outside Bats.
GIT_REPO_PROJECT_ROOT="${PROJECT_ROOT}"
export GIT_REPO_PROJECT_ROOT

# shellcheck disable=SC1090
. "${JSON_HELPER}"
# shellcheck disable=SC1090
. "${REPO_HELPER}"

export GITHOOKS_SILENCE_COMPAT_WARN=1

# Reset errexit that may be enabled by sourced helpers; command failures are
# captured per-case instead of aborting the matrix run.
set +e

OUTPUT_DIR="${SCRIPT_DIR}/output"
if [ ! -d "${OUTPUT_DIR}" ]; then
  mkdir -p "${OUTPUT_DIR}" || {
    printf '%s\n' "cli-matrix: failed to create ${OUTPUT_DIR}" >&2
    exit 1
  }
fi

if [ -n "${MATRIX_OUTPUT:-}" ]; then
  MATRIX_FILE="${MATRIX_OUTPUT}"
else
  MATRIX_FILE="${OUTPUT_DIR}/cli-matrix.ndjson"
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/cli-matrix.XXXXXX") || {
  printf '%s\n' "cli-matrix: unable to create temp directory" >&2
  exit 1
}

cleanup() {
  if [ -d "${TMP_ROOT:-}" ]; then
    rm -rf "${TMP_ROOT}"
  fi
}
trap cleanup EXIT INT TERM HUP

: >"${MATRIX_FILE}" || {
  printf '%s\n' "cli-matrix: cannot write to ${MATRIX_FILE}" >&2
  exit 1
}

CLI_ENTRY="${PROJECT_ROOT}/install.sh"

case_note() {
  _matrix_note=${1-}
  [ -n "${_matrix_note}" ] || return 0
  if [ -z "${CASE_NOTES}" ]; then
    CASE_NOTES="${_matrix_note}"
    return 0
  fi
  _matrix_nl=$(printf '\n_')
  _matrix_saved_ifs=${IFS}
  IFS=${_matrix_nl%_}
  set -f
  for _matrix_existing in ${CASE_NOTES}; do
    if [ "${_matrix_existing}" = "${_matrix_note}" ]; then
      set +f
      IFS=${_matrix_saved_ifs}
      return 0
    fi
  done
  set +f
  IFS=${_matrix_saved_ifs}
  CASE_NOTES="${CASE_NOTES}\n${_matrix_note}"
}

matrix_tmp() {
  mktemp "${TMP_ROOT}/cli-matrix.XXXXXX"
}

matrix_escape_sed() {
  if [ "$#" -ne 1 ]; then
    return 0
  fi
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/[&|]/\\&/g'
}

matrix_replace_path() {
  if [ "$#" -ne 3 ]; then
    return 0
  fi
  replace_file=$1
  replace_from=$2
  replace_to=$3
  if [ -z "${replace_from}" ] || [ ! -f "${replace_file}" ]; then
    return 0
  fi
  replace_escaped=$(matrix_escape_sed "${replace_from}")
  replace_tmp=$(matrix_tmp)
  sed "s|${replace_escaped}|${replace_to}|g" "${replace_file}" >"${replace_tmp}"
  mv "${replace_tmp}" "${replace_file}"
}

matrix_sanitize_file() {
  if [ "$#" -ne 1 ]; then
    return 0
  fi
  sanitize_target=$1
  if [ ! -f "${sanitize_target}" ]; then
    return 0
  fi
  matrix_replace_path "${sanitize_target}" "${GIT_REPO_WORK:-}" '<repo>'
  matrix_replace_path "${sanitize_target}" "${GIT_REPO_REMOTE:-}" '<remote>'
  matrix_replace_path "${sanitize_target}" "${GIT_REPO_HOME:-}" '<home>'
  matrix_replace_path "${sanitize_target}" "${GIT_REPO_BASE:-}" '<sandbox>'
  matrix_replace_path "${sanitize_target}" "${TMP_ROOT:-}" '<tmp-root>'
}

sandbox_cli_exec() {
  git_repo_exec "${CLI_ENTRY}" "$@"
}

sandbox_cli_quiet() {
  _matrix_out=$(matrix_tmp)
  _matrix_err=$(matrix_tmp)
  sandbox_cli_exec "$@" >"${_matrix_out}" 2>"${_matrix_err}"
  _matrix_status=$?
  rm -f "${_matrix_out}" "${_matrix_err}"
  return ${_matrix_status}
}

matrix_crc() {
  _matrix_file=$1
  if [ ! -f "${_matrix_file}" ]; then
    printf '%s' 'absent'
    return 0
  fi
  _matrix_raw=$(cksum <"${_matrix_file}" 2>/dev/null || printf '')
  if [ -z "${_matrix_raw}" ]; then
    printf '%s' 'error'
    return 0
  fi
  _matrix_crc=${_matrix_raw%% *}
  _matrix_rest=${_matrix_raw#* }
  _matrix_len=${_matrix_rest%% *}
  printf '%s:%s' "${_matrix_crc}" "${_matrix_len}"
}

matrix_args_to_lines() {
  if [ "$#" -eq 0 ]; then
    printf '%s' ''
    return 0
  fi
  _matrix_args=''
  for _matrix_arg in "$@"; do
    if [ -z "${_matrix_args}" ]; then
      _matrix_args="${_matrix_arg}"
    else
      _matrix_args="${_matrix_args}\n${_matrix_arg}"
    fi
  done
  printf '%s' "${_matrix_args}"
}

matrix_trim() {
  printf '%s' "${1-}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

matrix_capture_hooks_path() {
  if [ -z "${GIT_REPO_WORK:-}" ] || [ ! -d "${GIT_REPO_WORK}" ]; then
    printf '%s' '<unset>'
    return 0
  fi
  _matrix_path=$(git_repo_exec git config --path --get core.hooksPath 2>/dev/null || true)
  _matrix_path=$(matrix_trim "${_matrix_path}")
  if [ -z "${_matrix_path}" ]; then
    printf '%s' '<unset>'
  else
    printf '%s' "${_matrix_path}"
  fi
}

matrix_capture_manifest_value() {
  if [ -z "${GIT_REPO_WORK:-}" ]; then
    return 1
  fi
  git_repo_manifest_value "$1"
}

matrix_capture_overlay_roots() {
  if [ -z "${GIT_REPO_WORK:-}" ] || [ -z "${GIT_REPO_HOME:-}" ]; then
    printf '%s' ''
    return 0
  fi
  git_repo_overlay_roots || true
}

matrix_capture_overlay_log() {
  if [ -z "${GIT_REPO_WORK:-}" ] || [ -z "${GIT_REPO_HOME:-}" ]; then
    printf '%s' ''
    return 0
  fi
  git_repo_overlay_log || true
}

matrix_capture_precedence() {
  matrix_capture_manifest_value PRECEDENCE_MODE || true
}

tag_args_for_notes() {
  prev_mode=0
  prev_overlay=0
  prev_hooks=0
  for tag_arg in "$@"; do
    if [ ${prev_mode} -eq 1 ]; then
      case_note "mode:${tag_arg}"
      prev_mode=0
      continue
    fi
    if [ ${prev_overlay} -eq 1 ]; then
      case_note "overlay:${tag_arg}"
      prev_overlay=0
      continue
    fi
    if [ ${prev_hooks} -eq 1 ]; then
      case_note "hooks:${tag_arg}"
      prev_hooks=0
      continue
    fi
    case "${tag_arg}" in
      --mode)
        prev_mode=1
        ;;
      --mode=*)
        case_note "mode:${tag_arg#*=}"
        ;;
      --overlay)
        prev_overlay=1
        ;;
      --overlay=*)
        case_note "overlay:${tag_arg#*=}"
        ;;
      --hooks|-H)
        prev_hooks=1
        ;;
      --hooks=*|-H=*)
        case_note "hooks:${tag_arg#*=}"
        ;;
    esac
  done
  if [ ${prev_mode} -eq 1 ]; then
    case_note 'mode:<missing>'
  fi
  if [ ${prev_overlay} -eq 1 ]; then
    case_note 'overlay:<missing>'
  fi
  if [ ${prev_hooks} -eq 1 ]; then
    case_note 'hooks:<missing>'
  fi
  for tag_arg in "$@"; do
    case "${tag_arg}" in
      --dry-run|-n)
        case_note 'dry-run'
        ;;
      --all-hooks|--all|-A)
        case_note 'all-hooks'
        ;;
      --force|-f)
        case_note 'force'
        ;;
      --help|-h)
        case_note 'help-flag'
        ;;
      help)
        case_note 'help-subcommand'
        ;;
      --version|-V)
        case_note 'version'
        ;;
    esac
  done
}

prepare_scenario() {
  _matrix_scenario=${1-}
  case "${_matrix_scenario}" in
    fresh)
      return 0
      ;;
    standard-installed)
      if ! sandbox_cli_quiet install; then
        case_note 'setup-failed:install'
        return 1
      fi
      return 0
      ;;
    staged-examples)
      if ! prepare_scenario standard-installed; then
        return 1
      fi
      if ! sandbox_cli_quiet stage add examples --hook pre-commit; then
        case_note 'setup-failed:stage-add'
        return 1
      fi
      return 0
      ;;
    ephemeral-installed)
      if ! sandbox_cli_quiet install --mode ephemeral; then
        case_note 'setup-failed:install-ephemeral'
        return 1
      fi
      return 0
      ;;
    standard-installed-force)
      if ! prepare_scenario standard-installed; then
        return 1
      fi
      return 0
      ;;
    *)
      case_note "unknown-scenario:${_matrix_scenario}"
      return 1
      ;;
  esac
}

run_case() {
  case_id=$1
  scenario=$2
  shift 2

  CASE_NOTES=''
  stdout_file=$(matrix_tmp)
  stderr_file=$(matrix_tmp)

  args_lines=$(matrix_args_to_lines "$@")
  hooks_path='<unset>'
  overlay_lines=''
  precedence_mode=''
  exit_code=0
  skip_command=0

  printf '%s\n' "cli-matrix: ${case_id}" >&2

  if ! git_repo_setup; then
    case_note 'setup-failed:sandbox'
    exit_code=125
    skip_command=1
  else
    if ! git_repo_init; then
      case_note 'setup-failed:init'
      exit_code=125
      skip_command=1
    fi
  fi

  if [ ${skip_command} -eq 0 ]; then
    if ! prepare_scenario "${scenario}"; then
      skip_command=1
      exit_code=125
    fi
  fi

  if [ ${skip_command} -eq 0 ]; then
    sandbox_cli_exec "$@" >"${stdout_file}" 2>"${stderr_file}"
    exit_code=$?
  fi

  if [ ${skip_command} -eq 1 ]; then
    case_note 'execution-skipped'
  fi

  tag_args_for_notes "$@"

  if [ ${exit_code} -ne 0 ]; then
    case_note "exit-nonzero:${exit_code}"
  fi

  hooks_path=$(matrix_capture_hooks_path)
  overlay_lines=$(matrix_capture_overlay_roots)
  overlay_log=$(matrix_capture_overlay_log)
  precedence_mode=$(matrix_capture_precedence)
  if [ -n "${precedence_mode}" ]; then
    case_note "precedence:${precedence_mode}"
  fi
  overlay_truncated=0
  if [ -n "${overlay_log}" ]; then
    _overlay_log_issue=0
    _overlay_log_nl=$(printf '\n_')
    _overlay_log_saved_ifs=${IFS}
    IFS=${_overlay_log_nl%_}
    set -f
    for _overlay_log_line in ${overlay_log}; do
      [ -n "${_overlay_log_line}" ] || continue
      case "${_overlay_log_line}" in
        *'INFO:   ['*)
          case "${_overlay_log_line}" in
            *'] /'*)
              ;;
            *)
              _overlay_log_issue=1
              ;;
          esac
          ;;
      esac
    done
    set +f
    IFS=${_overlay_log_saved_ifs}
    if [ ${_overlay_log_issue} -eq 1 ]; then
      overlay_truncated=1
    fi
  elif [ -n "${overlay_lines}" ]; then
    case_note 'overlay-log-empty'
  fi
  if [ ${overlay_truncated} -eq 1 ]; then
    case_note 'overlay-truncated'
  fi

  matrix_sanitize_file "${stdout_file}"
  matrix_sanitize_file "${stderr_file}"

  stdout_crc=$(matrix_crc "${stdout_file}")
  stderr_crc=$(matrix_crc "${stderr_file}")

  json_emit_case_record \
    "${case_id}" \
    'githooks' \
    "${args_lines}" \
    "${exit_code}" \
    "${stdout_crc}" \
    "${stderr_crc}" \
    "${hooks_path}" \
    "${overlay_lines}" \
    "${CASE_NOTES}" >>"${MATRIX_FILE}"

  rm -f "${stdout_file}" "${stderr_file}"
  if [ -n "${GIT_REPO_BASE:-}" ]; then
    git_repo_teardown
  fi
  unset GIT_REPO_BASE GIT_REPO_WORK GIT_REPO_REMOTE GIT_REPO_HOME
}

main() {
  run_case root-default fresh
  run_case root-help-flag fresh --help
  run_case root-help-short fresh -h
  run_case root-help-command fresh help
  run_case root-help-install fresh help install
  run_case root-version fresh --version

  run_case install-default fresh install
  run_case install-help-flag fresh install --help
  run_case install-help-subcommand fresh install help
  run_case install-dry-run fresh install --dry-run
  run_case install-hooks fresh install --hooks pre-commit,post-merge
  run_case install-all-hooks fresh install --all-hooks
  run_case install-force standard-installed-force install --force

  run_case install-ephemeral fresh install --mode ephemeral
  run_case install-ephemeral-overlay-versioned fresh install --mode ephemeral --overlay versioned-first
  run_case install-ephemeral-overlay-merge fresh install --mode ephemeral --overlay merge
  run_case install-ephemeral-hooks fresh install --mode ephemeral --hooks pre-commit
  run_case install-ephemeral-flag fresh install --mode ephemeral --help
  run_case install-ephemeral-dry-run fresh install --mode ephemeral --dry-run

  run_case stage-default fresh stage
  run_case stage-help-flag fresh stage --help
  run_case stage-help fresh stage help
  run_case stage-help-add fresh stage help add
  run_case stage-flag-add fresh stage --help add
  run_case stage-flag-list fresh stage --help list
  run_case stage-flag-remove fresh stage --help remove
  run_case stage-flag-unstage fresh stage --help unstage
  run_case stage-add fresh stage add examples
  run_case stage-add-hook fresh stage add examples --hook pre-commit
  run_case stage-add-name fresh stage add examples --name dependency-sync
  run_case stage-add-dry-run fresh stage add examples --dry-run
  run_case stage-add-topic fresh help stage add
  run_case stage-list fresh stage list
  run_case stage-list-hook standard-installed stage list pre-commit
  run_case stage-list-flag fresh stage list --help
  run_case stage-list-topic fresh help stage list
  run_case stage-add-help fresh stage add --help
  run_case stage-unstage staged-examples stage unstage examples --hook pre-commit
  run_case stage-unstage-flag fresh stage unstage --help
  run_case stage-unstage-topic fresh help stage unstage
  run_case stage-remove-all staged-examples stage remove pre-commit --all
  run_case stage-remove-help fresh stage remove --help
  run_case stage-remove-topic fresh help stage remove

  run_case hooks-default standard-installed hooks
  run_case hooks-list-hook standard-installed hooks list pre-commit
  run_case hooks-help fresh hooks --help
  run_case hooks-flag-list fresh hooks --help list
  run_case hooks-help-list fresh hooks help list
  run_case hooks-list-help fresh hooks list --help
  run_case hooks-list-topic fresh help hooks list
  run_case help-hooks fresh help hooks

  run_case config-show standard-installed config show
  run_case config-show-help fresh config show --help
  run_case config-show-inline fresh config show help
  run_case config-set fresh config set hooks-path .githooks
  run_case config-set-help fresh config set --help
  run_case config-set-inline fresh config set help hooks-path
  run_case config-help fresh config --help
  run_case config-help-show fresh config help show
  run_case config-help-set fresh config help set
  run_case config-show-topic fresh help config show
  run_case config-set-topic fresh help config set

  run_case uninstall-default standard-installed uninstall
  run_case uninstall-dry-run standard-installed uninstall --dry-run
  run_case uninstall-help fresh uninstall --help
  run_case uninstall-ephemeral ephemeral-installed uninstall --mode ephemeral
  run_case uninstall-ephemeral-dry-run ephemeral-installed uninstall --mode ephemeral --dry-run

  run_case alias-init fresh init --dry-run
  run_case alias-init-flag fresh init --help
  run_case alias-add fresh add examples --hook pre-commit
  run_case alias-add-flag fresh add --help
  run_case alias-remove staged-examples remove pre-commit --all
  run_case alias-remove-flag fresh remove --help

  run_case help-stage fresh help stage
  run_case help-config fresh help config
  run_case help-uninstall fresh help uninstall
  run_case help-help fresh help help
}

main "$@"
