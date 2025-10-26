#!/bin/sh
# Shared configuration asset management for git-hooks runner toolkit.
# Provides registration, staging, refresh, and removal helpers for
# hook-associated configuration files in both standard and Ephemeral modes.

# shellcheck disable=SC2034
: "${GITHOOKS_CONFIG_SPECS:=}"
: "${GITHOOKS_CONFIG_REQUIRED:=}"

githooks_config_append_spec() {
  _cfg_spec=$1
  if [ -z "${GITHOOKS_CONFIG_SPECS}" ]; then
    GITHOOKS_CONFIG_SPECS=${_cfg_spec}
  else
    GITHOOKS_CONFIG_SPECS="${GITHOOKS_CONFIG_SPECS}
${_cfg_spec}"
  fi
}

githooks_config_register_copy() {
  _cfg_name=$1
  _cfg_source=$2
  _cfg_dest=$3
  _cfg_mode=${4:-644}
  _cfg_parts=${5-}
  _cfg_after_install=${6-}
  _cfg_after_remove=${7-}
  if [ -z "${_cfg_name}" ] || [ -z "${_cfg_dest}" ]; then
    githooks_die "githooks_config_register_copy requires name and destination"
  fi
  githooks_config_append_spec "copy|${_cfg_name}|${_cfg_source}|${_cfg_dest}|${_cfg_mode}||${_cfg_parts}|${_cfg_after_install}|${_cfg_after_remove}"
}

githooks_config_register_generator() {
  _cfg_name=$1
  _cfg_template=$2
  _cfg_dest=$3
  _cfg_mode=${4:-644}
  _cfg_generator=${5-}
  _cfg_parts=${6-}
  _cfg_after_install=${7-}
  _cfg_after_remove=${8-}
  if [ -z "${_cfg_name}" ] || [ -z "${_cfg_dest}" ] || [ -z "${_cfg_generator}" ]; then
    githooks_die "githooks_config_register_generator requires name, destination, and generator"
  fi
  githooks_config_append_spec "generate|${_cfg_name}|${_cfg_template}|${_cfg_dest}|${_cfg_mode}|${_cfg_generator}|${_cfg_parts}|${_cfg_after_install}|${_cfg_after_remove}"
}

githooks_config_clear_required() {
  GITHOOKS_CONFIG_REQUIRED=""
}

githooks_config_require() {
  _cfg_name=$1
  if [ -z "${_cfg_name}" ]; then
    return 0
  fi
  if [ -z "${GITHOOKS_CONFIG_REQUIRED}" ]; then
    GITHOOKS_CONFIG_REQUIRED=${_cfg_name}
    return 0
  fi
  _cfg_saved_ifs=${IFS}
  IFS=' '
  for _cfg_existing in ${GITHOOKS_CONFIG_REQUIRED}; do
    if [ "${_cfg_existing}" = "${_cfg_name}" ]; then
      IFS=${_cfg_saved_ifs}
      return 0
    fi
  done
  GITHOOKS_CONFIG_REQUIRED="${GITHOOKS_CONFIG_REQUIRED} ${_cfg_name}"
  IFS=${_cfg_saved_ifs}
}

githooks_config_lookup_spec() {
  _cfg_target=$1
  if [ -z "${_cfg_target}" ] || [ -z "${GITHOOKS_CONFIG_SPECS}" ]; then
    return 1
  fi
  _cfg_saved_ifs=${IFS}
  _cfg_newline=$(printf '\n_')
  IFS=${_cfg_newline%_}
  for _cfg_spec in ${GITHOOKS_CONFIG_SPECS}; do
    [ -n "${_cfg_spec}" ] || continue
    IFS='|'
    set -- ${_cfg_spec}
    IFS=${_cfg_newline%_}
    _cfg_type=$1
    _cfg_name=$2
    if [ "${_cfg_name}" = "${_cfg_target}" ]; then
      printf '%s\n' "${_cfg_spec}"
      IFS=${_cfg_saved_ifs}
      return 0
    fi
  done
  IFS=${_cfg_saved_ifs}
  return 1
}

