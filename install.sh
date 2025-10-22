#!/bin/sh
# Installer for git hook runner toolkit. Creates shared runner, library, and
# stub dispatchers for the configured hook list using POSIX-compliant sh.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
LIB_PATH="${SCRIPT_DIR}/lib/common.sh"
if [ ! -f "${LIB_PATH}" ]; then
  printf '[hook-runner] ERROR: missing shared library at %s\n' "${LIB_PATH}" >&2
  exit 1
fi
. "${LIB_PATH}"

CLI_ARGS_LIB="${SCRIPT_DIR}/lib/cli_args.sh"
if [ ! -f "${CLI_ARGS_LIB}" ]; then
  printf '[hook-runner] ERROR: missing CLI helper at %s\n' "${CLI_ARGS_LIB}" >&2
  exit 1
fi
. "${CLI_ARGS_LIB}"

EPHEMERAL_LIB="${SCRIPT_DIR}/lib/ephemeral_lifecycle.sh"
if [ ! -f "${EPHEMERAL_LIB}" ]; then
  printf '[hook-runner] ERROR: missing ephemeral lifecycle library at %s\n' "${EPHEMERAL_LIB}" >&2
  exit 1
fi
. "${EPHEMERAL_LIB}"

EPHEMERAL_OVERLAY_LIB="${SCRIPT_DIR}/lib/ephemeral_overlay.sh"
if [ ! -f "${EPHEMERAL_OVERLAY_LIB}" ]; then
  printf '[hook-runner] ERROR: missing ephemeral overlay library at %s\n' "${EPHEMERAL_OVERLAY_LIB}" >&2
  exit 1
fi
. "${EPHEMERAL_OVERLAY_LIB}"

print_usage() {
  cat <<'HELP'
NAME
    githooks - Manage shared Git hook runners and composable hook parts.

SYNOPSIS
    githooks [GLOBAL OPTIONS] COMMAND [SUBCOMMAND] [ARGS]

DESCRIPTION
    The toolkit installs a central runner under .githooks/, arranges Git hook
    stubs to dispatch through it, and provides commands for staging, listing,
    and removing hook parts. Commands accept --dry-run so you can inspect
    planned actions before they modify the working tree.

    Ephemeral Mode keeps toolkit assets inside the repository's .git
    directory, letting you enable hooks without committing toolkit files.
    Combine it with overlay controls to layer local automation alongside any
    versioned hook directories. Use it when repository policy forbids tracked
    tooling: all requirements are met with a writable Git worktree and a
    POSIX-compliant shell. The companion guide at docs/ephemeral-mode.md covers
    prerequisites, install steps, precedence rules, and uninstall workflows.
    Use `githooks install --mode ephemeral --help` for CLI specifics and
    `githooks uninstall --mode ephemeral --dry-run` to preview manifest-guided
    cleanup before making changes.

GLOBAL OPTIONS
    -h, --help
        Show this overview or, when combined with a command, print its manual.

    -V, --version
        Display the toolkit version banner.

    -n, --dry-run
        Simulate filesystem changes, echoing the work that would be performed.

    --mode MODE
        Select installation mode. The default `standard` vendors files into
        .githooks/. Use `ephemeral` to install under .git/.githooks/ while
        leaving tracked files untouched; see docs/ephemeral-mode.md for details.

COMMAND OVERVIEW
    install
        Provision the runner, stubs, and default hook directories.

    stage
        Add, remove, or list staged hook parts sourced from directories.

    hooks
        Summarise hook coverage and staged parts across the repository.

    config
        Inspect Git configuration relevant to the runner, or update hooks-path.

    uninstall
        Remove managed stubs and shared runner artefacts.

    help
        Display contextual help for any command or subcommand.

LEGACY COMPATIBILITY
    init                Alias for install.
    add                 Alias for stage add.
    remove              Alias for stage remove.

SEE ALSO
    githooks help COMMAND
    githooks COMMAND help
    githooks COMMAND SUBCOMMAND --help
HELP
}

DEFAULT_HOOKS="post-merge post-rewrite post-checkout pre-commit prepare-commit-msg commit-msg post-commit pre-push"

ALL_HOOKS="applypatch-msg pre-applypatch post-applypatch pre-commit prepare-commit-msg commit-msg post-commit pre-merge-commit pre-rebase post-checkout post-merge post-rewrite pre-push pre-receive update post-receive post-update reference-transaction push-to-checkout proc-receive pre-auto-gc post-index-change sendemail-validate fsmonitor-watchman p4-changelist p4-prepare-changelist p4-post-changelist p4-pre-submit p4-post-submit"

MODE="install"
DRY_RUN=0
FORCE=0
HOOKS="${DEFAULT_HOOKS}"
USE_ALL=0
HOOKS_WERE_EXPLICIT=0
REQUEST_STAGE=0
REQUEST_UNINSTALL=0

CLI_INSTALL_MODE="standard"

TOOLKIT_VERSION="${TOOLKIT_VERSION:-0.3.0}"
COMPAT_WARNED=0
STAGE_LIST_HEADER_SHOWN=0

STAGE_SOURCES_ORDERED=""
STAGE_HOOK_FILTERS_ORDERED=""
STAGE_NAME_FILTERS_ORDERED=""
STAGE_ORDER_STRATEGY="source"
STAGE_SUMMARY=0
STAGE_LEGACY_USED=0
STAGE_RUNNER_READY=0
STAGE_COPY_COUNT=0
STAGE_SKIP_IDENTICAL=0
STAGE_SKIPPED_FILES=0
STAGE_DETECTED_HOOKS=""
STAGE_DETECTED_SOURCE="none"
STAGE_PLAN_FILE=""
STAGE_PLAN_COUNT=0
STAGE_PLANNED_DESTS=""

