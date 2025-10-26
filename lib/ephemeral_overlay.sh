#!/bin/sh
# Ephemeral overlay root resolution helpers. Determine hook part search roots
# and precedence using config overrides without mutating repository state.

ephemeral_overlay_trim() {
  _ephemeral_trim_value=${1-}
  printf "%s" "${_ephemeral_trim_value}" | sed -e "s/^[[:space:]]*//" -e "s/[[:space:]]*$//"
}

ephemeral_overlay_list_contains() {
  _ephemeral_list=${1-}
  _ephemeral_seek=${2-}
  if [ -z "${_ephemeral_list}" ]; then
    return 1
  fi
  _ephemeral_list=$(printf '%b' "${_ephemeral_list}")
  _ephemeral_saved_ifs=${IFS}
  IFS="\n"
  set -f
  for _ephemeral_item in ${_ephemeral_list}; do
    if [ "${_ephemeral_item}" = "${_ephemeral_seek}" ]; then
      IFS=${_ephemeral_saved_ifs}
      set +f
      return 0
    fi
  done
  set +f
  IFS=${_ephemeral_saved_ifs}
  return 1
}

ephemeral_overlay_append_unique() {
  _ephemeral_var=$1
  _ephemeral_value=$2
  if [ -z "${_ephemeral_value}" ]; then
    return 0
  fi
  eval "_ephemeral_current=\${${_ephemeral_var}:-}"
  if ephemeral_overlay_list_contains "${_ephemeral_current}" "${_ephemeral_value}"; then
    return 0
  fi
  if [ -z "${_ephemeral_current}" ]; then
    eval "${_ephemeral_var}=\"\${_ephemeral_value}\""
  else
    eval "${_ephemeral_var}=\"\${_ephemeral_current}\\n\${_ephemeral_value}\""
  fi
}

