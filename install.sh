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
# shellcheck source=scripts/git-hooks/lib/common.sh
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

Post-install verification (recommended):
  sh scripts/git-hooks/tests/test_git_hooks_runner.sh

Rollback:
  scripts/git-hooks/install.sh --uninstall
  # restores Git's default hooks for managed entries

Options:
  --hooks HOOK1,HOOK2   Comma-separated hook names to manage (defaults below).
  --all-hooks           Manage every hook Git documents (client + server).
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
HELP
}

DEFAULT_HOOKS="post-merge post-rewrite post-checkout pre-commit prepare-commit-msg commit-msg post-commit pre-push"

ALL_HOOKS="applypatch-msg pre-applypatch post-applypatch pre-commit prepare-commit-msg commit-msg post-commit pre-merge-commit pre-rebase post-checkout post-merge post-rewrite pre-push pre-receive update post-receive post-update reference-transaction push-to-checkout proc-receive pre-auto-gc post-index-change sendemail-validate fsmonitor-watchman p4-changelist p4-prepare-changelist p4-post-changelist p4-pre-submit p4-post-submit"

MODE="install"
DRY_RUN=0
FORCE=0
HOOKS="${DEFAULT_HOOKS}"
USE_ALL=0

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
  IFS=$_saved_ifs
  for _hook_item in "$@"; do
    _trimmed=$(printf '%s' "$_hook_item" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
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

while [ "$#" -gt 0 ]; do
  case "$1" in
    --hooks)
      if [ "$#" -lt 2 ]; then
        githooks_die "--hooks requires an argument"
      fi
      parse_hook_list "$2"
      shift 2
      ;;
    --hooks=*)
      parse_hook_list "${1#*=}"
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
      shift
      ;;
    --all-hooks)
      USE_ALL=1
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

shared_root=$(githooks_shared_root)
hooks_root=$(githooks_hooks_root)
runner_target="${shared_root%/}/_runner.sh"
lib_target="${shared_root%/}/lib/common.sh"

if githooks_is_bare_repo; then
  stub_runner='$(dirname "\$0")/_runner.sh'
else
  stub_runner='$(git rev-parse --show-toplevel)/.githooks/_runner.sh'
fi

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
  *)
    githooks_die "unknown mode: ${MODE}"
    ;;
esac