parse_hook_list() {
  if [ "$#" -ne 1 ]; then
    githooks_die "--hooks requires an argument"
  fi
  _raw_hooks=$1
  HOOKS=""
  _saved_ifs=$IFS
  IFS=','
  set -f
  set -- ${_raw_hooks}
  set +f
  IFS=${_saved_ifs}
  for _hook_item in "$@"; do
    _trimmed=$(printf '%s' "${_hook_item}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [ -n "${_trimmed}" ]; then
      if [ -z "${HOOKS}" ]; then
        HOOKS="${_trimmed}"
      else
        HOOKS="${HOOKS} ${_trimmed}"
      fi
    fi
  done
  if [ -z "${HOOKS}" ]; then
    githooks_die "--hooks requires at least one hook name"
  fi
}

log_action() {
  githooks_log_info "$1"
}

maybe_run() {
  maybe_description=$1
  shift
  if [ "${DRY_RUN}" -eq 1 ]; then
    log_action "DRY-RUN: ${maybe_description}"
    return 0
  fi
  log_action "${maybe_description}"
  "$@"
}

ensure_parent_dir() {
  ensure_path=$1
  ensure_dir=$(dirname "${ensure_path}")
  if [ "${DRY_RUN}" -eq 1 ]; then
    log_action "DRY-RUN: ensure directory ${ensure_dir}"
    return 0
  fi
  githooks_mkdir_p "${ensure_dir}"
}

install_runner() {
  maybe_run "create shared directory ${shared_root}" githooks_mkdir_p "${shared_root}"
  maybe_run "create library directory ${shared_root%/}/lib" githooks_mkdir_p "${shared_root%/}/lib"
  maybe_run "copy runner to ${runner_target}" githooks_copy_file "${SCRIPT_DIR}/_runner.sh" "${runner_target}"
  maybe_run "copy shared library to ${lib_target}" githooks_copy_file "${SCRIPT_DIR}/lib/common.sh" "${lib_target}"
  maybe_run "chmod runner ${runner_target}" githooks_chmod 755 "${runner_target}"
}

write_stub() {
  stub_hook=$1
  stub_path="${hooks_root%/}/${stub_hook}"
  if [ -e "${stub_path}" ] && [ "${FORCE}" -eq 0 ]; then
    githooks_log_warn "stub exists for ${stub_hook}; use --force to overwrite"
    return 0
  fi
  ensure_parent_dir "${stub_path}"
  if [ "${DRY_RUN}" -eq 1 ]; then
    return 0
  fi
  tmp_stub="${stub_path}.tmp"
  githooks_stub_body "${stub_runner}" "${stub_hook}" >"${tmp_stub}"
  mv "${tmp_stub}" "${stub_path}"
  githooks_chmod 755 "${stub_path}"
}

uninstall_stub() {
  unstub_hook=$1
  stub_path="${hooks_root%/}/${unstub_hook}"
  if [ ! -f "${stub_path}" ]; then
    return 0
  fi
  if ! grep -q 'generated by .githooks-runner' "${stub_path}" 2>/dev/null; then
    githooks_log_warn "skipping ${unstub_hook}; not managed by runner"
    return 0
  fi
  if [ "${DRY_RUN}" -eq 1 ]; then
    log_action "DRY-RUN: remove stub ${stub_path}"
    return 0
  fi
  rm -f "${stub_path}"
  githooks_log_info "removed ${stub_path}"
}

create_parts_dir() {
  parts_hook=$1
  parts_dir="${shared_root%/}/${parts_hook}.d"
  if [ "${DRY_RUN}" -eq 1 ]; then
    log_action "DRY-RUN: ensure parts directory ${parts_dir}"
    return 0
  fi
  githooks_mkdir_p "${parts_dir}"
}

remove_runner_files() {
  runner_source="${SCRIPT_DIR%/}/_runner.sh"
  lib_source="${SCRIPT_DIR%/}/lib/common.sh"
  planned_removal=0
  performed_removal=0

  if [ -f "${runner_target}" ]; then
    if [ -f "${runner_source}" ] && [ "${runner_target}" -ef "${runner_source}" ]; then
      githooks_log_info "skip removing ${runner_target}; shared with installer source"
    else
      if [ "${DRY_RUN}" -eq 1 ]; then
        log_action "DRY-RUN: remove ${runner_target}"
        planned_removal=1
      else
        rm -f "${runner_target}"
        performed_removal=1
        githooks_log_info "removed ${runner_target}"
      fi
    fi
  fi

  if [ -f "${lib_target}" ]; then
    if [ -f "${lib_source}" ] && [ "${lib_target}" -ef "${lib_source}" ]; then
      githooks_log_info "skip removing ${lib_target}; shared with installer source"
    else
      if [ "${DRY_RUN}" -eq 1 ]; then
        log_action "DRY-RUN: remove ${lib_target}"
        planned_removal=1
      else
        rm -f "${lib_target}"
        performed_removal=1
        githooks_log_info "removed ${lib_target}"
      fi
    fi
  fi

  if [ "${DRY_RUN}" -eq 1 ]; then
    if [ "${planned_removal}" -eq 0 ]; then
      githooks_log_info "DRY-RUN: no managed runner artefacts to remove"
    fi
    return 0
  fi

  if [ "${performed_removal}" -eq 1 ]; then
    githooks_log_info "removed runner artefacts from ${shared_root}"
  else
    githooks_log_info "no runner artefacts removed"
  fi
}

stage_append_unique() {
  stage_var=$1
  stage_value=$2
  if [ -z "${stage_value}" ]; then
    return 0
  fi
  eval "stage_current=\${${stage_var}}"
  for stage_item in ${stage_current}; do
    if [ "${stage_item}" = "${stage_value}" ]; then
      return 0
    fi
  done
  if [ -z "${stage_current}" ]; then
    eval "${stage_var}='${stage_value}'"
  else
    eval "${stage_var}='${stage_current} ${stage_value}'"
  fi
}

stage_list_contains() {
  stage_list=$1
  stage_seek=$2
  stage_saved_ifs=$IFS
  IFS=$' \t\n'
  set -f
  set -- ${stage_list}
  set +f
  IFS=${stage_saved_ifs}
  for stage_item in "$@"; do
    if [ "${stage_item}" = "${stage_seek}" ]; then
      return 0
    fi
  done
  return 1
}

stage_resolve_source_dir() {
  stage_raw=$1
  if [ -z "${stage_raw}" ]; then
    printf '%s' "${SCRIPT_DIR}"
    return 0
  fi
  case "${stage_raw}" in
    /*)
      printf '%s' "${stage_raw}"
      ;;
    ~*)
      stage_rest=${stage_raw#~}
      printf '%s/%s' "${HOME}" "${stage_rest#/}"
      ;;
    *)
      printf '%s/%s' "${SCRIPT_DIR%/}" "${stage_raw}"
      ;;
  esac
}

stage_append_ordered() {
  stage_var=$1
  stage_value=$2
  if [ -z "${stage_value}" ]; then
    return 0
  fi
  eval "stage_current=\${${stage_var}}"
  for stage_item in ${stage_current}; do
    if [ "${stage_item}" = "${stage_value}" ]; then
      return 0
    fi
  done
  if [ -z "${stage_current}" ]; then
    eval "${stage_var}='${stage_value}'"
  else
    eval "${stage_var}='${stage_current} ${stage_value}'"
  fi
}

stage_add_source() {
  stage_raw=$1
  case "${stage_raw}" in
    ''|all)
      stage_add_source examples
      stage_add_source hooks
      return 0
      ;;
    examples)
      stage_path="${SCRIPT_DIR%/}/examples"
      ;;
    hooks)
      stage_path="${SCRIPT_DIR%/}/hooks"
      ;;
    *)
      stage_path=$(stage_resolve_source_dir "${stage_raw}")
      ;;
  esac
  stage_append_ordered STAGE_SOURCES_ORDERED "${stage_path}"
}

stage_add_hook() {
  stage_hook=$1
  if [ -z "${stage_hook}" ]; then
    return 0
  fi
  case "${stage_hook}" in
    *,*)
      stage_saved_ifs=$IFS
      IFS=','
      set -f
      set -- ${stage_hook}
      set +f
      IFS=${stage_saved_ifs}
      for stage_piece in "$@"; do
        stage_trim=$(printf '%s' "${stage_piece}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        if [ -n "${stage_trim}" ]; then
          stage_add_hook "${stage_trim}"
        fi
      done
      return 0
      ;;
  esac
  stage_trim=$(printf '%s' "${stage_hook}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  if [ -n "${stage_trim}" ]; then
    stage_append_ordered STAGE_HOOK_FILTERS_ORDERED "${stage_trim}"
  fi
}

stage_add_name() {
  stage_name=$1
  if [ -z "${stage_name}" ]; then
    return 0
  fi
  case "${stage_name}" in
    *,*)
      stage_saved_ifs=$IFS
      IFS=','
      set -f
      set -- ${stage_name}
      set +f
      IFS=${stage_saved_ifs}
      for stage_piece in "$@"; do
        stage_trim=$(printf '%s' "${stage_piece}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        if [ -n "${stage_trim}" ]; then
          stage_add_name "${stage_trim}"
        fi
      done
      return 0
      ;;
  esac
  stage_trim=$(printf '%s' "${stage_name}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  if [ -n "${stage_trim}" ]; then
    stage_append_ordered STAGE_NAME_FILTERS_ORDERED "${stage_trim}"
  fi
}

stage_parse_legacy_selector() {
  stage_token=$1
  stage_trimmed=$(printf '%s' "${stage_token}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  if [ -z "${stage_trimmed}" ]; then
    return 0
  fi
  STAGE_LEGACY_USED=1
  case "${stage_trimmed}" in
    all|examples|hooks)
      stage_add_source "${stage_trimmed}"
      ;;
    source:*)
      stage_add_source "${stage_trimmed#source:}"
      ;;
    hook:*)
      stage_add_hook "${stage_trimmed#hook:}"
      ;;
    name:*)
      stage_add_name "${stage_trimmed#name:}"
      ;;
    *)
      stage_add_hook "${stage_trimmed}"
      ;;
  esac
}

stage_handle_legacy_list() {
  stage_list=$1
  if [ -z "${stage_list}" ]; then
    stage_parse_legacy_selector "all"
    return 0
  fi
  stage_saved_ifs=$IFS
  IFS=','
  set -f
  set -- ${stage_list}
  set +f
  IFS=${stage_saved_ifs}
  if [ $# -eq 0 ]; then
    stage_parse_legacy_selector "${stage_list}"
    return 0
  fi
  for stage_item in "$@"; do
    stage_parse_legacy_selector "${stage_item}"
  done
}

stage_ensure_default_sources() {
  if [ -n "${STAGE_SOURCES_ORDERED}" ]; then
    return 0
  fi
  stage_add_source examples
  stage_add_source hooks
  return 0
}

stage_display_source() {
  stage_source_path=$1
  case "${stage_source_path}" in
    "${SCRIPT_DIR%/}/examples")
      printf '%s' 'examples'
      ;;
    "${SCRIPT_DIR%/}/hooks")
      printf '%s' 'hooks'
      ;;
    *)
      printf '%s' "${stage_source_path}"
      ;;
  esac
}

stage_prepare_plan_file() {
  if [ -n "${STAGE_PLAN_FILE}" ] && [ -f "${STAGE_PLAN_FILE}" ]; then
    :
  else
    STAGE_PLAN_FILE=$(mktemp "${TMPDIR:-/tmp}/githooks-stage-plan.XXXXXX") || githooks_die 'failed to create stage plan file'
  fi
  STAGE_PLAN_COUNT=0
  STAGE_PLANNED_DESTS=""
}

stage_cleanup_plan() {
  if [ -n "${STAGE_PLAN_FILE}" ] && [ -f "${STAGE_PLAN_FILE}" ]; then
    rm -f "${STAGE_PLAN_FILE}"
  fi
  STAGE_PLAN_FILE=""
}

stage_register_destination() {
  stage_dest=$1
  if [ -z "${stage_dest}" ]; then
    return 1
  fi
  stage_found=0
  stage_new=""
  for stage_item in ${STAGE_PLANNED_DESTS}; do
    if [ "${stage_item}" = "${stage_dest}" ]; then
      stage_found=1
      if [ "${FORCE}" -eq 1 ]; then
        continue
      fi
    fi
    if [ -z "${stage_item}" ]; then
      continue
    fi
    if [ -z "${stage_new}" ]; then
      stage_new="${stage_item}"
    else
      stage_new="${stage_new} ${stage_item}"
    fi
  done
  if [ "${stage_found}" -eq 1 ] && [ "${FORCE}" -eq 0 ]; then
    STAGE_PLANNED_DESTS="${stage_new}"
    return 1
  fi
  if [ -z "${stage_new}" ]; then
    STAGE_PLANNED_DESTS="${stage_dest}"
  else
    STAGE_PLANNED_DESTS="${stage_new} ${stage_dest}"
  fi
  return 0
}

stage_relative_path() {
  stage_file=$1
  stage_source=$2
  case "${stage_file}" in
    "${stage_source%/}/"*)
      printf '%s' "${stage_file#${stage_source%/}/}"
      ;;
    *)
      printf '%s' "$(basename "${stage_file}")"
      ;;
  esac
}

stage_add_plan_entry() {
  stage_hook=$1
  stage_name=$2
  stage_source=$3
  stage_file=$4
  stage_rel=$(stage_relative_path "${stage_file}" "${stage_source}")
  parts_dir=$(githooks_parts_dir "${stage_hook}")
  stage_dest="${parts_dir%/}/${stage_name}"
  if ! stage_register_destination "${stage_dest}"; then
    githooks_log_info "stage skip ${stage_name}: duplicate destination for ${stage_hook}"
    return 0
  fi
  stage_prepare_plan_file
  printf '%s|%s|%s|%s|%s\n' "${stage_hook}" "${stage_name}" "${stage_source}" "${stage_rel}" "${stage_file}" >>"${STAGE_PLAN_FILE}" || githooks_die "failed to write stage plan"
  STAGE_PLAN_COUNT=$((STAGE_PLAN_COUNT + 1))
}

stage_summary_requested() {
  if [ "${STAGE_SUMMARY}" -eq 1 ] || [ "${DRY_RUN}" -eq 1 ]; then
    return 0
  fi
  return 1
}

stage_sort_plan_if_needed() {
  if [ -z "${STAGE_PLAN_FILE}" ] || [ ! -f "${STAGE_PLAN_FILE}" ]; then
    return 0
  fi
  case "${STAGE_ORDER_STRATEGY}" in
    hook)
      stage_tmp=$(mktemp "${TMPDIR:-/tmp}/githooks-stage-plan-sort.XXXXXX") || githooks_die 'failed to create sort scratch'
      LC_ALL=C sort -t '|' -k1,1 -k2,2 "${STAGE_PLAN_FILE}" >"${stage_tmp}"
      mv "${stage_tmp}" "${STAGE_PLAN_FILE}"
      ;;
    name)
      stage_tmp=$(mktemp "${TMPDIR:-/tmp}/githooks-stage-plan-sort.XXXXXX") || githooks_die 'failed to create sort scratch'
      LC_ALL=C sort -t '|' -k2,2 -k1,1 "${STAGE_PLAN_FILE}" >"${stage_tmp}"
      mv "${stage_tmp}" "${STAGE_PLAN_FILE}"
      ;;
    *)
      :
      ;;
  esac
}

stage_emit_plan_summary() {
  if stage_summary_requested; then
    :
  else
    return 0
  fi
  if [ -z "${STAGE_PLAN_FILE}" ] || [ ! -f "${STAGE_PLAN_FILE}" ]; then
    return 0
  fi
  while IFS='|' read -r stage_hook stage_name stage_source stage_rel stage_file; do
    [ -n "${stage_hook}" ] || continue
    stage_label=$(stage_display_source "${stage_source}")
    githooks_log_info "PLAN: hook=${stage_hook} name=${stage_name} source=${stage_label} rel=${stage_rel}"
  done <"${STAGE_PLAN_FILE}"
}

stage_is_hook_like() {
  if [ "$#" -ne 1 ]; then
    return 1
  fi
  stage_candidate=$1
  case "${stage_candidate}" in
    *-*)
      ;;
    *)
      return 1
      ;;
  esac
  case "${stage_candidate}" in
    *[!A-Za-z0-9-]*)
      return 1
      ;;
  esac
  return 0
}

stage_hooks_from_directory() {
  stage_file=$1
  stage_root=$2
  STAGE_TMP_DIR_HOOKS=""
  stage_norm_root=${stage_root%/}
  stage_rel=${stage_file}
  case "${stage_file}" in
    "${stage_norm_root}"/*)
      stage_rel=${stage_file#${stage_norm_root}/}
      ;;
  esac
  stage_rel_dir=$(dirname "${stage_rel}")
  if [ "${stage_rel_dir}" = "." ]; then
    stage_rel_dir=""
  fi
  stage_parent=""
  if [ -n "${stage_rel_dir}" ]; then
    stage_parent=$(basename "${stage_rel_dir}")
  fi
  stage_grand_dir=""
  if [ -n "${stage_rel_dir}" ]; then
    stage_grand_dir=$(dirname "${stage_rel_dir}")
    if [ "${stage_grand_dir}" = "." ]; then
      stage_grand_dir=""
    fi
  fi
  stage_grandparent=""
  if [ -n "${stage_grand_dir}" ]; then
    stage_grandparent=$(basename "${stage_grand_dir}")
  fi
  if [ -n "${stage_parent}" ]; then
    case "${stage_parent}" in
      hooks|examples)
        ;;
      *.d)
        stage_candidate=${stage_parent%.d}
        if [ -n "${stage_candidate}" ]; then
          stage_append_unique STAGE_TMP_DIR_HOOKS "${stage_candidate}"
        fi
        ;;
      *)
        if stage_is_hook_like "${stage_parent}"; then
          stage_append_unique STAGE_TMP_DIR_HOOKS "${stage_parent}"
        fi
        ;;
    esac
  fi
  if [ -n "${stage_grandparent}" ]; then
    case "${stage_grandparent}" in
      hooks|examples)
        ;;
      *.d)
        stage_candidate=${stage_grandparent%.d}
        if [ -n "${stage_candidate}" ]; then
          stage_append_unique STAGE_TMP_DIR_HOOKS "${stage_candidate}"
        fi
        ;;
      *)
        if stage_is_hook_like "${stage_grandparent}"; then
          stage_append_unique STAGE_TMP_DIR_HOOKS "${stage_grandparent}"
        fi
        ;;
    esac
  fi
  stage_result=${STAGE_TMP_DIR_HOOKS}
  STAGE_TMP_DIR_HOOKS=""
  printf '%s' "${stage_result}"
}

stage_detect_hooks_for_file() {
  stage_file=$1
  stage_root=$2
  STAGE_DETECTED_HOOKS=""
  STAGE_DETECTED_SOURCE="none"
  stage_metadata_hooks=""
  stage_metadata_found=0
  stage_nonempty=0
  stage_line_total=0
  while IFS= read -r stage_line || [ -n "${stage_line}" ]; do
    stage_line_total=$((stage_line_total + 1))
    stage_trimmed=$(printf '%s' "${stage_line}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [ -n "${stage_trimmed}" ]; then
      stage_nonempty=$((stage_nonempty + 1))
    fi
    case "${stage_trimmed}" in
      '# githooks-stage:'*)
        stage_values=${stage_trimmed#\# githooks-stage:}
        stage_values=$(printf '%s' "${stage_values}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | tr ',' ' ')
        for stage_value in ${stage_values}; do
          stage_token=$(printf '%s' "${stage_value}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
          if [ -n "${stage_token}" ]; then
            stage_append_unique stage_metadata_hooks "${stage_token}"
          fi
        done
        stage_metadata_found=1
        break
        ;;
    esac
    if [ "${stage_nonempty}" -ge 20 ]; then
      break
    fi
    if [ "${stage_line_total}" -ge 200 ]; then
      break
    fi
  done < "${stage_file}"
  if [ "${stage_metadata_found}" -eq 1 ] && [ -n "${stage_metadata_hooks}" ]; then
    STAGE_DETECTED_HOOKS="${stage_metadata_hooks}"
    STAGE_DETECTED_SOURCE="metadata"
    return 0
  fi
  stage_dir_hooks=$(stage_hooks_from_directory "${stage_file}" "${stage_root}")
  if [ -n "${stage_dir_hooks}" ]; then
    STAGE_DETECTED_HOOKS="${stage_dir_hooks}"
    STAGE_DETECTED_SOURCE="directory"
    return 0
  fi
  STAGE_DETECTED_HOOKS=""
  STAGE_DETECTED_SOURCE="none"
  return 1
}

stage_normalise_hooks() {
  stage_input=$1
  STAGE_TMP_UNIQUE=""
  for stage_item in ${stage_input}; do
    stage_append_unique STAGE_TMP_UNIQUE "${stage_item}"
  done
  stage_result=${STAGE_TMP_UNIQUE}
  STAGE_TMP_UNIQUE=""
  printf '%s' "${stage_result}"
}

stage_hook_allowed() {
  stage_hook=$1
  if [ -n "${STAGE_HOOK_FILTERS_ORDERED}" ]; then
    if stage_list_contains "${STAGE_HOOK_FILTERS_ORDERED}" "${stage_hook}"; then
      :
    else
      return 1
    fi
  fi
  if [ "${HOOKS_WERE_EXPLICIT}" -eq 1 ]; then
    if stage_list_contains "${HOOKS}" "${stage_hook}"; then
      :
    else
      return 1
    fi
  fi
  return 0
}

stage_name_matches_filter() {
  stage_candidate=$1
  stage_filter=$2
  case "${stage_candidate}" in
    ${stage_filter})
      return 0
      ;;
  esac
  stage_candidate_noext=${stage_candidate%.sh}
  if [ "${stage_candidate_noext}" != "${stage_candidate}" ]; then
    case "${stage_candidate_noext}" in
      ${stage_filter})
        return 0
        ;;
    esac
  fi
  return 1
}

stage_name_allowed() {
  stage_basename=$1
  if [ -z "${STAGE_NAME_FILTERS_ORDERED}" ]; then
    return 0
  fi
  for stage_name_filter in ${STAGE_NAME_FILTERS_ORDERED}; do
    if stage_name_matches_filter "${stage_basename}" "${stage_name_filter}"; then
      return 0
    fi
  done
  return 1
}

stage_ensure_runner() {
  if [ "${STAGE_RUNNER_READY}" -eq 0 ]; then
    install_runner
    STAGE_RUNNER_READY=1
  fi
}

stage_ensure_stub() {
  stage_hook=$1
  stage_stub_path="${hooks_root%/}/${stage_hook}"
  if [ -f "${stage_stub_path}" ]; then
    if grep -q 'generated by .githooks-runner' "${stage_stub_path}" 2>/dev/null; then
      if [ "${FORCE}" -eq 1 ]; then
        write_stub "${stage_hook}"
      fi
      return 0
    fi
    if [ "${FORCE}" -eq 1 ]; then
      write_stub "${stage_hook}"
    else
      githooks_log_warn "stub exists for ${stage_hook}; rerun with --force to replace unmanaged stub"
    fi
    return 0
  fi
  write_stub "${stage_hook}"
}

stage_files_identical() {
  stage_src=$1
  stage_dst=$2
  if [ ! -f "${stage_src}" ] || [ ! -f "${stage_dst}" ]; then
    return 1
  fi
  if ! stage_src_sum=$(cksum < "${stage_src}" 2>/dev/null); then
    return 1
  fi
  if ! stage_dst_sum=$(cksum < "${stage_dst}" 2>/dev/null); then
    return 1
  fi
  if [ "${stage_src_sum}" = "${stage_dst_sum}" ]; then
    return 0
  fi
  return 1
}

stage_copy_part() {
  stage_src=$1
  stage_dst=$2
  stage_dst_dir=$(dirname "${stage_dst}")
  maybe_run "ensure parts directory ${stage_dst_dir}" githooks_mkdir_p "${stage_dst_dir}"
  if [ "${DRY_RUN}" -eq 1 ]; then
    githooks_log_info "DRY-RUN: stage ${stage_src} -> ${stage_dst}"
    return 0
  fi
  stage_action="copy"
  if [ -f "${stage_dst}" ]; then
    if [ "${FORCE}" -eq 0 ] && stage_files_identical "${stage_src}" "${stage_dst}"; then
      STAGE_SKIP_IDENTICAL=$((STAGE_SKIP_IDENTICAL + 1))
      githooks_log_info "stage skip identical ${stage_dst}"
      return 0
    fi
    stage_action="update"
  fi
  stage_tmp="${stage_dst}.stage.$$"
  if ! cp "${stage_src}" "${stage_tmp}"; then
    rm -f "${stage_tmp}" 2>/dev/null || true
    githooks_die "Failed to ${stage_action} ${stage_dst}"
  fi
  githooks_chmod 755 "${stage_tmp}"
  if ! mv "${stage_tmp}" "${stage_dst}"; then
    rm -f "${stage_tmp}" 2>/dev/null || true
    githooks_die "Failed to finalise ${stage_dst}"
  fi
  STAGE_COPY_COUNT=$((STAGE_COPY_COUNT + 1))
  githooks_log_info "stage ${stage_action} ${stage_dst}"
}

stage_name_filtered_out() {
  stage_basename=$1
  if [ -z "${STAGE_NAME_FILTERS_ORDERED}" ]; then
    return 1
  fi
  for stage_name_filter in ${STAGE_NAME_FILTERS_ORDERED}; do
    if stage_name_matches_filter "${stage_basename}" "${stage_name_filter}"; then
      return 1
    fi
  done
  return 0
}

stage_process_file() {
  stage_file=$1
  stage_source=$2
  stage_basename=$(basename "${stage_file}")
  if stage_name_allowed "${stage_basename}"; then
    :
  else
    STAGE_SKIPPED_FILES=$((STAGE_SKIPPED_FILES + 1))
    githooks_log_info "stage skip ${stage_basename}: filtered by name"
    return 0
  fi
  stage_detect_hooks_for_file "${stage_file}" "${stage_source}"
  stage_hooks=${STAGE_DETECTED_HOOKS}
  if [ -z "${stage_hooks}" ]; then
    if [ "${HOOKS_WERE_EXPLICIT}" -eq 1 ] && [ -n "${HOOKS}" ]; then
      stage_hooks=${HOOKS}
    else
      STAGE_SKIPPED_FILES=$((STAGE_SKIPPED_FILES + 1))
      githooks_log_warn "stage skip ${stage_basename}: unable to determine hook target"
      return 0
    fi
  fi
  stage_hooks=$(stage_normalise_hooks "${stage_hooks}")
  stage_allowed_hooks=""
  stage_hook_saved_ifs=$IFS
  IFS=' '
  for stage_hook in ${stage_hooks}; do
    if stage_hook_allowed "${stage_hook}"; then
      if [ -z "${stage_allowed_hooks}" ]; then
        stage_allowed_hooks="${stage_hook}"
      else
        stage_allowed_hooks="${stage_allowed_hooks} ${stage_hook}"
      fi
    fi
  done
  IFS=${stage_hook_saved_ifs}
  if [ -z "${stage_allowed_hooks}" ]; then
    STAGE_SKIPPED_FILES=$((STAGE_SKIPPED_FILES + 1))
    githooks_log_info "stage skip ${stage_basename}: filtered by hook selectors"
    return 0
  fi
  stage_prepare_plan_file
  stage_hook_saved_ifs=$IFS
  IFS=' '
  for stage_hook in ${stage_allowed_hooks}; do
    stage_add_plan_entry "${stage_hook}" "${stage_basename}" "${stage_source}" "${stage_file}"
  done
  IFS=${stage_hook_saved_ifs}
}

stage_reset_state() {
  STAGE_COPY_COUNT=0
  STAGE_SKIP_IDENTICAL=0
  STAGE_SKIPPED_FILES=0
  STAGE_RUNNER_READY=0
}

stage_build_plan() {
  stage_prepare_plan_file
  STAGE_PLAN_COUNT=0
  stage_any_source=0
  stage_saved_ifs=$IFS
  for stage_source in ${STAGE_SOURCES_ORDERED}; do
    stage_any_source=1
    if [ ! -d "${stage_source}" ]; then
      githooks_log_warn "stage source missing: ${stage_source}"
      continue
    fi
    stage_candidates=$(LC_ALL=C find -L "${stage_source}" -type f -perm -u+x -name '*.sh' -print 2>/dev/null | LC_ALL=C sort)
    if [ -z "${stage_candidates}" ]; then
      continue
    fi
    stage_newline=$(printf '\n_')
    IFS=${stage_newline%_}
    set -f
    set -- ${stage_candidates}
    for stage_candidate do
      stage_process_file "${stage_candidate}" "${stage_source}"
    done
    set +f
  done
  IFS=${stage_saved_ifs}
  if [ "${stage_any_source}" -eq 0 ]; then
    githooks_log_warn "stage aborted: no source directories available"
    stage_cleanup_plan
    return 1
  fi
  return 0
}

stage_finish_no_plan() {
  stage_action=$1
  stage_zero_phrase=$2
  if stage_summary_requested; then
    githooks_log_info "PLAN: no matching files"
  fi
  if [ "${DRY_RUN}" -eq 1 ]; then
    githooks_log_info "${stage_action} dry-run complete"
  else
    githooks_log_info "${stage_action} complete: ${stage_zero_phrase}"
  fi
  if [ "${STAGE_SKIPPED_FILES}" -gt 0 ]; then
    githooks_log_info "${stage_action} skipped ${STAGE_SKIPPED_FILES} file(s) due to filters or missing metadata"
  fi
  stage_cleanup_plan
  return 0
}

run_stage() {
  stage_reset_state
  if [ "${STAGE_LEGACY_USED}" -eq 1 ]; then
    githooks_log_warn "stage: legacy selector syntax detected; prefer positional sources with --hook/--name filters"
  fi
  stage_ensure_default_sources
  if ! stage_build_plan; then
    return 1
  fi
  if [ "${STAGE_PLAN_COUNT}" -eq 0 ]; then
    stage_finish_no_plan "stage" "0 file(s) updated"
    return 0
  fi
  stage_sort_plan_if_needed
  stage_emit_plan_summary
  if [ "${DRY_RUN}" -eq 1 ]; then
    githooks_log_info "stage dry-run complete"
    stage_cleanup_plan
    return 0
  fi
  while IFS='|' read -r plan_hook plan_name plan_source plan_rel plan_file; do
    [ -n "${plan_hook}" ] || continue
    stage_ensure_runner
    parts_dir=$(githooks_parts_dir "${plan_hook}")
    create_parts_dir "${plan_hook}"
    stage_ensure_stub "${plan_hook}"
    stage_dest="${parts_dir%/}/${plan_name}"
    githooks_log_info "stage plan ${plan_rel} -> ${plan_hook}"
    stage_copy_part "${plan_file}" "${stage_dest}"
  done <"${STAGE_PLAN_FILE}"
  stage_cleanup_plan
  githooks_log_info "stage complete: ${STAGE_COPY_COUNT} file(s) updated"
  if [ "${STAGE_SKIP_IDENTICAL}" -gt 0 ]; then
    githooks_log_info "stage skipped ${STAGE_SKIP_IDENTICAL} identical file(s)"
  fi
  if [ "${STAGE_SKIPPED_FILES}" -gt 0 ]; then
    githooks_log_info "stage skipped ${STAGE_SKIPPED_FILES} file(s) due to filters or missing metadata"
  fi
  return 0
}

run_stage_unstage() {
  stage_reset_state
  if [ "${STAGE_LEGACY_USED}" -eq 1 ]; then
    githooks_log_warn "stage: legacy selector syntax detected; prefer positional sources with --hook/--name filters"
  fi
  stage_ensure_default_sources
  if ! stage_build_plan; then
    return 1
  fi
  if [ "${STAGE_PLAN_COUNT}" -eq 0 ]; then
    stage_finish_no_plan "unstage" "0 file(s) removed"
    return 0
  fi
  stage_sort_plan_if_needed
  stage_emit_plan_summary
  if [ "${DRY_RUN}" -eq 1 ]; then
    githooks_log_info "unstage dry-run complete"
    stage_cleanup_plan
    return 0
  fi
  UNSTAGE_REMOVE_COUNT=0
  UNSTAGE_MISSING_COUNT=0
  while IFS='|' read -r plan_hook plan_name plan_source plan_rel plan_file; do
    [ -n "${plan_hook}" ] || continue
    parts_dir=$(githooks_parts_dir "${plan_hook}")
    stage_dest="${parts_dir%/}/${plan_name}"
    githooks_log_info "unstage plan ${plan_rel} -> ${plan_hook}"
    if [ -f "${stage_dest}" ]; then
      maybe_run "remove ${stage_dest}" rm -f "${stage_dest}"
      UNSTAGE_REMOVE_COUNT=$((UNSTAGE_REMOVE_COUNT + 1))
    else
      githooks_log_info "unstage skip missing ${stage_dest}"
      UNSTAGE_MISSING_COUNT=$((UNSTAGE_MISSING_COUNT + 1))
    fi
  done <"${STAGE_PLAN_FILE}"
  stage_cleanup_plan
  githooks_log_info "unstage complete: ${UNSTAGE_REMOVE_COUNT} file(s) removed"
  if [ "${UNSTAGE_MISSING_COUNT}" -gt 0 ]; then
    githooks_log_info "unstage skipped ${UNSTAGE_MISSING_COUNT} missing file(s)"
  fi
  if [ "${STAGE_SKIPPED_FILES}" -gt 0 ]; then
    githooks_log_info "unstage skipped ${STAGE_SKIPPED_FILES} file(s) due to filters or missing metadata"
  fi
  return 0
}

print_install_usage() {
  cat <<'HELP'
NAME
    githooks install - Install the shared runner and hook stubs.

SYNOPSIS
    githooks install [OPTIONS]

DESCRIPTION
    Creates or refreshes the managed hook runner under .githooks/, ensures each
    selected Git hook has a stub that dispatches into the runner, and prepares
    per-hook directories (.githooks/<hook>.d) for staged scripts. Existing stubs
    are left untouched unless --force is supplied.

    When invoked with `--mode ephemeral`, the runner and stubs live under
    .git/.githooks/, leaving repository history untouched while persisting
    across pulls and resets. The installer records manifest metadata so future
    refresh or uninstall operations restore the previous hooks configuration.

    Ephemeral installs default to `ephemeral-first` precedence. Use the
    `--overlay` flag or matching config to reorder versioned `.githooks/`
    content when layering local automation with tracked hooks.

    Existing `.githooks/` directories remain compatible: overlay precedence
    determines whether tracked or ephemeral hook parts dispatch first, and the
    manifest retains prior `core.hooksPath` values for clean rollbacks.

OPTIONS
    --mode MODE
        Switch between installation strategies. The default `standard` vendors
        files into .githooks/. Use `ephemeral` to keep assets inside
        .git/.githooks/ and snapshot the prior hooks configuration for
        reversible uninstall.

    --hooks HOOKS | --hooks=HOOKS | -H HOOKS
        Comma-separated hook names to manage. Overrides the default curated set.

    --all-hooks | --all | -A
        Manage every hook supported by Git. Useful for shared repositories that
        require wide coverage.

    --overlay MODE
        For Ephemeral Mode, choose precedence between `ephemeral-first`,
        `versioned-first`, or `merge` when combining hook roots. Defaults to
        `ephemeral-first`. Values can also be set via the
        GITHOOKS_EPHEMERAL_PRECEDENCE environment variable or
        `git config githooks.ephemeral.precedence`.

    --force | -f
        Overwrite any existing managed stub files. Safe for regenerating stubs.

    -n, --dry-run
        Print the actions that would be taken without touching the filesystem.

    -h, --help | help
        Display this manual entry.

NOTES
    Ensure Git and a POSIX-compliant shell are available before running the
    installer; target a writable repository worktree or bare `.git` directory.

    Ephemeral installations snapshot precedence, hooks, and prior Git
    configuration in `.git/.githooks/manifest.sh`. Inspect the manifest or run
    `githooks config show` when troubleshooting, and use the same command after
    installation to confirm the hooks path and overlay ordering captured in the
    manifest.

EXAMPLES
    githooks install --mode ephemeral --hooks pre-commit,post-merge
        Install Ephemeral Mode for specific hooks without touching tracked files.

    githooks install --mode ephemeral --overlay versioned-first
        Layer Ephemeral Mode while prioritizing staged hooks from `.githooks/`.

    githooks install --hooks pre-commit,pre-push
        Install the runner and only manage the pre-commit and pre-push hooks.

    githooks install --all-hooks --dry-run
        Review the complete set of hooks that would be managed before applying.

SEE ALSO
    githooks stage add, githooks uninstall
HELP
}

print_stage_usage() {
  cat <<'HELP'
NAME
    githooks stage - Stage, remove, or list hook parts sourced from directories.

SYNOPSIS
    githooks stage [SUBCOMMAND] [ARGS]

DESCRIPTION
    The stage family copies executable scripts into .githooks/<hook>.d based on
    metadata comments or directory structure. Use `githooks stage help <topic>`
    for detailed guidance on each operation.

SUBCOMMANDS
    add     Plan and copy scripts from directories into managed hook slots.
    unstage Reverse stage add by removing staged scripts that match sources.
    remove  Delete one or all staged scripts for a given hook.
    list    Display staged scripts, grouped by hook.
    help    Show this manual or a subcommand-specific manual.

GLOBAL OPTIONS
    -n, --dry-run
        Honour dry-run mode across stage subcommands, surfacing planned work.

EXAMPLES
    githooks stage add examples --hook pre-commit --name 'lint-*'
        Stage example lint scripts whose filenames match the glob, targeting the
        pre-commit hook only.

    githooks stage list pre-commit
        Inspect staged scripts for the pre-commit hook.

SEE ALSO
    githooks stage add help
    githooks stage remove help
    githooks stage list help
HELP
}

print_stage_add_usage() {
  cat <<'HELP'
NAME
    githooks stage add - Copy hook parts from a source directory into .githooks.

SYNOPSIS
    githooks stage add SOURCE [OPTIONS]

DESCRIPTION
    Walks SOURCE (examples, hooks, or a custom directory), detects executable
    *.sh files, resolves their target hooks either from `# githooks-stage:`
    metadata or by directory placement, and copies matching scripts into
    .githooks/<hook>.d. Destination filenames mirror the source basename, with
    `.sh` appended automatically when omitted.

OPTIONS
    --hook HOOKS | --hook=HOOKS | --for-hook HOOKS
        Restrict staging to the listed hooks (comma-separated). Scripts whose
        resolved hook set does not intersect the filter are skipped.

    --name PATTERNS | --name=PATTERNS | --part PATTERNS
        Accept a comma-separated list of shell globs. A script is staged only if
        its basename, or that basename without a trailing .sh, matches at least
        one pattern (e.g. `git-crypt-*`, `lint`).

    --force | -f
        Overwrite existing staged scripts even when contents already match.

    -n, --dry-run
        Emit the staging plan without copying files.

    -h, --help | help
        Display this manual entry.

EXAMPLES
    githooks stage add hooks --hook pre-commit,prepare-commit-msg
        Stage every executable script beneath hooks/ that targets either listed
        hook.

    githooks stage add custom-scripts --name 'security-*'
        Stage only scripts whose basenames begin with `security-`.

SEE ALSO
    githooks stage remove, githooks stage list, README section “Adding Hook Parts”
HELP
}

print_stage_unstage_usage() {
  cat <<'HELP'
NAME
    githooks stage unstage - Remove staged hook parts matching source files.

SYNOPSIS
    githooks stage unstage SOURCE [OPTIONS]

DESCRIPTION
    Walks SOURCE (examples, hooks, or a custom directory), detects executable
    *.sh files, resolves their target hooks from metadata comments or directory
    placement, and removes any matching staged scripts from .githooks/<hook>.d.
    Filters restrict removals to specific hooks or filenames.

OPTIONS
    --hook HOOKS | --hook=HOOKS | --for-hook HOOKS
        Restrict unstaging to the listed hooks (comma-separated). Scripts whose
        resolved hook set does not intersect the filter are ignored.

    --name PATTERNS | --name=PATTERNS | --part PATTERNS
        Accept a comma-separated list of shell globs. A staged script is only
        removed when its basename, or that basename without a trailing .sh,
        matches at least one pattern (e.g. `dependency-sync`, `lint-*`).

    -n, --dry-run
        Emit the unstaging plan without removing files.

    -h, --help | help
        Display this manual entry.

EXAMPLES
    githooks stage unstage examples --name dependency-sync
        Remove the dependency-sync example from every hook where it is staged.

    githooks stage unstage hooks --hook pre-commit
        Remove staged scripts sourced from hooks/ that target pre-commit.

SEE ALSO
    githooks stage add, githooks stage remove, README section “Managing Staged Parts”
HELP
}

print_stage_remove_usage() {
  cat <<'HELP'
NAME
    githooks stage remove - Delete staged scripts for a specific hook.

SYNOPSIS
    githooks stage remove HOOK [OPTIONS]

DESCRIPTION
    Removes staged scripts from .githooks/HOOK.d. Provide a specific name (with
    or without `.sh`) or use --all to clear the hook entirely.

OPTIONS
    --name PART | --name=PART | --part PART
        Remove only the named staged script. The `.sh` suffix is optional.

    --all
        Remove every staged script for HOOK.

    -n, --dry-run
        Describe deletions without performing them.

    -h, --help | help
        Display this manual entry.

EXAMPLES
    githooks stage remove pre-commit git-crypt-enforce
        Remove the git-crypt enforcement script from the pre-commit hook.

    githooks stage remove post-merge --all --dry-run
        Preview the scripts that would be removed from post-merge.

SEE ALSO
    githooks stage add, githooks stage list
HELP
}

print_stage_list_usage() {
  cat <<'HELP'
NAME
    githooks stage list - Show staged scripts grouped by hook.

SYNOPSIS
    githooks stage list [HOOK]

DESCRIPTION
    Prints a tabular view of hooks and their staged script names. When a HOOK is
    provided, the output focuses on that hook; otherwise all hooks with staged
    scripts are displayed. The command emits a header followed by hook/name rows.

OPTIONS
    -h, --help | help
        Display this manual entry.

EXAMPLES
    githooks stage list
        Show every staged script across the repository.

    githooks stage list prepare-commit-msg
        Inspect staged scripts for a single hook.

SEE ALSO
    githooks hooks list, githooks stage add
HELP
}

print_hooks_usage() {
  cat <<'HELP'
NAME
    githooks hooks - Inspect stub coverage and staged parts per hook.

SYNOPSIS
    githooks hooks [SUBCOMMAND]

DESCRIPTION
    Commands under `hooks` reveal which Git hooks have managed stubs and how
    many staged scripts each hook currently owns.

SUBCOMMANDS
    list    Emit a table showing stub status and staged script counts.
    help    Display this manual or a subcommand-specific manual.

SEE ALSO
    githooks hooks list help
HELP
}

print_hooks_list_usage() {
  cat <<'HELP'
NAME
    githooks hooks list - Summarise managed hooks and staged script counts.

SYNOPSIS
    githooks hooks list [HOOK]

DESCRIPTION
    For each managed hook, print whether a stub exists and how many parts are
    staged. Provide a HOOK to narrow the report to a single entry.

OPTIONS
    -h, --help | help
        Display this manual entry.

EXAMPLES
    githooks hooks list
        Review every managed hook and the number of staged scripts.

    githooks hooks list pre-commit
        Inspect only the pre-commit hook.

SEE ALSO
    githooks stage list, githooks install
HELP
}

print_config_usage() {
  cat <<'HELP'
NAME
    githooks config - Query or update runner-related Git configuration.

SYNOPSIS
    githooks config [SUBCOMMAND]

DESCRIPTION
    Provides helpers for inspecting the repository’s Git configuration values
    that influence hook execution and for updating the hooks-path setting.

SUBCOMMANDS
    show    Print resolved hooks-path values and derived toolkit paths.
    set     Update supported configuration keys (currently hooks-path).
    help    Display this manual or a subcommand-specific manual.

SEE ALSO
    githooks config show help, githooks config set help
HELP
}

print_config_show_usage() {
  cat <<'HELP'
NAME
    githooks config show - Display hook-related configuration values.

SYNOPSIS
    githooks config show

DESCRIPTION
    Echoes Git’s core.hooksPath (if set), plus the resolved shared runner and
    hooks directories. Helpful when diagnosing custom Git configuration.

OPTIONS
    -h, --help | help
        Display this manual entry.

SEE ALSO
    githooks config set, git config core.hooksPath
HELP
}

print_config_set_usage() {
  cat <<'HELP'
NAME
    githooks config set - Update supported configuration keys.

SYNOPSIS
    githooks config set hooks-path PATH

DESCRIPTION
    Writes the supplied PATH into Git’s core.hooksPath, pointing Git at the
    shared runner directory. The command echoes the git config invocation before
    running it, and respects --dry-run when supplied globally.

OPTIONS
    -h, --help | help
        Display this manual entry.

EXAMPLES
    githooks config set hooks-path .githooks
        Direct Git to use the staged runner directory within the repository.

SEE ALSO
    githooks config show, git config core.hooksPath
HELP
}

print_uninstall_usage() {
  cat <<'HELP'
NAME
    githooks uninstall - Remove managed stubs and shared runner artefacts.

SYNOPSIS
    githooks uninstall [OPTIONS]

DESCRIPTION
    Deletes the shared runner (.githooks/_runner.sh), its library, and any stubs
    previously installed in .git/hooks by the toolkit. Files not recognised as
    managed stubs are left untouched to avoid destroying user-managed hooks.

    For Ephemeral Mode, the command removes `.git/.githooks/` assets, restores
    the prior `core.hooksPath` recorded in the manifest, and deletes the
    manifest itself while leaving tracked files untouched.

    The uninstall flow consults manifest metadata to restore precedence
    settings and prior hook roots. Re-run `githooks install --mode ephemeral`
    after cleanup to reinstate the ephemeral environment.

OPTIONS
    -n, --dry-run
        Describe the filesystem removals without executing them.

    --mode MODE
        Uninstall a specific installation mode. Use `ephemeral` to clean the
        local .git/.githooks/ assets and restore the prior hooks configuration
        captured during install.

    -h, --help | help
        Display this manual entry.

NOTES
    Pair `--dry-run` with Ephemeral Mode to review manifest-driven removals
    before touching the filesystem. After cleanup, run `githooks config show`
    to confirm the restored hooks path and precedence state.

EXAMPLES
    githooks uninstall --mode ephemeral
        Remove Ephemeral Mode assets and reinstate the previous hooks path.

    githooks uninstall --dry-run
        Preview which artefacts would be removed.

SEE ALSO
    githooks install, githooks stage remove
HELP
}

compat_warn() {
  if [ "$#" -ne 1 ]; then
    return 0
  fi
  if [ "${COMPAT_WARNED}" -eq 0 ]; then
    githooks_log_warn "legacy command alias '$1' detected; prefer modern subcommands"
  fi
  COMPAT_WARNED=1
}

normalise_part_name() {
  if [ "$#" -ne 1 ]; then
    githooks_die "normalise_part_name expects script name"
  fi
  _norm_name=$1
  case "${_norm_name}" in
    */*)
      _norm_name=$(basename "${_norm_name}")
      ;;
  esac
  if [ -z "${_norm_name}" ]; then
    githooks_die "hook part name required"
  fi
  case "${_norm_name}" in
    *.sh)
      printf '%s\n' "${_norm_name}"
      ;;
    *)
      printf '%s.sh\n' "${_norm_name}"
      ;;
  esac
}

