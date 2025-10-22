#!/bin/sh
# Ephemeral Mode lifecycle helpers. Provides install, refresh, and uninstall
# flows that keep toolkit assets under .git/.githooks without touching tracked
# files, while snapshotting and restoring the prior hooks configuration.

# shellcheck disable=SC2155
GITHOOKS_EPHEMERAL_VERSION=${GITHOOKS_EPHEMERAL_VERSION:-1}

# Return 0 when global DRY_RUN flag is enabled.
ephemeral_in_dry_run() {
  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    return 0
  fi
  return 1
}

# Resolve the toolkit root for runner/library sources.
ephemeral_toolkit_root() {
  if [ -n "${GITHOOKS_EPHEMERAL_TOOLKIT_DIR:-}" ]; then
    printf '%s\n' "${GITHOOKS_EPHEMERAL_TOOLKIT_DIR}"
    return 0
  fi
  if [ -n "${SCRIPT_DIR:-}" ]; then
    printf '%s\n' "${SCRIPT_DIR}"
    return 0
  fi
  githooks_die "Ephemeral lifecycle requires SCRIPT_DIR or GITHOOKS_EPHEMERAL_TOOLKIT_DIR"
}

# Determine the on-disk root (absolute) hosting ephemeral artefacts.
ephemeral_root_dir() {
  _ephemeral_git_dir=$(githooks_repo_git_dir)
  printf '%s/.githooks\n' "${_ephemeral_git_dir%/}"
}

ephemeral_manifest_path() {
  printf '%s/manifest.sh\n' "$(ephemeral_root_dir)"
}

# Value to store in core.hooksPath for non-bare and bare repositories.
ephemeral_hooks_config_value() {
  if githooks_is_bare_repo; then
    printf '%s\n' '.githooks'
    return 0
  fi
  printf '%s\n' '.git/.githooks'
}

# Absolute directory Git will read hook scripts from after install.
ephemeral_hooks_path_absolute() {
  _ephemeral_git_dir=$(githooks_repo_git_dir)
  if githooks_is_bare_repo; then
    printf '%s/.githooks\n' "${_ephemeral_git_dir%/}"
    return 0
  fi
  printf '%s/.githooks\n' "${_ephemeral_git_dir%/}"
}

ephemeral_precedence_mode() {
  if [ -n "${GITHOOKS_EPHEMERAL_PRECEDENCE:-}" ]; then
    printf '%s\n' "${GITHOOKS_EPHEMERAL_PRECEDENCE}"
    return 0
  fi
  _ephemeral_config=$(git config --local --get githooks.ephemeral.precedence 2>/dev/null || true)
  if [ -n "${_ephemeral_config}" ]; then
    printf '%s\n' "${_ephemeral_config}"
    return 0
  fi
  printf '%s\n' 'ephemeral-first'
}

ephemeral_manifest_roots() {
  _ephemeral_primary_root=$(ephemeral_root_dir)
  printf '%s\n' "${_ephemeral_primary_root}"
}

ephemeral_runner_target() {
  printf '%s/_runner.sh\n' "$(ephemeral_root_dir)"
}

ephemeral_common_library_target() {
  printf '%s/lib/common.sh\n' "$(ephemeral_root_dir)"
}

ephemeral_lib_dir() {
  printf '%s/lib\n' "$(ephemeral_root_dir)"
}

ephemeral_current_hooks_path() {
  git config --local --get core.hooksPath 2>/dev/null || true
}

ephemeral_shell_quote() {
  _ephemeral_value=${1-}
  printf "'%s'\n" "$(printf '%s' "${_ephemeral_value}" | sed "s/'/'\"'\"'/g")"
}