ephemeral_overlay_absolute_path() {
  _ephemeral_path=${1-}
  if [ -z "${_ephemeral_path}" ]; then
    return 1
  fi
  case "${_ephemeral_path}" in
    /*)
      printf "%s\n" "${_ephemeral_path}"
      ;;
    ~*)
      printf "%s\n" "${HOME}${_ephemeral_path#~}"
      ;;
    *)
      if githooks_is_bare_repo; then
        _ephemeral_base=$(githooks_repo_git_dir)
      else
        _ephemeral_base=$(githooks_repo_top)
      fi
      printf "%s/%s\n" "${_ephemeral_base%/}" "${_ephemeral_path#./}"
      ;;
  esac
}

ephemeral_overlay_parse_and_append() {
  _ephemeral_input=${1-}
  _ephemeral_target=$2
  if [ -z "${_ephemeral_input}" ]; then
    return 0
  fi
  _ephemeral_normalised=$(printf "%s" "${_ephemeral_input}" | tr ,: "\n")
  _ephemeral_saved_ifs=${IFS}
  IFS="\n"
  set -f
  for _ephemeral_candidate in ${_ephemeral_normalised}; do
    _ephemeral_candidate_trimmed=$(ephemeral_overlay_trim "${_ephemeral_candidate}")
    if [ -z "${_ephemeral_candidate_trimmed}" ]; then
      continue
    fi
    _ephemeral_abs=$(ephemeral_overlay_absolute_path "${_ephemeral_candidate_trimmed}")
    ephemeral_overlay_append_unique "${_ephemeral_target}" "${_ephemeral_abs}"
  done
  set +f
  IFS=${_ephemeral_saved_ifs}
}

ephemeral_overlay_extra_roots() {
  _ephemeral_extra_roots=""
  if [ -n "${GITHOOKS_EPHEMERAL_EXTRA_ROOTS:-}" ]; then
    ephemeral_overlay_parse_and_append "${GITHOOKS_EPHEMERAL_EXTRA_ROOTS}" _ephemeral_extra_roots
  fi
  _ephemeral_config_roots=$(git config --local --get-all githooks.ephemeral.extraRoot 2>/dev/null || true)
  if [ -n "${_ephemeral_config_roots}" ]; then
    ephemeral_overlay_parse_and_append "${_ephemeral_config_roots}" _ephemeral_extra_roots
  fi
  printf "%s\n" "${_ephemeral_extra_roots}"
}

ephemeral_overlay_ephemeral_root() {
  _ephemeral_root=$(ephemeral_root_dir)
  printf "%s\n" "${_ephemeral_root%/}/parts"
}

ephemeral_overlay_versioned_root() {
  if githooks_is_bare_repo; then
    _ephemeral_git_dir=$(githooks_repo_git_dir)
    printf "%s\n" "${_ephemeral_git_dir%/}/hooks"
    return 0
  fi
  _ephemeral_repo_top=$(githooks_repo_top)
  printf "%s\n" "${_ephemeral_repo_top%/}/.githooks"
}

ephemeral_overlay_consider_root() {
  _ephemeral_target=$1
  _ephemeral_candidate=$2
  if [ -z "${_ephemeral_candidate}" ]; then
    return 0
  fi
  ephemeral_overlay_append_unique "${_ephemeral_target}" "${_ephemeral_candidate}"
}

ephemeral_overlay_resolve_roots() {
  _ephemeral_precedence=$(ephemeral_precedence_mode)
  _ephemeral_resolved=""
  _ephemeral_root_ephemeral=$(ephemeral_overlay_ephemeral_root)
  _ephemeral_root_versioned=$(ephemeral_overlay_versioned_root)

  case "${_ephemeral_precedence}" in
    versioned-first)
      ephemeral_overlay_consider_root _ephemeral_resolved "${_ephemeral_root_versioned}"
      ephemeral_overlay_consider_root _ephemeral_resolved "${_ephemeral_root_ephemeral}"
      ;;
    merge)
      ephemeral_overlay_consider_root _ephemeral_resolved "${_ephemeral_root_ephemeral}"
      ephemeral_overlay_consider_root _ephemeral_resolved "${_ephemeral_root_versioned}"
      ;;
    *)
      ephemeral_overlay_consider_root _ephemeral_resolved "${_ephemeral_root_ephemeral}"
      ephemeral_overlay_consider_root _ephemeral_resolved "${_ephemeral_root_versioned}"
      ;;
  esac

  _ephemeral_extra=$(ephemeral_overlay_extra_roots)
  if [ -n "${_ephemeral_extra}" ]; then
    _ephemeral_extra=$(printf '%b' "${_ephemeral_extra}")
    _ephemeral_saved_ifs=${IFS}
    IFS="\n"
    set -f
    for _ephemeral_additional in ${_ephemeral_extra}; do
      ephemeral_overlay_consider_root _ephemeral_resolved "${_ephemeral_additional}"
    done
    set +f
    IFS=${_ephemeral_saved_ifs}
  fi

  printf "%s\n" "${_ephemeral_resolved}"
}

ephemeral_overlay_roots_serialized() {
  _ephemeral_roots=$(ephemeral_overlay_resolve_roots)
  if [ -z "${_ephemeral_roots}" ]; then
    printf "%s\n" ""
    return 0
  fi
  _ephemeral_roots=$(printf '%b' "${_ephemeral_roots}")
  _ephemeral_serial=""
  _ephemeral_saved_ifs=${IFS}
  IFS="\n"
  set -f
  for _ephemeral_entry in ${_ephemeral_roots}; do
    if [ -z "${_ephemeral_entry}" ]; then
      continue
    fi
    if [ -z "${_ephemeral_serial}" ]; then
      _ephemeral_serial="${_ephemeral_entry}"
    else
      _ephemeral_serial="${_ephemeral_serial}:${_ephemeral_entry}"
    fi
  done
  set +f
  IFS=${_ephemeral_saved_ifs}
  printf "%s\n" "${_ephemeral_serial}"
}

ephemeral_overlay_log_roots() {
  if [ "$#" -gt 0 ]; then
    _ephemeral_logged_roots=$1
  else
    _ephemeral_logged_roots=$(ephemeral_overlay_resolve_roots)
  fi
  _ephemeral_mode=$(ephemeral_precedence_mode)
  if [ -z "${_ephemeral_logged_roots}" ]; then
    githooks_log_info "Ephemeral overlay order (${_ephemeral_mode}): <none>"
    return 0
  fi
  _ephemeral_logged_roots=$(printf '%b' "${_ephemeral_logged_roots}")
  githooks_log_info "Ephemeral overlay order (${_ephemeral_mode}):"
  _ephemeral_index=0
  printf '%b' "${_ephemeral_logged_roots}\n" | while IFS= read -r _ephemeral_logged || [ -n "${_ephemeral_logged}" ]; do
    [ -n "${_ephemeral_logged}" ] || continue
    _ephemeral_index=$((_ephemeral_index + 1))
    if [ -d "${_ephemeral_logged}" ]; then
      _ephemeral_state=present
    else
      _ephemeral_state=missing
    fi
    githooks_log_info "  [${_ephemeral_index}] ${_ephemeral_logged} (${_ephemeral_state})"
  done
}