stage_remove_part() {
  if [ "$#" -ne 2 ]; then
    githooks_die "remove requires hook and part name"
  fi
  _remove_hook=$1
  _remove_name=$(normalise_part_name "$2")
  _remove_dir=$(githooks_parts_dir "${_remove_hook}")
  _remove_path="${_remove_dir%/}/${_remove_name}"
  if [ ! -f "${_remove_path}" ]; then
    githooks_die "no staged part ${_remove_name} for hook ${_remove_hook}"
  fi
  maybe_run "remove ${_remove_path}" rm -f "${_remove_path}"
}

stage_remove_all_parts() {
  if [ "$#" -ne 1 ]; then
    githooks_die "remove --all requires hook name"
  fi
  _remove_hook=$1
  _remove_dir=$(githooks_parts_dir "${_remove_hook}")
  if [ ! -d "${_remove_dir}" ]; then
    githooks_die "no staged parts directory for hook ${_remove_hook}"
  fi
  remove_any=0
  stage_parts=$(githooks_list_parts "${_remove_hook}")
  if [ -n "${stage_parts}" ]; then
    stage_newline=$(printf '\n_')
    stage_old_ifs=$IFS
    IFS=${stage_newline%_}
    set -f
    for stage_part in ${stage_parts}; do
      remove_any=1
      stage_remove_part "${_remove_hook}" "$(basename "${stage_part}")"
    done
    set +f
    IFS=${stage_old_ifs}
  fi
  if [ "${remove_any}" -eq 0 ]; then
    githooks_log_info "no parts staged for ${_remove_hook}"
  fi
}

