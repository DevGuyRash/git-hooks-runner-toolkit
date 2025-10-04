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
Usage: scripts/git-hooks/install.sh [options]

Provision, update, or remove the git-hooks-runner toolkit in the
current repository. By default a curated set of client-side hooks are
installed under `.githooks/` and wired into `.git/hooks/` stubs that
delegate to the shared runner.

Common flows:
  scripts/git-hooks/install.sh
  scripts/git-hooks/install.sh --hooks post-merge,post-rewrite
  scripts/git-hooks/install.sh --uninstall --hooks post-merge
  scripts/git-hooks/install.sh --stage
  scripts/git-hooks/install.sh --stage=examples --hooks pre-commit

Post-install verification (recommended):
  sh scripts/git-hooks/tests/test_git_hooks_runner.sh

Rollback:
  scripts/git-hooks/install.sh --uninstall
  # restores Git's default hooks for managed entries

Options:
  --hooks HOOK1,HOOK2   Comma-separated hook names to manage (defaults below).
  --all-hooks           Manage every hook Git documents (client + server).
  --stage[=SELECTORS]   Stage hook parts from toolkit directories into .githooks/.
  --dry-run             Print planned actions without touching the filesystem.
  --force               Overwrite existing hook stubs even if they already exist.
  --uninstall           Remove runner artefacts and managed stubs instead of installing.
  -h, --help            Show this help message.

Notes:
  - Default hooks: post-merge, post-rewrite, post-checkout, pre-commit,
    prepare-commit-msg, commit-msg, post-commit, pre-push.
  - Managed stubs include an audit string so unrelated hooks are left untouched.
  - Parts live in `.githooks/<hook>.d/`; add scripts there to compose behaviour.
  - For automated environments, run in `--dry-run` first to review planned changes.
  - `--stage` selectors: `all` (default), `examples`, `hooks`, `source:<dir>`,
    `hook:<name>`, `name:<file>`, or bare hook names (comma-separated).
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
STAGE_SELECTOR_RAW=""

STAGE_SOURCE_DIRS=""
STAGE_HOOK_FILTERS=""
STAGE_NAME_FILTERS=""
STAGE_RUNNER_READY=0
STAGE_COPY_COUNT=0
STAGE_SKIP_IDENTICAL=0
STAGE_SKIPPED_FILES=0
STAGE_DETECTED_HOOKS=""
STAGE_DETECTED_SOURCE="none"

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
  if ! grep -q 'generated by git-hooks-runner' "${stub_path}" 2>/dev/null; then
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
  for stage_item in ${stage_list}; do
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

