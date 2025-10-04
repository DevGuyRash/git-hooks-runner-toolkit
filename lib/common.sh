#!/bin/sh
# Shared helpers for git hook toolkit. Provides deterministic enumeration,
# logging, and repository context helpers using POSIX-compatible sh.

set -eu

# ----------------------------- Logging --------------------------------------
: "${GITHOOKS_LOG_NAMESPACE:=hook-runner}"

_githooks_log() {
  if [ "$#" -lt 2 ]; then
    return 1
  fi
  _githooks_log_level=$1
  shift
  _githooks_log_msg="$*"
  _githooks_log_line="[${GITHOOKS_LOG_NAMESPACE}] ${_githooks_log_level}: ${_githooks_log_msg}"
  case "${_githooks_log_level}" in
    INFO|DEBUG)
      printf '%s\n' "${_githooks_log_line}"
      ;;
    WARN|ERROR)
      printf '%s\n' "${_githooks_log_line}" >&2
      ;;
    *)
      printf '%s\n' "${_githooks_log_line}" >&2
      ;;
  esac
}

githooks_log_info()  { _githooks_log INFO "$*"; }
githooks_log_warn()  { _githooks_log WARN "$*"; }
githooks_log_error() { _githooks_log ERROR "$*"; }

githooks_die() {
  githooks_log_error "$*"
  exit 1
}

# ----------------------------- Repo context ---------------------------------
: "${GITHOOKS_CONTEXT_INITIALISED:=0}"