stage_list_parts_for_hook() {
  if [ "$#" -ne 1 ]; then
    githooks_die "list requires hook name"
  fi
  _list_hook=$1
  _list_parts=$(githooks_list_parts "${_list_hook}")
  if [ -z "${_list_parts}" ]; then
    return 1
  fi
  stage_newline=$(printf '\n_')
  stage_old_ifs=$IFS
  IFS=${stage_newline%_}
  set -f
  for _list_part in ${_list_parts}; do
    if [ "${STAGE_LIST_HEADER_SHOWN}" -eq 0 ]; then
      printf '%s\t%s\n' 'HOOK' 'PART'
      STAGE_LIST_HEADER_SHOWN=1
    fi
    STAGE_LIST_PRINTED=1
    printf '%s\t%s\n' "${_list_hook}" "$(basename "${_list_part}")"
  done
  set +f
  IFS=${stage_old_ifs}
  return 0
}

stage_list_all_parts() {
  STAGE_LIST_PRINTED=0
  STAGE_LIST_HEADER_SHOWN=0
  stage_root=$(githooks_shared_root)
  if [ ! -d "${stage_root}" ]; then
    githooks_log_info "no hook parts staged"
    return 0
  fi
  stage_dirs=$(LC_ALL=C find "${stage_root}" -mindepth 1 -maxdepth 1 -type d -name '*.d' -print 2>/dev/null | LC_ALL=C sort)
  if [ -z "${stage_dirs}" ]; then
    githooks_log_info "no hook parts staged"
    return 0
  fi
  stage_newline=$(printf '\n_')
  stage_old_ifs=$IFS
  IFS=${stage_newline%_}
  set -f
  for stage_dir in ${stage_dirs}; do
    stage_hook_name=$(basename "${stage_dir}")
    stage_hook_name=${stage_hook_name%.d}
    stage_list_parts_for_hook "${stage_hook_name}"
  done
  set +f
  IFS=${stage_old_ifs}
  if [ "${STAGE_LIST_PRINTED}" -eq 0 ]; then
    githooks_log_info "no hook parts staged"
  fi
}