ephemeral_manifest_get() {
  _ephemeral_key=$1
  _ephemeral_manifest=$(ephemeral_manifest_path)
  if [ ! -f "${_ephemeral_manifest}" ]; then
    return 1
  fi
  _ephemeral_line=$(grep -E "^${_ephemeral_key}=" "${_ephemeral_manifest}" 2>/dev/null | tail -1 || true)
  if [ -z "${_ephemeral_line}" ]; then
    return 1
  fi
  _ephemeral_value=${_ephemeral_line#*=}
  _ephemeral_value=${_ephemeral_value#\'}
  _ephemeral_value=${_ephemeral_value%\'}
  printf '%s\n' "$(printf '%s' "${_ephemeral_value}" | sed "s/'\"'\"'/'/g")"
  return 0
}

ephemeral_manifest_write() {
  _ephemeral_previous=$1
  _ephemeral_active=$2
  _ephemeral_hooks=$3
  _ephemeral_action=$4
  _ephemeral_manifest=$(ephemeral_manifest_path)
  if ephemeral_in_dry_run; then
    githooks_log_info "DRY-RUN: write manifest ${_ephemeral_manifest}"
    return 0
  fi
  _ephemeral_root_dir=$(ephemeral_root_dir)
  if [ ! -d "${_ephemeral_root_dir}" ]; then
    githooks_mkdir_p "${_ephemeral_root_dir}"
  fi
  _ephemeral_timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')
  _ephemeral_tmp="${_ephemeral_manifest}.tmp.$$"
  _ephemeral_precedence=$(ephemeral_precedence_mode)
  _ephemeral_roots=$(ephemeral_manifest_roots)
  {
    printf 'VERSION=%s\n' "$(ephemeral_shell_quote "${GITHOOKS_EPHEMERAL_VERSION}")"
    printf 'INSTALL_MODE=%s\n' "'ephemeral'"
    printf 'LAST_ACTION=%s\n' "$(ephemeral_shell_quote "${_ephemeral_action}")"
    printf 'UPDATED_AT=%s\n' "$(ephemeral_shell_quote "${_ephemeral_timestamp}")"
    printf 'PREVIOUS_CORE_HOOKS_PATH=%s\n' "$(ephemeral_shell_quote "${_ephemeral_previous}")"
    printf 'ACTIVE_CORE_HOOKS_PATH=%s\n' "$(ephemeral_shell_quote "${_ephemeral_active}")"
    printf 'MANAGED_HOOKS=%s\n' "$(ephemeral_shell_quote "${_ephemeral_hooks}")"
    printf 'PRECEDENCE_MODE=%s\n' "$(ephemeral_shell_quote "${_ephemeral_precedence}")"
    printf 'ROOTS=%s\n' "$(ephemeral_shell_quote "${_ephemeral_roots}")"
  } >"${_ephemeral_tmp}" || githooks_die "Failed to build manifest ${_ephemeral_tmp}"
  mv "${_ephemeral_tmp}" "${_ephemeral_manifest}" || githooks_die "Failed to publish manifest ${_ephemeral_manifest}"
  githooks_chmod 600 "${_ephemeral_manifest}"
}

ephemeral_set_core_hooks_path() {
  _ephemeral_target=$1
  if ephemeral_in_dry_run; then
    githooks_log_info "DRY-RUN: set core.hooksPath -> ${_ephemeral_target}"
    return 0
  fi
  if ! git config --local core.hooksPath "${_ephemeral_target}"; then
    githooks_die "Failed to set core.hooksPath to ${_ephemeral_target}"
  fi
}

ephemeral_restore_previous_hooks_path() {
  _ephemeral_previous=$1
  if ephemeral_in_dry_run; then
    if [ -n "${_ephemeral_previous}" ]; then
      githooks_log_info "DRY-RUN: restore core.hooksPath -> ${_ephemeral_previous}"
    else
      githooks_log_info 'DRY-RUN: unset core.hooksPath'
    fi
    return 0
  fi
  if [ -n "${_ephemeral_previous}" ]; then
    if ! git config --local core.hooksPath "${_ephemeral_previous}"; then
      githooks_die "Failed to restore core.hooksPath to ${_ephemeral_previous}"
    fi
    return 0
  fi
  if git config --local --get core.hooksPath >/dev/null 2>&1; then
    git config --local --unset core.hooksPath || githooks_die 'Failed to unset core.hooksPath'
  fi
}

ephemeral_prepare_directory() {
  _ephemeral_dir=$1
  if [ -z "${_ephemeral_dir}" ]; then
    githooks_die 'ephemeral_prepare_directory requires directory path'
  fi
  if ephemeral_in_dry_run; then
    githooks_log_info "DRY-RUN: ensure directory ${_ephemeral_dir}"
    return 0
  fi
  if [ ! -d "${_ephemeral_dir}" ]; then
    githooks_mkdir_p "${_ephemeral_dir}"
  fi
  githooks_chmod 700 "${_ephemeral_dir}"
}

ephemeral_copy_runner_assets() {
  _ephemeral_root=$(ephemeral_root_dir)
  _ephemeral_lib_dir=$(ephemeral_lib_dir)
  _ephemeral_runner_src="$(ephemeral_toolkit_root)/_runner.sh"
  _ephemeral_common_src="$(ephemeral_toolkit_root)/lib/common.sh"
  if [ ! -f "${_ephemeral_runner_src}" ]; then
    githooks_die "Missing runner source at ${_ephemeral_runner_src}"
  fi
  if [ ! -f "${_ephemeral_common_src}" ]; then
    githooks_die "Missing shared library at ${_ephemeral_common_src}"
  fi
  ephemeral_prepare_directory "${_ephemeral_root}"
  ephemeral_prepare_directory "${_ephemeral_lib_dir}"
  _ephemeral_runner_dst="${_ephemeral_root%/}/_runner.sh"
  _ephemeral_common_dst="${_ephemeral_lib_dir%/}/common.sh"
  if ephemeral_in_dry_run; then
    githooks_log_info "DRY-RUN: copy runner to ${_ephemeral_runner_dst}"
    githooks_log_info "DRY-RUN: copy library to ${_ephemeral_common_dst}"
    return 0
  fi
  githooks_copy_file "${_ephemeral_runner_src}" "${_ephemeral_runner_dst}"
  githooks_chmod 755 "${_ephemeral_runner_dst}"
  githooks_copy_file "${_ephemeral_common_src}" "${_ephemeral_common_dst}"
  githooks_chmod 644 "${_ephemeral_common_dst}"
}

ephemeral_write_stub() {
  _ephemeral_hook=${1-}
  if [ -z "${_ephemeral_hook}" ]; then
    githooks_die 'ephemeral_write_stub requires hook name'
  fi
  _ephemeral_root=$(ephemeral_root_dir)
  _ephemeral_stub="${_ephemeral_root%/}/${_ephemeral_hook}"
  if ephemeral_in_dry_run; then
    githooks_log_info "DRY-RUN: write stub ${_ephemeral_stub}"
    return 0
  fi
  _ephemeral_tmp="${_ephemeral_stub}.tmp.$$"
  githooks_stub_body '$(dirname "$0")/_runner.sh' "${_ephemeral_hook}" >"${_ephemeral_tmp}" || githooks_die "Failed to create stub for ${_ephemeral_hook}"
  mv "${_ephemeral_tmp}" "${_ephemeral_stub}" || githooks_die "Failed to install stub ${_ephemeral_stub}"
  githooks_chmod 755 "${_ephemeral_stub}"
}

ephemeral_install_cleanup() {
  if [ "${EPHEMERAL_INSTALL_GUARD:-0}" -eq 0 ]; then
    return 0
  fi
  trap - EXIT INT TERM HUP
  if [ "${EPHEMERAL_INSTALL_CONFIG_UPDATED:-0}" -eq 1 ]; then
    ephemeral_restore_previous_hooks_path "${EPHEMERAL_INSTALL_PREVIOUS_CONFIG:-}"
  fi
  if [ "${EPHEMERAL_INSTALL_ROOT_CREATED:-0}" -eq 1 ] && ! ephemeral_in_dry_run; then
    _ephemeral_root=$(ephemeral_root_dir)
    rm -rf "${_ephemeral_root}" 2>/dev/null || true
  fi
  EPHEMERAL_INSTALL_GUARD=0
}

ephemeral_install_common() {
  _ephemeral_action=$1
  shift
  _ephemeral_hooks=""
  if [ "$#" -gt 0 ]; then
    _ephemeral_hooks=$*
  else
    _ephemeral_hooks=$(ephemeral_manifest_get MANAGED_HOOKS || true)
  fi
  if [ -n "${_ephemeral_hooks}" ]; then
    _ephemeral_hooks=$(printf '%s' "${_ephemeral_hooks}" | tr '\n' ' ' | sed -e 's/[[:space:]]\+/ /g' -e 's/^ //; s/ $//')
  fi
  _ephemeral_existing_manifest=0
  _ephemeral_previous=$(ephemeral_manifest_get PREVIOUS_CORE_HOOKS_PATH || true)
  if [ -f "$(ephemeral_manifest_path)" ]; then
    _ephemeral_existing_manifest=1
  fi
  if [ "${_ephemeral_existing_manifest}" -eq 0 ] || [ -z "${_ephemeral_previous}" ]; then
    _ephemeral_previous=$(ephemeral_current_hooks_path)
  fi
  EPHEMERAL_INSTALL_GUARD=1
  EPHEMERAL_INSTALL_CONFIG_UPDATED=0
  EPHEMERAL_INSTALL_ROOT_CREATED=0
  EPHEMERAL_INSTALL_PREVIOUS_CONFIG=${_ephemeral_previous}
  trap 'ephemeral_install_cleanup' EXIT INT TERM HUP

  _ephemeral_root=$(ephemeral_root_dir)
  if [ ! -d "${_ephemeral_root}" ] && ! ephemeral_in_dry_run; then
    EPHEMERAL_INSTALL_ROOT_CREATED=1
  fi
  ephemeral_copy_runner_assets

  _ephemeral_hook_list="${_ephemeral_hooks}"
  if [ -n "${_ephemeral_hook_list}" ]; then
    for _ephemeral_hook in ${_ephemeral_hook_list}; do
      ephemeral_write_stub "${_ephemeral_hook}"
    done
  fi

  _ephemeral_target=$(ephemeral_hooks_config_value)
  ephemeral_set_core_hooks_path "${_ephemeral_target}"
  EPHEMERAL_INSTALL_CONFIG_UPDATED=1

  ephemeral_manifest_write "${_ephemeral_previous}" "${_ephemeral_target}" "${_ephemeral_hook_list}" "${_ephemeral_action}"

  EPHEMERAL_INSTALL_GUARD=0
  trap - EXIT INT TERM HUP
  githooks_log_info "Ephemeral Mode ${_ephemeral_action} complete"
}

ephemeral_install() {
  ephemeral_install_common install "${1-}"
}

ephemeral_refresh() {
  ephemeral_install_common refresh "${1-}"
}

ephemeral_uninstall_cleanup() {
  if [ "${EPHEMERAL_UNINSTALL_GUARD:-0}" -eq 0 ]; then
    return 0
  fi
  trap - EXIT INT TERM HUP
  if [ "${EPHEMERAL_UNINSTALL_CONFIG_SET:-0}" -eq 1 ]; then
    ephemeral_restore_previous_hooks_path "${EPHEMERAL_UNINSTALL_TARGET_CONFIG:-}"
  fi
  EPHEMERAL_UNINSTALL_GUARD=0
}

ephemeral_uninstall() {
  _ephemeral_manifest=$(ephemeral_manifest_path)
  _ephemeral_root=$(ephemeral_root_dir)
  if [ ! -f "${_ephemeral_manifest}" ] && [ ! -d "${_ephemeral_root}" ]; then
    githooks_log_info 'Ephemeral Mode not installed; nothing to uninstall'
    return 0
  fi
  _ephemeral_previous=$(ephemeral_manifest_get PREVIOUS_CORE_HOOKS_PATH || true)
  EPHEMERAL_UNINSTALL_GUARD=1
  EPHEMERAL_UNINSTALL_CONFIG_SET=0
  EPHEMERAL_UNINSTALL_TARGET_CONFIG=${_ephemeral_previous}
  trap 'ephemeral_uninstall_cleanup' EXIT INT TERM HUP

  if [ -d "${_ephemeral_root}" ]; then
    if ephemeral_in_dry_run; then
      githooks_log_info "DRY-RUN: remove ${_ephemeral_root}"
    else
      rm -rf "${_ephemeral_root}" || githooks_die "Failed to remove ${_ephemeral_root}"
    fi
  fi

  if [ -n "${_ephemeral_previous}" ]; then
    ephemeral_set_core_hooks_path "${_ephemeral_previous}"
  else
    ephemeral_restore_previous_hooks_path ""
  fi
  EPHEMERAL_UNINSTALL_CONFIG_SET=1

  if [ -f "${_ephemeral_manifest}" ] && ! ephemeral_in_dry_run; then
    rm -f "${_ephemeral_manifest}" 2>/dev/null || true
  fi

  EPHEMERAL_UNINSTALL_GUARD=0
  trap - EXIT INT TERM HUP
  githooks_log_info 'Ephemeral Mode uninstall complete'
}