_githooks_trim() {
  if [ "$#" -eq 0 ]; then
    return 0
  fi
  printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

_githooks_absolute_path() {
  _githooks_abs_value="$1"
  _githooks_abs_base="$2"
  if [ -z "${_githooks_abs_value}" ]; then
    printf '%s' "${_githooks_abs_base}"
    return 0
  fi
  case "${_githooks_abs_value}" in
    /*)
      printf '%s' "${_githooks_abs_value}"
      ;;
    ~*)
      _githooks_abs_rest="${_githooks_abs_value#~}"
      printf '%s' "${HOME}${_githooks_abs_rest}"
      ;;
    *)
      if [ -n "${_githooks_abs_base}" ]; then
        printf '%s/%s' "${_githooks_abs_base%/}" "${_githooks_abs_value}"
      else
        printf '%s/%s' "${PWD}" "${_githooks_abs_value}"
      fi
      ;;
  esac
}

_githooks_init_context() {
  if [ "${GITHOOKS_CONTEXT_INITIALISED}" = "1" ]; then
    return 0
  fi
  if ! _githooks_git_dir=$(git rev-parse --absolute-git-dir 2>/dev/null); then
    githooks_die "Not inside a Git repository; unable to detect hooks context"
  fi
  GITHOOKS_REPO_GIT_DIR="${_githooks_git_dir}"
  _githooks_bare_flag=$(git rev-parse --is-bare-repository 2>/dev/null || printf 'false')
  if [ "${_githooks_bare_flag}" = "true" ]; then
    GITHOOKS_IS_BARE=1
    GITHOOKS_REPO_TOP="${GITHOOKS_REPO_GIT_DIR}"
  else
    if ! GITHOOKS_REPO_TOP=$(git rev-parse --show-toplevel 2>/dev/null); then
      githooks_die "Unable to determine repository top-level"
    fi
    GITHOOKS_IS_BARE=0
  fi
  GITHOOKS_CONTEXT_INITIALISED=1
}

_githooks_normalise_hooks_path() {
  if [ "$#" -eq 0 ]; then
    return 0
  fi
  _githooks_cfg=$(_githooks_trim "$1")
  if [ -z "${_githooks_cfg}" ]; then
    return 0
  fi
  case "${_githooks_cfg}" in
    /*)
      printf '%s' "${_githooks_cfg}"
      ;;
    ~*)
      _githooks_rest="${_githooks_cfg#~}"
      printf '%s' "${HOME}${_githooks_rest}"
      ;;
    *)
      _githooks_init_context
      if [ "${GITHOOKS_IS_BARE}" = "1" ]; then
        printf '%s/%s' "${GITHOOKS_REPO_GIT_DIR%/}" "${_githooks_cfg}"
      else
        printf '%s/%s' "${GITHOOKS_REPO_TOP%/}" "${_githooks_cfg}"
      fi
      ;;
  esac
}

githooks_repo_top() {
  _githooks_init_context
  printf '%s\n' "${GITHOOKS_REPO_TOP}"
}

githooks_repo_git_dir() {
  _githooks_init_context
  printf '%s\n' "${GITHOOKS_REPO_GIT_DIR}"
}

githooks_is_bare_repo() {
  _githooks_init_context
  if [ "${GITHOOKS_IS_BARE}" = "1" ]; then
    return 0
  fi
  return 1
}

githooks_hooks_root() {
  _githooks_init_context
  _githooks_cfg=$(git config --path --get core.hooksPath 2>/dev/null || true)
  _githooks_norm=$(_githooks_normalise_hooks_path "${_githooks_cfg}")
  if [ -n "${_githooks_norm}" ]; then
    printf '%s\n' "${_githooks_norm}"
    return 0
  fi
  printf '%s/hooks\n' "${GITHOOKS_REPO_GIT_DIR%/}"
}

githooks_shared_root() {
  _githooks_init_context
  if githooks_is_bare_repo; then
    printf '%s/hooks\n' "${GITHOOKS_REPO_GIT_DIR%/}"
  else
    printf '%s/.githooks\n' "${GITHOOKS_REPO_TOP%/}"
  fi
}

githooks_parts_dir() {
  if [ "$#" -ne 1 ] || [ -z "$1" ]; then
    githooks_die "githooks_parts_dir requires hook name"
  fi
  _githooks_parts_hook=$1
  _githooks_parts_base=$(githooks_shared_root)
  printf '%s/%s.d\n' "${_githooks_parts_base%/}" "${_githooks_parts_hook}"
}

# ----------------------------- Enumerating parts ----------------------------

githooks_list_parts() {
  if [ "$#" -ne 1 ]; then
    githooks_die "githooks_list_parts expects hook name"
  fi
  _githooks_list_hook=$1
  _githooks_list_dir=$(githooks_parts_dir "${_githooks_list_hook}")
  if [ ! -d "${_githooks_list_dir}" ]; then
    return 0
  fi
  LC_ALL=C find "${_githooks_list_dir}" -mindepth 1 -maxdepth 1 -type f -name '*.sh' -perm -u+x -print 2>/dev/null | LC_ALL=C sort
}

githooks_require_readable_parts() {
  if [ "$#" -ne 1 ]; then
    githooks_die "githooks_require_readable_parts expects directory"
  fi
  _githooks_req_dir=$1
  if [ ! -d "${_githooks_req_dir}" ]; then
    githooks_log_info "No hook parts directory present at ${_githooks_req_dir}"
    return 1
  fi
  if [ ! -r "${_githooks_req_dir}" ]; then
    githooks_die "Hook parts directory not readable: ${_githooks_req_dir}"
  fi
  return 0
}

# ----------------------------- Filesystem helpers --------------------------

githooks_mkdir_p() {
  if [ "$#" -ne 1 ] || [ -z "$1" ]; then
    githooks_die "githooks_mkdir_p expects a directory path"
  fi
  _githooks_dir=$1
  if [ -d "${_githooks_dir}" ]; then
    return 0
  fi
  mkdir -p "${_githooks_dir}" || githooks_die "Failed to create directory: ${_githooks_dir}"
}

githooks_write_file() {
  if [ "$#" -lt 2 ]; then
    githooks_die "githooks_write_file expects path and content"
  fi
  _githooks_write_path=$1
  shift
  printf '%s\n' "$*" >"${_githooks_write_path}" || githooks_die "Failed to write file: ${_githooks_write_path}"
}

githooks_copy_file() {
  if [ "$#" -ne 2 ]; then
    githooks_die "githooks_copy_file expects source and destination"
  fi
  _githooks_copy_src=$1
  _githooks_copy_dst=$2
  if [ ! -f "${_githooks_copy_src}" ]; then
    githooks_die "Source file missing: ${_githooks_copy_src}"
  fi
  cp "${_githooks_copy_src}" "${_githooks_copy_dst}" || githooks_die "Failed to copy ${_githooks_copy_src} -> ${_githooks_copy_dst}"
}

githooks_chmod() {
  if [ "$#" -ne 2 ]; then
    githooks_die "githooks_chmod expects mode and path"
  fi
  _githooks_chmod_mode=$1
  _githooks_chmod_path=$2
  chmod "${_githooks_chmod_mode}" "${_githooks_chmod_path}" || githooks_die "Failed to chmod ${_githooks_chmod_mode} ${_githooks_chmod_path}"
}

# ----------------------------- Stub content --------------------------------

githooks_stub_body() {
  if [ "$#" -ne 2 ]; then
    githooks_die "githooks_stub_body expects runner path and hook name"
  fi
  _githooks_stub_runner=$1
  _githooks_stub_hook=$2
  cat <<_STUB
#!/bin/sh
# generated by .githooks-runner; do not edit manually
set -eu
exec "${_githooks_stub_runner}" "\$0" "${_githooks_stub_hook}" "\$@"
_STUB
}

# End of library