hooks_list_summary() {
  hooks_target="${hooks_root%/}"
  shared_target=$(githooks_shared_root)
  HOOK_SUMMARY_NAMES=""
  hook_filter=""
  if [ "$#" -gt 0 ]; then
    hook_filter=$1
  fi

  if [ -d "${shared_target}" ]; then
    hooks_dirs=$(LC_ALL=C find "${shared_target}" -mindepth 1 -maxdepth 1 -type d -name '*.d' -print 2>/dev/null)
    if [ -n "${hooks_dirs}" ]; then
      stage_newline=$(printf '\n_')
      stage_old_ifs=$IFS
      IFS=${stage_newline%_}
      set -f
      for hook_dir in ${hooks_dirs}; do
        hook_name=$(basename "${hook_dir}")
        hook_name=${hook_name%.d}
        if [ -z "${hook_filter}" ] || [ "${hook_filter}" = "${hook_name}" ]; then
          stage_append_unique HOOK_SUMMARY_NAMES "${hook_name}"
        fi
      done
      set +f
      IFS=${stage_old_ifs}
    fi
  fi

  if [ -d "${hooks_target}" ]; then
    stub_files=$(LC_ALL=C find "${hooks_target}" -mindepth 1 -maxdepth 1 -type f -perm -u+x -print 2>/dev/null)
    if [ -n "${stub_files}" ]; then
      stage_newline=$(printf '\n_')
      stage_old_ifs=$IFS
      IFS=${stage_newline%_}
      set -f
      for stub_file in ${stub_files}; do
        stub_name=$(basename "${stub_file}")
        if [ -z "${hook_filter}" ] || [ "${hook_filter}" = "${stub_name}" ]; then
          stage_append_unique HOOK_SUMMARY_NAMES "${stub_name}"
        fi
      done
      set +f
      IFS=${stage_old_ifs}
    fi
  fi

  if [ -n "${hook_filter}" ]; then
    stage_append_unique HOOK_SUMMARY_NAMES "${hook_filter}"
  fi

  if [ -z "${HOOK_SUMMARY_NAMES}" ]; then
    githooks_log_info "no hooks detected"
    return 0
  fi

  set -f
  HOOK_SUMMARY_SORTED=$(printf '%s\n' ${HOOK_SUMMARY_NAMES} | LC_ALL=C sort)
  set +f
  stage_newline=$(printf '\n_')
  stage_old_ifs=$IFS
  IFS=${stage_newline%_}
  set -f
  printf '%s\n' 'HOOK                STUB  PARTS'
  for hook_name in ${HOOK_SUMMARY_SORTED}; do
    hook_stub_path="${hooks_target}/${hook_name}"
    if [ -f "${hook_stub_path}" ]; then
      hook_stub_status='yes'
    else
      hook_stub_status='no'
    fi
    parts_count=0
    hook_parts=$(githooks_list_parts "${hook_name}")
    if [ -n "${hook_parts}" ]; then
      stage_newline=$(printf '\n_')
      stage_inner_old_ifs=$IFS
      IFS=${stage_newline%_}
      set -f
      for hook_part in ${hook_parts}; do
        parts_count=$((parts_count + 1))
      done
      set +f
      IFS=${stage_inner_old_ifs}
    fi
    printf '%-18s %-4s  %d\n' "${hook_name}" "${hook_stub_status}" "${parts_count}"
  done
  set +f
  IFS=${stage_old_ifs}
}

