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

print_usage() {
  cat <<'HELP'
NAME
    install.sh - Install, update, or remove the Git Hooks Runner Toolkit.

SYNOPSIS
    install.sh COMMAND [OPTIONS]

DESCRIPTION
    This script manages the installation and configuration of the Git Hooks Runner
    Toolkit in your repository. It creates a shared runner, a library of helper
    functions, and stub dispatchers for the hooks you want to manage.

    The toolkit allows you to create composable, version-controlled Git hooks that
    are easy to maintain. Instead of a single, monolithic hook script, you can
    have multiple "hook parts" that are executed in lexical order.

COMMANDS
    init
        Install the toolkit and create hook stubs. This is the default command.

        --hooks HOOKS
            A comma-separated list of hook names to manage.
        --all-hooks
            Manage every hook that Git documents.
        --force
            Overwrite existing hook stubs.

    add SOURCE
        Add a hook script from a source directory. The special keywords "examples"
        and "hooks" can be used to refer to the bundled examples and hooks.

        --for-hook HOOK
            Target a specific hook.

    remove HOOK SCRIPT_NAME
        Remove a hook script.

    uninstall
        Remove the runner artifacts and any managed hook stubs.

    help
        Show this help message.

OPTIONS
    -n, --dry-run
        Print the planned actions without actually touching the filesystem.
        This is useful for testing and debugging.

    -f, --force
        Overwrite existing hook stubs, even if they were not created by this
        toolkit.

    -h, --help
        Show this help message.

EXAMPLES
    Install the default set of hooks:
        install.sh

    Install only the pre-commit and post-merge hooks:
        install.sh init --hooks pre-commit,post-merge

    Add all the included examples:
        install.sh add examples

    Add only the dependency-sync.sh example for the post-merge hook:
        install.sh add examples --for-hook post-merge

    Remove a hook script:
        install.sh remove post-merge dependency-sync.sh

    Uninstall all managed hooks:
        install.sh uninstall

FILES
    .githooks/
        The directory where the shared runner, library, and hook parts are
        stored.

    .githooks/_runner.sh
        The shared hook runner.

    .githooks/lib/common.sh
        A library of shared helper functions.

    .githooks/<hook>.d/
        The directory where the hook parts for a specific hook are stored.

    .git/hooks/<hook>
        The hook stub that delegates to the shared runner.

SEE ALSO
    githooks(1)
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
  if [ "${DRY_RUN}" -eq 1 ]; then
    log_action "DRY-RUN: remove ${runner_target}"
    log_action "DRY-RUN: remove ${lib_target}"
    return 0
  fi
  rm -f "${runner_target}" "${lib_target}"
  githooks_log_info "removed runner artefacts from ${shared_root}"
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

stage_name_allowed() {
  stage_basename=$1
  if [ -z "${STAGE_NAME_FILTERS_ORDERED}" ]; then
    return 0
  fi
  if stage_list_contains "${STAGE_NAME_FILTERS_ORDERED}" "${stage_basename}"; then
    return 0
  fi
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
    if [ "${stage_basename}" = "${stage_name_filter}" ]; then
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

run_stage() {
  STAGE_COPY_COUNT=0
  STAGE_SKIP_IDENTICAL=0
  STAGE_SKIPPED_FILES=0
  STAGE_RUNNER_READY=0
  if [ "${STAGE_LEGACY_USED}" -eq 1 ]; then
    githooks_log_warn "stage: legacy selector syntax detected; prefer --stage-source/--stage-hook/--stage-name"
  fi
  stage_ensure_default_sources
  stage_prepare_plan_file
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
  if [ "${STAGE_PLAN_COUNT}" -eq 0 ]; then
    if stage_summary_requested; then
      githooks_log_info "PLAN: no matching files"
    fi
    if [ "${DRY_RUN}" -eq 1 ]; then
      githooks_log_info "stage dry-run complete"
    else
      githooks_log_info "stage complete: 0 file(s) updated"
      if [ "${STAGE_SKIPPED_FILES}" -gt 0 ]; then
        githooks_log_info "stage skipped ${STAGE_SKIPPED_FILES} file(s) due to filters or missing metadata"
      fi
    fi
    stage_cleanup_plan
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

if [ "$#" -eq 0 ]; then
  COMMAND="init"
else
  COMMAND=$1
  shift
fi

shared_root=$(githooks_shared_root)
hooks_root=$(githooks_hooks_root)
runner_target="${shared_root%/}/_runner.sh"
lib_target="${shared_root%/}/lib/common.sh"


if githooks_is_bare_repo; then
  stub_runner='$(dirname "$0")/_runner.sh'
else
  stub_runner='$(git rev-parse --show-toplevel)/.githooks/_runner.sh'
fi

case "${MODE}" in
  install)
    install_runner
    for hook in ${HOOKS}; do
      create_parts_dir "${hook}"
      write_stub "${hook}"
    done
    githooks_log_info "installation complete"
    ;;
  uninstall)
    for hook in ${HOOKS}; do
      uninstall_stub "${hook}"
    done
    remove_runner_files
    githooks_log_info "uninstallation complete"
    ;;
  stage)
    if run_stage; then
    exit 0
  fi
  exit 1
}

cmd_init() {
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
      --all-hooks|-A)
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
        print_usage
        exit 0
        ;;
      *)
        githooks_die "unknown option for init: $1"
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

cmd_add() {
  if [ "$#" -eq 0 ]; then
    githooks_die "add command requires a source"
  fi
  stage_add_source "$1"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --for-hook)
        if [ "$#" -lt 2 ]; then
          githooks_die "--for-hook requires an argument"
        fi
        stage_add_hook "$2"
        shift 2
        ;;
      --for-hook=*)
        stage_add_hook "${1#*=}"
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
        print_usage
        exit 0
        ;;
      *)
        githooks_die "unknown option for add: $1"
        ;;
    esac
  done
  run_stage
}

cmd_remove() {
  if [ "$#" -ne 2 ]; then
    githooks_die "remove command requires hook and script name"
  fi
  remove_hook_part "$1" "$2"
}

cmd_uninstall() {
    while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run|-n)
        DRY_RUN=1
        shift
        ;;
      *)
        githooks_die "unknown option for uninstall: $1"
        ;;
    esac
  done
  for hook in ${HOOKS}; do
    uninstall_stub "${hook}"
  done
  remove_runner_files
  githooks_log_info "uninstallation complete"
}

cmd_help() {
  print_usage
}

cmd_unknown() {
  githooks_die "unknown command: $1"
}

if [ "$#" -eq 0 ]; then
  COMMAND="init"
else
  COMMAND=$1
  shift
fi

case "${COMMAND}" in
  init)
    cmd_init "$@"
    ;;
  add)
    cmd_add "$@"
    ;;
  remove)
    cmd_remove "$@"
    ;;
  uninstall)
    cmd_uninstall "$@"
    ;;
  help)
    cmd_help "$@"
    ;;
  *)
    cmd_unknown "${COMMAND}"
    ;;
esac