parse_stage_selectors() {
  STAGE_SOURCE_DIRS=""
  STAGE_HOOK_FILTERS=""
  STAGE_NAME_FILTERS=""
  stage_include_examples=0
  stage_include_hooks=0
  stage_raw=${STAGE_SELECTOR_RAW}
  if [ -z "${stage_raw}" ]; then
    stage_raw="all"
  fi
  stage_saved_ifs=$IFS
  IFS=','
  set -f
  set -- ${stage_raw}
  set +f
  IFS=${stage_saved_ifs}
  for stage_selector in "$@"; do
    stage_trimmed=$(printf '%s' "${stage_selector}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [ -z "${stage_trimmed}" ]; then
      continue
    fi
    case "${stage_trimmed}" in
      all)
        stage_include_examples=1
        stage_include_hooks=1
        ;;
      examples)
        stage_include_examples=1
        ;;
      hooks)
        stage_include_hooks=1
        ;;
      source:*)
        stage_path=${stage_trimmed#source:}
        stage_path_trim=$(printf '%s' "${stage_path}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        if [ -n "${stage_path_trim}" ]; then
          stage_abs=$(stage_resolve_source_dir "${stage_path_trim}")
          stage_append_unique STAGE_SOURCE_DIRS "${stage_abs}"
        fi
        ;;
      hook:*)
        stage_hook=${stage_trimmed#hook:}
        stage_hook_trim=$(printf '%s' "${stage_hook}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        if [ -n "${stage_hook_trim}" ]; then
          stage_append_unique STAGE_HOOK_FILTERS "${stage_hook_trim}"
        fi
        ;;
      name:*)
        stage_name=${stage_trimmed#name:}
        stage_name_trim=$(printf '%s' "${stage_name}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        if [ -n "${stage_name_trim}" ]; then
          stage_append_unique STAGE_NAME_FILTERS "${stage_name_trim}"
        fi
        ;;
      *)
        stage_append_unique STAGE_HOOK_FILTERS "${stage_trimmed}"
        ;;
    esac
  done
  if [ "${stage_include_examples}" -eq 1 ]; then
    stage_append_unique STAGE_SOURCE_DIRS "${SCRIPT_DIR%/}/examples"
  fi
  if [ "${stage_include_hooks}" -eq 1 ]; then
    stage_append_unique STAGE_SOURCE_DIRS "${SCRIPT_DIR%/}/hooks"
  fi
  if [ -z "${STAGE_SOURCE_DIRS}" ]; then
    stage_append_unique STAGE_SOURCE_DIRS "${SCRIPT_DIR%/}/examples"
    stage_append_unique STAGE_SOURCE_DIRS "${SCRIPT_DIR%/}/hooks"
  fi
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
  if [ -n "${STAGE_HOOK_FILTERS}" ]; then
    if stage_list_contains "${STAGE_HOOK_FILTERS}" "${stage_hook}"; then
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

stage_apply_hook_filters() {
  stage_input_hooks=$1
  stage_result=""
  for stage_hook in ${stage_input_hooks}; do
    if stage_hook_allowed "${stage_hook}"; then
      if [ -z "${stage_result}" ]; then
        stage_result="${stage_hook}"
      else
        stage_result="${stage_result} ${stage_hook}"
      fi
    fi
  done
  printf '%s' "${stage_result}"
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
    if grep -q 'generated by git-hooks-runner' "${stage_stub_path}" 2>/dev/null; then
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
  if [ -z "${STAGE_NAME_FILTERS}" ]; then
    return 1
  fi
  for stage_name_filter in ${STAGE_NAME_FILTERS}; do
    if [ "${stage_basename}" = "${stage_name_filter}" ]; then
      return 1
    fi
  done
  return 0
}

stage_process_file() {
  stage_file=$1
  stage_root=$2
  stage_basename=$(basename "${stage_file}")
  if stage_name_filtered_out "${stage_basename}"; then
    STAGE_SKIPPED_FILES=$((STAGE_SKIPPED_FILES + 1))
    githooks_log_info "stage skip ${stage_basename}: filtered by name"
    return 0
  fi
  stage_detect_hooks_for_file "${stage_file}" "${stage_root}"
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
  stage_hooks=$(stage_apply_hook_filters "${stage_hooks}")
  if [ -z "${stage_hooks}" ]; then
    STAGE_SKIPPED_FILES=$((STAGE_SKIPPED_FILES + 1))
    githooks_log_info "stage skip ${stage_basename}: filtered by hook selectors"
    return 0
  fi
  case "${stage_file}" in
    "${stage_root%/}"/*)
      stage_rel_path=${stage_file#${stage_root%/}/}
      ;;
    *)
      stage_rel_path=${stage_basename}
      ;;
  esac
  stage_hook_saved_ifs=$IFS
  IFS=' '
  for stage_hook in ${stage_hooks}; do
    parts_dir=$(githooks_parts_dir "${stage_hook}")
    create_parts_dir "${stage_hook}"
    stage_ensure_stub "${stage_hook}"
    stage_dest="${parts_dir%/}/${stage_basename}"
    githooks_log_info "stage plan ${stage_rel_path} -> ${stage_hook}"
    stage_copy_part "${stage_file}" "${stage_dest}"
  done
  IFS=${stage_hook_saved_ifs}
}

run_stage() {
  STAGE_COPY_COUNT=0
  STAGE_SKIP_IDENTICAL=0
  STAGE_SKIPPED_FILES=0
  STAGE_RUNNER_READY=0
  parse_stage_selectors
  stage_any_source=0
  for stage_source in ${STAGE_SOURCE_DIRS}; do
    stage_any_source=1
    if [ ! -d "${stage_source}" ]; then
      githooks_log_warn "stage source missing: ${stage_source}"
      continue
    fi
    stage_candidates=$(LC_ALL=C find -L "${stage_source}" -type f -perm -u+x -name '*.sh' -print 2>/dev/null | LC_ALL=C sort)
    if [ -z "${stage_candidates}" ]; then
      continue
    fi
    stage_saved_ifs=$IFS
    stage_newline=$(printf '\n_')
    IFS=${stage_newline%_}
    set -f
    set -- ${stage_candidates}
    for stage_candidate do
      stage_process_file "${stage_candidate}" "${stage_source}"
    done
    set +f
    IFS=${stage_saved_ifs}
  done
  if [ "${stage_any_source}" -eq 0 ]; then
    githooks_log_warn "stage aborted: no source directories available"
    return 1
  fi
  if [ "${DRY_RUN}" -eq 1 ]; then
    githooks_log_info "stage dry-run complete"
  else
    githooks_log_info "stage complete: ${STAGE_COPY_COUNT} file(s) updated"
    if [ "${STAGE_SKIP_IDENTICAL}" -gt 0 ]; then
      githooks_log_info "stage skipped ${STAGE_SKIP_IDENTICAL} identical file(s)"
    fi
    if [ "${STAGE_SKIPPED_FILES}" -gt 0 ]; then
      githooks_log_info "stage skipped ${STAGE_SKIPPED_FILES} file(s) due to filters or missing metadata"
    fi
  fi
  return 0
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --hooks)
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
    --stage)
      REQUEST_STAGE=1
      MODE="stage"
      if [ -z "${STAGE_SELECTOR_RAW}" ]; then
        STAGE_SELECTOR_RAW="all"
      else
        STAGE_SELECTOR_RAW="${STAGE_SELECTOR_RAW},all"
      fi
      shift
      ;;
    --stage=*)
      REQUEST_STAGE=1
      MODE="stage"
      _stage_value=${1#*=}
      if [ -z "${STAGE_SELECTOR_RAW}" ]; then
        STAGE_SELECTOR_RAW="${_stage_value}"
      else
        STAGE_SELECTOR_RAW="${STAGE_SELECTOR_RAW},${_stage_value}"
      fi
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --uninstall)
      MODE="uninstall"
      REQUEST_UNINSTALL=1
      shift
      ;;
    --all-hooks)
      USE_ALL=1
      HOOKS_WERE_EXPLICIT=1
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      githooks_die "unknown option: $1"
      ;;
  esac
done

if [ "${USE_ALL}" -eq 1 ]; then
  HOOKS="${ALL_HOOKS}"
fi

if [ "${REQUEST_STAGE}" -eq 1 ] && [ "${REQUEST_UNINSTALL}" -eq 1 ]; then
  githooks_die "--stage cannot be combined with --uninstall"
fi

if [ "${MODE}" = "stage" ] && [ -z "${STAGE_SELECTOR_RAW}" ]; then
  STAGE_SELECTOR_RAW="all"
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
    ;;
  *)
    githooks_die "unknown mode: ${MODE}"
    ;;
esac