config_show() {
  hooks_path=$(git config --path --get core.hooksPath 2>/dev/null || true)
  githooks_log_info "core.hooksPath=${hooks_path:-<unset>}"
  githooks_log_info "shared_root=$(githooks_shared_root)"
  githooks_log_info "hooks_root=$(githooks_hooks_root)"
}

config_set() {
  if [ "$#" -lt 2 ]; then
    githooks_die "config set requires key and value"
  fi
  cfg_key=$1
  cfg_value=$2
  case "${cfg_key}" in
    hooks-path)
      maybe_run "set core.hooksPath ${cfg_value}" git config core.hooksPath "${cfg_value}"
      ;;
    *)
      githooks_die "unknown config key: ${cfg_key}"
      ;;
  esac
}

shared_root=$(githooks_shared_root)
hooks_root=$(githooks_hooks_root)
runner_target="${shared_root%/}/_runner.sh"
lib_target="${shared_root%/}/lib/common.sh"


if githooks_is_bare_repo; then
  stub_runner='$(dirname "$0")/_runner.sh'
else
  stub_runner='$(git rev-parse --show-toplevel)/.githooks/_runner.sh'
fi

cmd_install() {
  INSTALL_RESOLVED_MODE=$(githooks_cli_resolve_mode "${CLI_INSTALL_MODE}" "$@")
  if [ "${INSTALL_RESOLVED_MODE}" = "ephemeral" ]; then
    cmd_install_ephemeral "$@"
    return 0
  fi
  if [ "$#" -gt 0 ]; then
    case "$1" in
      help)
        print_install_usage
        return 0
        ;;
    esac
  fi
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --hooks|-H)
        if [ "$#" -lt 2 ]; then
          githooks_die "--hooks requires an argument"
        fi
        parse_hook_list "$2"
        HOOKS_WERE_EXPLICIT=1
        shift 2
        ;;
      --hooks=*)
        parse_hook_list "${1#*=}"
        HOOKS_WERE_EXPLICIT=1
        shift
        ;;
      --all-hooks|-A|--all)
        USE_ALL=1
        HOOKS_WERE_EXPLICIT=1
        shift
        ;;
      --dry-run|-n)
        DRY_RUN=1
        shift
        ;;
      --force|-f)
        FORCE=1
        shift
        ;;
      -h|--help)
        print_install_usage
        return 0
        ;;
      help)
        print_install_usage
        return 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        githooks_die "unknown option for install: $1"
        ;;
      *)
        githooks_die "unexpected argument for install: $1"
        ;;
    esac
  done

  if [ "${USE_ALL}" -eq 1 ]; then
    HOOKS="${ALL_HOOKS}"
  fi

  install_runner
  for hook in ${HOOKS}; do
    create_parts_dir "${hook}"
    write_stub "${hook}"
  done
  githooks_log_info "installation complete"
}