githooks_config_require_for_part() {
  _cfg_part=$1
  if [ -z "${_cfg_part}" ] || [ -z "${GITHOOKS_CONFIG_SPECS}" ]; then
    return 0
  fi
  _cfg_saved_ifs=${IFS}
  _cfg_newline=$(printf '\n_')
  IFS=${_cfg_newline%_}
  for _cfg_spec in ${GITHOOKS_CONFIG_SPECS}; do
    [ -n "${_cfg_spec}" ] || continue
    IFS='|'
    set -- ${_cfg_spec}
    IFS=${_cfg_newline%_}
    _cfg_name=$2
    _cfg_parts=${7-}
    if [ -z "${_cfg_parts}" ]; then
      continue
    fi
    _cfg_norm=$(printf '%s' "${_cfg_parts}" | tr ',:' ' ')
    _cfg_part_saved_ifs=${IFS}
    IFS=' '
    for _cfg_entry in ${_cfg_norm}; do
      if [ "${_cfg_entry}" = "${_cfg_part}" ]; then
        githooks_config_require "${_cfg_name}"
        break
      fi
    done
    IFS=${_cfg_part_saved_ifs}
  done
  IFS=${_cfg_saved_ifs}
}

githooks_config_files_identical() {
  _cfg_src=$1
  _cfg_dst=$2
  if [ ! -f "${_cfg_src}" ] || [ ! -f "${_cfg_dst}" ]; then
    return 1
  fi
  _cfg_src_sum=$(cksum < "${_cfg_src}" 2>/dev/null || printf '')
  _cfg_dst_sum=$(cksum < "${_cfg_dst}" 2>/dev/null || printf '')
  if [ -n "${_cfg_src_sum}" ] && [ "${_cfg_src_sum}" = "${_cfg_dst_sum}" ]; then
    return 0
  fi
  return 1
}