cmd_install_ephemeral() {
  EPHEMERAL_MODE_OVERLAY=""
  EPHEMERAL_MODE_HOOKS=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mode)
        if [ "$#" -lt 2 ]; then
          githooks_die "--mode requires a value"
        fi
        githooks_cli_normalise_mode "$2" >/dev/null
        shift 2
        ;;
      --mode=*)
        githooks_cli_normalise_mode "${1#*=}" >/dev/null
        shift
        ;;
      --hooks|-H)
        if [ "$#" -lt 2 ]; then
          githooks_die "--hooks requires an argument"
        fi
        parse_hook_list "$2"
        HOOKS_WERE_EXPLICIT=1
        shift 2
        ;;
      --hooks=*)
        parse_hook_list "${1#*=}"
        HOOKS_WERE_EXPLICIT=1
        shift
        ;;
      --overlay)
        if [ "$#" -lt 2 ]; then
          githooks_die "--overlay requires a value"
        fi
        EPHEMERAL_MODE_OVERLAY=$(githooks_cli_normalise_overlay "$2")
        shift 2
        ;;
      --overlay=*)
        EPHEMERAL_MODE_OVERLAY=$(githooks_cli_normalise_overlay "${1#*=}")
        shift
        ;;
      --dry-run|-n)
        DRY_RUN=1
        shift
        ;;
      --force|-f)
        FORCE=1
        shift
        ;;
      -h|--help|help)
        print_install_usage
        return 0
        ;;
      --)
        shift
        break
        ;;
      -* )
        githooks_die "unknown option for install --mode ephemeral: $1"
        ;;
      *)
        githooks_die "unexpected argument for install --mode ephemeral: $1"
        ;;
    esac
  done

  if [ "$#" -gt 0 ]; then
    githooks_die "install --mode ephemeral does not accept positional arguments"
  fi

  if [ -n "${EPHEMERAL_MODE_OVERLAY}" ]; then
    GITHOOKS_EPHEMERAL_PRECEDENCE="${EPHEMERAL_MODE_OVERLAY}"
    export GITHOOKS_EPHEMERAL_PRECEDENCE
  fi

  EPHEMERAL_MODE_HOOKS="${HOOKS}"
  if [ "${HOOKS_WERE_EXPLICIT}" -eq 0 ]; then
    EPHEMERAL_MANIFEST_HOOKS=$(ephemeral_manifest_get MANAGED_HOOKS || true)
    if [ -n "${EPHEMERAL_MANIFEST_HOOKS}" ]; then
      EPHEMERAL_MODE_HOOKS="${EPHEMERAL_MANIFEST_HOOKS}"
    fi
  fi

  if [ -z "${EPHEMERAL_MODE_HOOKS}" ]; then
    githooks_die "Ephemeral Mode requires at least one managed hook"
  fi

  EPHEMERAL_MODE_HOOKS=$(printf '%s\n' "${EPHEMERAL_MODE_HOOKS}" | tr '\n' ' ')

  # shellcheck disable=SC2086
  ephemeral_install ${EPHEMERAL_MODE_HOOKS}

  EPHEMERAL_ACTIVE_PATH=$(ephemeral_hooks_path_absolute)
  EPHEMERAL_PRECEDENCE_MODE=$(ephemeral_precedence_mode)
  githooks_log_info "Ephemeral Mode hooks path: ${EPHEMERAL_ACTIVE_PATH}"
  githooks_log_info "Ephemeral precedence mode: ${EPHEMERAL_PRECEDENCE_MODE}"
  EPHEMERAL_OVERLAY_ROOTS=$(ephemeral_overlay_resolve_roots)
  ephemeral_overlay_log_roots "${EPHEMERAL_OVERLAY_ROOTS}"
}

cmd_stage_add() {
  if [ "$#" -eq 0 ]; then
    githooks_die "stage add requires a source directory"
  fi
  case "$1" in
    -h|--help|help)
      print_stage_add_usage
      return 0
      ;;
  esac
  stage_add_source "$1"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --for-hook|--hook)
        if [ "$#" -lt 2 ]; then
          githooks_die "--hook requires an argument"
        fi
        stage_add_hook "$2"
        shift 2
        ;;
      --for-hook=*|--hook=*)
        stage_add_hook "${1#*=}"
        shift
        ;;
      --name|--part)
        if [ "$#" -lt 2 ]; then
          githooks_die "--name requires an argument"
        fi
        stage_add_name "$2"
        shift 2
        ;;
      --name=*|--part=*)
        stage_add_name "${1#*=}"
        shift
        ;;
      --dry-run|-n)
        DRY_RUN=1
        shift
        ;;
      --force|-f)
        FORCE=1
        shift
        ;;
      -h|--help|help)
        print_stage_add_usage
        return 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        githooks_die "unknown option for stage add: $1"
        ;;
      *)
        githooks_die "unexpected argument for stage add: $1"
        ;;
    esac
  done
  if [ "$#" -gt 0 ]; then
    githooks_die "unexpected argument for stage add: $1"
  fi
  run_stage
}

cmd_stage_unstage() {
  if [ "$#" -eq 0 ]; then
    githooks_die "stage unstage requires a source directory"
  fi
  case "$1" in
    -h|--help|help)
      print_stage_unstage_usage
      return 0
      ;;
  esac
  stage_add_source "$1"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --for-hook|--hook)
        if [ "$#" -lt 2 ]; then
          githooks_die "--hook requires an argument"
        fi
        stage_add_hook "$2"
        shift 2
        ;;
      --for-hook=*|--hook=*)
        stage_add_hook "${1#*=}"
        shift
        ;;
      --name|--part)
        if [ "$#" -lt 2 ]; then
          githooks_die "--name requires an argument"
        fi
        stage_add_name "$2"
        shift 2
        ;;
      --name=*|--part=*)
        stage_add_name "${1#*=}"
        shift
        ;;
      --dry-run|-n)
        DRY_RUN=1
        shift
        ;;
      -h|--help|help)
        print_stage_unstage_usage
        return 0
        ;;
      --)
        shift
        break
        ;;
      -* )
        githooks_die "unknown option for stage unstage: $1"
        ;;
      *)
        githooks_die "unexpected argument for stage unstage: $1"
        ;;
    esac
  done
  if [ "$#" -gt 0 ]; then
    githooks_die "unexpected argument for stage unstage: $1"
  fi
  run_stage_unstage
}

cmd_stage_remove() {
  if [ "$#" -gt 0 ]; then
    case "$1" in
      -h|--help|help)
        print_stage_remove_usage
        return 0
        ;;
    esac
  fi
  if [ "$#" -eq 0 ]; then
    githooks_die "stage remove requires a hook name"
  fi
  stage_remove_hook=$1
  shift
  stage_remove_all=0
  stage_remove_name=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name|--part)
        if [ "$#" -lt 2 ]; then
          githooks_die "--name requires an argument"
        fi
        stage_remove_name=$2
        shift 2
        ;;
      --name=*|--part=*)
        stage_remove_name=${1#*=}
        shift
        ;;
      --all)
        stage_remove_all=1
        shift
        ;;
      --dry-run|-n)
        DRY_RUN=1
        shift
        ;;
      -h|--help|help)
        print_stage_remove_usage
        return 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        githooks_die "unknown option for stage remove: $1"
        ;;
      *)
        if [ -z "${stage_remove_name}" ]; then
          stage_remove_name=$1
          shift
        else
          githooks_die "unexpected argument for stage remove: $1"
        fi
        ;;
    esac
  done
  if [ "$#" -gt 0 ]; then
    githooks_die "unexpected argument for stage remove: $1"
  fi
  if [ "${stage_remove_all}" -eq 1 ] && [ -n "${stage_remove_name}" ]; then
    githooks_die "cannot combine --all with --name"
  fi
  if [ "${stage_remove_all}" -eq 1 ]; then
    stage_remove_all_parts "${stage_remove_hook}"
    return 0
  fi
  if [ -z "${stage_remove_name}" ]; then
    githooks_die "stage remove requires --name or positional script name"
  fi
  stage_remove_part "${stage_remove_hook}" "${stage_remove_name}"
}

cmd_stage_list() {
  if [ "$#" -gt 0 ]; then
    case "$1" in
      -h|--help|help)
        print_stage_list_usage
        return 0
        ;;
    esac
  fi
  stage_list_hook=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help|help)
        print_stage_list_usage
        return 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        githooks_die "unknown option for stage list: $1"
        ;;
      *)
        if [ -n "${stage_list_hook}" ]; then
          githooks_die "stage list accepts at most one hook"
        fi
        stage_list_hook=$1
        shift
        ;;
    esac
  done
  if [ "$#" -gt 0 ]; then
    githooks_die "unexpected argument for stage list: $1"
  fi
  STAGE_LIST_HEADER_SHOWN=0
  STAGE_LIST_PRINTED=0
  if [ -n "${stage_list_hook}" ]; then
    if ! stage_list_parts_for_hook "${stage_list_hook}"; then
      githooks_log_info "no hook parts staged for ${stage_list_hook}"
    fi
    return 0
  fi
  stage_list_all_parts
}