githooks_config_run_generator() {
  _cfg_generator=$1
  _cfg_tmp=$2
  _cfg_dest_root=$3
  _cfg_name=$4
  _cfg_template=$5
  if [ -z "${_cfg_generator}" ]; then
    return 1
  fi
  if command -v "${_cfg_generator}" >/dev/null 2>&1; then
    "${_cfg_generator}" "${_cfg_tmp}" "${_cfg_dest_root}" "${_cfg_name}" "${_cfg_template}" || return 1
    return 0
  fi
  _cfg_gen_path=${_cfg_generator}
  case "${_cfg_gen_path}" in
    /*)
      ;;
    *)
      _cfg_gen_path="${SCRIPT_DIR%/}/${_cfg_gen_path}"
      ;;
  esac
  if [ ! -x "${_cfg_gen_path}" ]; then
    return 1
  fi
  "${_cfg_gen_path}" "${_cfg_tmp}" "${_cfg_dest_root}" "${_cfg_name}" "${_cfg_template}" || return 1
  return 0
}

githooks_config_apply() {
  _cfg_name=$1
  _cfg_op=$2
  _cfg_hooks_root=$3
  _cfg_force=${4:-0}
  _cfg_dry_run=${5:-0}
  _cfg_spec=$(githooks_config_lookup_spec "${_cfg_name}" || true)
  if [ -z "${_cfg_spec}" ]; then
    return 0
  fi
  _cfg_saved_ifs=${IFS}
  IFS='|'
  set -- ${_cfg_spec}
  IFS=${_cfg_saved_ifs}
  _cfg_type=$1
  _cfg_key=$2
  _cfg_payload=$3
  _cfg_dest_rel=$4
  _cfg_mode=${5:-644}
  _cfg_generator=${6-}
  _cfg_after_install=${8-}
  _cfg_after_remove=${9-}
  case "${_cfg_dest_rel}" in
    /*)
      _cfg_dest_path=${_cfg_dest_rel}
      ;;
    *)
      _cfg_dest_path="${_cfg_hooks_root%/}/${_cfg_dest_rel}"
      ;;
  esac
  _cfg_dest_dir=$(dirname "${_cfg_dest_path}")
  _cfg_display="${_cfg_dest_path}"
  if [ "${_cfg_op}" = "update" ]; then
    _cfg_display=${_cfg_dest_rel}
  fi

  case "${_cfg_op}" in
    stage|update)
      if [ "${_cfg_op}" = "stage" ] || [ -f "${_cfg_dest_path}" ]; then
        :
      else
        githooks_log_info "${_cfg_op} skip ${_cfg_key}: destination missing"
        return 0
      fi
      if [ "${_cfg_dry_run}" -eq 1 ]; then
        githooks_log_info "DRY-RUN: ensure config directory ${_cfg_dest_dir}"
      else
        githooks_mkdir_p "${_cfg_dest_dir}"
      fi
      _cfg_tmp="${_cfg_dest_path}.cfg.$$"
      case "${_cfg_type}" in
        copy)
          _cfg_src=${_cfg_payload}
          case "${_cfg_src}" in
            /*)
              ;;
            *)
              _cfg_src="${SCRIPT_DIR%/}/${_cfg_src}"
              ;;
          esac
          if [ ! -f "${_cfg_src}" ]; then
            githooks_log_warn "${_cfg_key}: source config missing at ${_cfg_src}; skipping"
            return 0
          fi
          if [ "${_cfg_op}" = "stage" ] && [ "${_cfg_dry_run}" -eq 1 ]; then
            githooks_log_info "DRY-RUN: stage config ${_cfg_src} -> ${_cfg_dest_path}"
            return 0
          fi
          if [ "${_cfg_op}" = "update" ] && [ "${_cfg_dry_run}" -eq 1 ]; then
            githooks_log_info "DRY-RUN: update ${_cfg_display}"
            return 0
          fi
          if [ "${_cfg_dry_run}" -eq 0 ]; then
            if [ -f "${_cfg_dest_path}" ] && [ "${_cfg_force}" -eq 0 ]; then
              if githooks_config_files_identical "${_cfg_src}" "${_cfg_dest_path}"; then
                if [ "${_cfg_op}" = "stage" ]; then
                  githooks_log_info "stage skip identical ${_cfg_dest_path}"
                else
                  githooks_log_info "update skip identical ${_cfg_display}"
                fi
                return 0
              fi
            fi
            if ! cp "${_cfg_src}" "${_cfg_tmp}"; then
              rm -f "${_cfg_tmp}" 2>/dev/null || true
              githooks_die "Failed to copy config ${_cfg_dest_path}"
            fi
          else
            return 0
          fi
          ;;
        generate)
          if [ "${_cfg_dry_run}" -eq 1 ]; then
            githooks_log_info "DRY-RUN: generate config ${_cfg_dest_path}"
            return 0
          fi
          if ! githooks_config_run_generator "${_cfg_generator}" "${_cfg_tmp}" "${_cfg_hooks_root}" "${_cfg_key}" "${_cfg_payload}"; then
            rm -f "${_cfg_tmp}" 2>/dev/null || true
            githooks_die "Failed to generate config for ${_cfg_key}"
          fi
          if [ -f "${_cfg_dest_path}" ] && [ "${_cfg_force}" -eq 0 ]; then
            if githooks_config_files_identical "${_cfg_tmp}" "${_cfg_dest_path}"; then
              rm -f "${_cfg_tmp}" 2>/dev/null || true
              if [ "${_cfg_op}" = "stage" ]; then
                githooks_log_info "stage skip identical ${_cfg_dest_path}"
              else
                githooks_log_info "update skip identical ${_cfg_display}"
              fi
              return 0
            fi
          fi
          ;;
        *)
          githooks_die "Unsupported config type ${_cfg_type}"
          ;;
      esac
      if [ "${_cfg_dry_run}" -eq 0 ]; then
        githooks_chmod "${_cfg_mode}" "${_cfg_tmp}"
        if ! mv "${_cfg_tmp}" "${_cfg_dest_path}"; then
          rm -f "${_cfg_tmp}" 2>/dev/null || true
          githooks_die "Failed to publish config ${_cfg_dest_path}"
        fi
        if [ "${_cfg_op}" = "stage" ]; then
          githooks_log_info "stage config ${_cfg_dest_path}"
        else
          githooks_log_info "update ${_cfg_display}"
          UPDATE_SUPPORT_REFRESHED=$((UPDATE_SUPPORT_REFRESHED + 1))
        fi
        if [ -n "${_cfg_after_install}" ] && command -v "${_cfg_after_install}" >/dev/null 2>&1; then
          "${_cfg_after_install}" "${_cfg_dest_path}"
        fi
      fi
      ;;
    remove)
      if [ ! -f "${_cfg_dest_path}" ]; then
        return 0
      fi
      if [ "${_cfg_dry_run}" -eq 1 ]; then
        githooks_log_info "DRY-RUN: remove config ${_cfg_dest_path}"
        return 0
      fi
      if [ "${_cfg_force}" -eq 0 ]; then
        _cfg_tmp="${_cfg_dest_path}.cfg.$$"
        _cfg_should_remove=0
        case "${_cfg_type}" in
          copy)
            _cfg_src=${_cfg_payload}
            case "${_cfg_src}" in
              /*)
                ;;
              *)
                _cfg_src="${SCRIPT_DIR%/}/${_cfg_src}"
                ;;
            esac
            if [ -f "${_cfg_src}" ] && githooks_config_files_identical "${_cfg_src}" "${_cfg_dest_path}"; then
              _cfg_should_remove=1
            fi
            ;;
          generate)
            if githooks_config_run_generator "${_cfg_generator}" "${_cfg_tmp}" "${_cfg_hooks_root}" "${_cfg_key}" "${_cfg_payload}"; then
              if githooks_config_files_identical "${_cfg_tmp}" "${_cfg_dest_path}"; then
                _cfg_should_remove=1
              fi
            fi
            ;;
        esac
        rm -f "${_cfg_tmp}" 2>/dev/null || true
        if [ "${_cfg_should_remove}" -eq 0 ]; then
          githooks_log_info "remove skip ${_cfg_dest_path}: differs from managed template"
          return 0
        fi
      fi
      if rm -f "${_cfg_dest_path}"; then
        githooks_log_info "remove config ${_cfg_dest_path}"
        if [ -n "${_cfg_after_remove}" ] && command -v "${_cfg_after_remove}" >/dev/null 2>&1; then
          "${_cfg_after_remove}" "${_cfg_dest_path}"
        fi
      fi
      ;;
    *)
      githooks_die "Unknown config operation ${_cfg_op}"
      ;;
  esac
  return 0
}

githooks_config_install_required() {
  _cfg_hooks_root=$(githooks_hooks_root)
  if [ -z "${GITHOOKS_CONFIG_REQUIRED}" ]; then
    return 0
  fi
  _cfg_saved_ifs=${IFS}
  IFS=' '
  for _cfg_name in ${GITHOOKS_CONFIG_REQUIRED}; do
    githooks_config_apply "${_cfg_name}" "stage" "${_cfg_hooks_root}" "${FORCE:-0}" "${DRY_RUN:-0}"
  done
  IFS=${_cfg_saved_ifs}
  githooks_config_clear_required
}

githooks_config_refresh_all() {
  if [ -z "${GITHOOKS_CONFIG_SPECS}" ]; then
    return 0
  fi
  _cfg_hooks_root=$(githooks_hooks_root)
  _cfg_saved_ifs=${IFS}
  _cfg_newline=$(printf '\n_')
  IFS=${_cfg_newline%_}
  for _cfg_spec in ${GITHOOKS_CONFIG_SPECS}; do
    [ -n "${_cfg_spec}" ] || continue
    IFS='|'
    set -- ${_cfg_spec}
    IFS=${_cfg_newline%_}
    _cfg_name=$2
    githooks_config_apply "${_cfg_name}" "update" "${_cfg_hooks_root}" "${FORCE:-0}" "${DRY_RUN:-0}"
  done
  IFS=${_cfg_saved_ifs}
}

githooks_config_remove_all() {
  if [ -z "${GITHOOKS_CONFIG_SPECS}" ]; then
    return 0
  fi
  _cfg_hooks_root=$(githooks_hooks_root)
  _cfg_saved_ifs=${IFS}
  _cfg_newline=$(printf '\n_')
  IFS=${_cfg_newline%_}
  for _cfg_spec in ${GITHOOKS_CONFIG_SPECS}; do
    [ -n "${_cfg_spec}" ] || continue
    IFS='|'
    set -- ${_cfg_spec}
    IFS=${_cfg_newline%_}
    _cfg_name=$2
    githooks_config_apply "${_cfg_name}" "remove" "${_cfg_hooks_root}" "${FORCE:-0}" "${DRY_RUN:-0}"
  done
  IFS=${_cfg_saved_ifs}
}