cmd_stage() {
  if [ "$#" -eq 0 ]; then
    cmd_stage_list
    return 0
  fi
  stage_subcommand=$1
  shift
  case "${stage_subcommand}" in
    add)
      cmd_stage_add "$@"
      ;;
    unstage)
      cmd_stage_unstage "$@"
      ;;
    remove)
      cmd_stage_remove "$@"
      ;;
    list)
      cmd_stage_list "$@"
      ;;
    -h|--help|help)
      if [ "$#" -eq 0 ]; then
        print_stage_usage
        return 0
      fi
      case "$1" in
        add)
          shift
          print_stage_add_usage
          ;;
        unstage)
          shift
          print_stage_unstage_usage
          ;;
        remove)
          shift
          print_stage_remove_usage
          ;;
        list)
          shift
          print_stage_list_usage
          ;;
        *)
          githooks_die "unknown stage help topic: $1"
          ;;
      esac
      ;;
    *)
      githooks_die "unknown stage subcommand: ${stage_subcommand}"
      ;;
  esac
}

cmd_hooks_list() {
  if [ "$#" -gt 0 ]; then
    case "$1" in
      -h|--help|help)
        print_hooks_list_usage
        return 0
        ;;
    esac
  fi
  hook_filter=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help|help)
        print_hooks_list_usage
        return 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        githooks_die "unknown option for hooks list: $1"
        ;;
      *)
        if [ -n "${hook_filter}" ]; then
          githooks_die "hooks list accepts at most one hook name"
        fi
        hook_filter=$1
        shift
        ;;
    esac
  done
  if [ "$#" -gt 0 ]; then
    githooks_die "unexpected argument for hooks list: $1"
  fi
  if [ -n "${hook_filter}" ]; then
    hooks_list_summary "${hook_filter}"
  else
    hooks_list_summary
  fi
}

cmd_hooks() {
  if [ "$#" -eq 0 ]; then
    hooks_list_summary
    return 0
  fi
  case "$1" in
    list)
      shift
      cmd_hooks_list "$@"
      ;;
    -h|--help|help)
      shift
      if [ "$#" -eq 0 ]; then
        print_hooks_usage
        return 0
      fi
      case "$1" in
        list)
          print_hooks_list_usage
          ;;
        *)
          githooks_die "unknown hooks help topic: $1"
          ;;
      esac
      ;;
    *)
      githooks_die "unknown hooks subcommand: $1"
      ;;
  esac
}

cmd_config() {
  if [ "$#" -eq 0 ]; then
    config_show
    return 0
  fi
  case "$1" in
    help|-h|--help)
      shift
      if [ "$#" -eq 0 ]; then
        print_config_usage
        return 0
      fi
      case "$1" in
        show)
          print_config_show_usage
          ;;
        set)
          print_config_set_usage
          ;;
        *)
          githooks_die "unknown config help topic: $1"
          ;;
      esac
      return 0
      ;;
    show)
      shift
      if [ "$#" -gt 0 ] && [ "$1" = "help" ]; then
        print_config_show_usage
        return 0
      fi
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -h|--help|help)
            print_config_show_usage
            return 0
            ;;
          --)
            shift
            break
            ;;
          -*)
            githooks_die "unknown option for config show: $1"
            ;;
          *)
            githooks_die "unexpected argument for config show: $1"
            ;;
        esac
      done
      if [ "$#" -gt 0 ]; then
        githooks_die "unexpected argument for config show: $1"
      fi
      config_show
      ;;
    set)
      shift
      if [ "$#" -gt 0 ] && [ "$1" = "help" ]; then
        print_config_set_usage
        return 0
      fi
      if [ "$#" -lt 2 ]; then
        githooks_die "config set requires key and value"
      fi
      cfg_key=$1
      cfg_value=$2
      shift 2
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -h|--help|help)
            print_config_set_usage
            return 0
            ;;
          --)
            shift
            break
            ;;
          -*)
            githooks_die "unknown option for config set: $1"
            ;;
          *)
            githooks_die "unexpected argument for config set: $1"
            ;;
        esac
      done
      if [ "$#" -gt 0 ]; then
        githooks_die "unexpected argument for config set: $1"
      fi
      config_set "${cfg_key}" "${cfg_value}"
      ;;
    *)
      githooks_die "unknown config subcommand: $1"
      ;;
  esac
}

cmd_uninstall() {
  UNINSTALL_RESOLVED_MODE=$(githooks_cli_resolve_mode "${CLI_INSTALL_MODE}" "$@")
  if [ "${UNINSTALL_RESOLVED_MODE}" = "ephemeral" ]; then
    cmd_uninstall_ephemeral "$@"
    return 0
  fi
  if [ "$#" -gt 0 ]; then
    case "$1" in
      -h|--help|help)
        print_uninstall_usage
        return 0
        ;;
    esac
  fi
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run|-n)
        DRY_RUN=1
        shift
        ;;
      -h|--help|help)
        print_uninstall_usage
        return 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        githooks_die "unknown option for uninstall: $1"
        ;;
      *)
        githooks_die "unexpected argument for uninstall: $1"
        ;;
    esac
  done
  if [ "$#" -gt 0 ]; then
    githooks_die "unexpected argument for uninstall: $1"
  fi
  for hook in ${HOOKS}; do
    uninstall_stub "${hook}"
  done
  remove_runner_files
  githooks_log_info "uninstallation complete"
}

cmd_uninstall_ephemeral() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mode)
        if [ "$#" -lt 2 ]; then
          githooks_die "--mode requires a value"
        fi
        githooks_cli_normalise_mode "$2" >/dev/null
        shift 2
        ;;
      --mode=*)
        githooks_cli_normalise_mode "${1#*=}" >/dev/null
        shift
        ;;
      --dry-run|-n)
        DRY_RUN=1
        shift
        ;;
      --force|-f)
        FORCE=1
        shift
        ;;
      -h|--help|help)
        print_uninstall_usage
        return 0
        ;;
      --overlay*|--hooks* )
        githooks_die "uninstall --mode ephemeral does not support $1"
        ;;
      --)
        shift
        break
        ;;
      -* )
        githooks_die "unknown option for uninstall --mode ephemeral: $1"
        ;;
      *)
        githooks_die "unexpected argument for uninstall --mode ephemeral: $1"
        ;;
    esac
  done

  if [ "$#" -gt 0 ]; then
    githooks_die "uninstall --mode ephemeral does not accept positional arguments"
  fi

  EPHEMERAL_TARGET_PATH=$(ephemeral_hooks_path_absolute)
  EPHEMERAL_PREVIOUS_CONFIG=$(ephemeral_manifest_get PREVIOUS_CORE_HOOKS_PATH || true)

  ephemeral_uninstall

  if [ -n "${EPHEMERAL_TARGET_PATH}" ]; then
    githooks_log_info "Ephemeral Mode hooks path cleared: ${EPHEMERAL_TARGET_PATH}"
  fi
  if [ -n "${EPHEMERAL_PREVIOUS_CONFIG}" ]; then
    githooks_log_info "core.hooksPath restored to ${EPHEMERAL_PREVIOUS_CONFIG}"
  else
    githooks_log_info "core.hooksPath restored to repository default"
  fi
}

cmd_help() {
  if [ "$#" -eq 0 ]; then
    print_usage
    return 0
  fi
  topic=$1
  shift
  case "${topic}" in
    install)
      print_install_usage
      ;;
    stage)
      if [ "$#" -eq 0 ]; then
        print_stage_usage
      else
        case "$1" in
          add)
            print_stage_add_usage
            ;;
          unstage)
            print_stage_unstage_usage
            ;;
          remove)
            print_stage_remove_usage
            ;;
          list)
            print_stage_list_usage
            ;;
          *)
            githooks_die "unknown stage help topic: $1"
            ;;
        esac
      fi
      ;;
    hooks)
      if [ "$#" -eq 0 ]; then
        print_hooks_usage
      else
        case "$1" in
          list)
            print_hooks_list_usage
            ;;
          *)
            githooks_die "unknown hooks help topic: $1"
            ;;
        esac
      fi
      ;;
    config)
      if [ "$#" -eq 0 ]; then
        print_config_usage
      else
        case "$1" in
          show)
            print_config_show_usage
            ;;
          set)
            print_config_set_usage
            ;;
          *)
            githooks_die "unknown config help topic: $1"
            ;;
        esac
      fi
      ;;
    uninstall)
      print_uninstall_usage
      ;;
    help)
      print_usage
      ;;
    *)
      githooks_die "unknown help topic: ${topic}"
      ;;
  esac
}

cmd_unknown() {
  githooks_die "unknown command: $1"
}

GLOBAL_SHOW_HELP=0
GLOBAL_SHOW_VERSION=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      GLOBAL_SHOW_HELP=1
      shift
      ;;
    -V|--version)
      GLOBAL_SHOW_VERSION=1
      shift
      ;;
    -n|--dry-run)
      DRY_RUN=1
      shift
      ;;
    --mode)
      if [ "$#" -lt 2 ]; then
        githooks_die "--mode requires a value"
      fi
      CLI_INSTALL_MODE=$(githooks_cli_normalise_mode "$2")
      shift 2
      ;;
    --mode=*)
      CLI_INSTALL_MODE=$(githooks_cli_normalise_mode "${1#*=}")
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      break
      ;;
    *)
      break
      ;;
  esac
done

if [ "${GLOBAL_SHOW_VERSION}" -eq 1 ]; then
  printf 'githooks-runner %s\n' "${TOOLKIT_VERSION}"
  if [ "$#" -eq 0 ] && [ "${GLOBAL_SHOW_HELP}" -eq 0 ]; then
    exit 0
  fi
fi

if [ "${GLOBAL_SHOW_HELP}" -eq 1 ] && [ "$#" -eq 0 ]; then
  print_usage
  exit 0
fi

if [ "$#" -eq 0 ]; then
  COMMAND="install"
else
  COMMAND=$1
  shift
fi

if [ "${GLOBAL_SHOW_HELP}" -eq 1 ]; then
  cmd_help "${COMMAND}" "$@"
  exit 0
fi

case "${COMMAND}" in
  install)
    cmd_install "$@"
    ;;
  stage)
    cmd_stage "$@"
    ;;
  hooks)
    cmd_hooks "$@"
    ;;
  config)
    cmd_config "$@"
    ;;
  uninstall)
    cmd_uninstall "$@"
    ;;
  help)
    cmd_help "$@"
    ;;
  init)
    compat_warn "init"
    cmd_install "$@"
    ;;
  add)
    compat_warn "add"
    cmd_stage_add "$@"
    ;;
  remove)
    compat_warn "remove"
    cmd_stage_remove "$@"
    ;;
  *)
    cmd_unknown "${COMMAND}"
    ;;
esac

