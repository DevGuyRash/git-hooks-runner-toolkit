#!/bin/sh
# Shared helpers for git hook runner integration tests (POSIX sh).

set -eu

: "${GHR_CAT:=$(command -v cat)}"
: "${GHR_CHMOD:=$(command -v chmod)}"
: "${GHR_MKDIR:=$(command -v mkdir)}"
: "${GHR_MKTEMP:=$(command -v mktemp)}"
: "${GHR_RM:=$(command -v rm)}"
: "${GHR_GIT:=$(command -v git)}"

ghr_mk_sandbox() {
  ghr_root=$(${GHR_MKTEMP} -d "${TMPDIR:-/tmp}/git-hooks-runner.XXXXXX") || return 1
  ghr_work="${ghr_root}/repo"
  ghr_remote="${ghr_root}/remote.git"
  ghr_home="${ghr_root}/home"
  "${GHR_MKDIR}" -p "${ghr_work}" "${ghr_remote}" "${ghr_home}" "${ghr_home}/.config" || return 1
  printf '%s|%s|%s|%s\n' "${ghr_root}" "${ghr_work}" "${ghr_remote}" "${ghr_home}"
}

ghr_cleanup_sandbox() {
  ghr_root=$1
  if [ -n "${ghr_root}" ] && [ -d "${ghr_root}" ]; then
    "${GHR_RM}" -rf -- "${ghr_root}"
  fi
}

ghr_in_repo() {
  if [ "$#" -lt 3 ]; then
    printf 'ghr_in_repo requires <repo> <home> <command...>\n' >&2
    return 2
  fi
  ghr_repo=$1
  ghr_home=$2
  shift 2
  (
    cd "${ghr_repo}" || return 1
    HOME="${ghr_home}"
    export HOME
    XDG_CONFIG_HOME="${ghr_home}/.config"
    export XDG_CONFIG_HOME
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_TERMINAL_PROMPT=0
    export LC_ALL=C
    export PATH="${PATH}"

    while [ "$#" -gt 0 ]; do
      case $1 in
        *=*)
          ghr_var_name=${1%%=*}
          ghr_var_value=${1#*=}
          export "${ghr_var_name}=${ghr_var_value}"
          shift
          ;;
        *)
          break
          ;;
      esac
    done

    if [ "$#" -eq 0 ]; then
      printf 'ghr_in_repo: missing command\n' >&2
      return 2
    fi

    "$@"
  )
}

ghr_git() {
  if [ "$#" -lt 3 ]; then
    printf 'ghr_git requires <repo> <home> <git-args...>\n' >&2
    return 2
  fi
  ghr_repo=$1
  ghr_home=$2
  shift 2
  ghr_in_repo "${ghr_repo}" "${ghr_home}" "${GHR_GIT}" "$@"
}

ghr_init_repo() {
  if [ "$#" -ne 2 ]; then
    printf 'ghr_init_repo requires <repo> <home>\n' >&2
    return 2
  fi
  ghr_repo=$1
  ghr_home=$2
  ghr_git "${ghr_repo}" "${ghr_home}" init -q
  ghr_git "${ghr_repo}" "${ghr_home}" config user.name 'Hook Runner Tester'
  ghr_git "${ghr_repo}" "${ghr_home}" config user.email 'hooks@example.invalid'
  ghr_git "${ghr_repo}" "${ghr_home}" config commit.gpgSign false
  printf '%s\n' 'base' >"${ghr_repo}/README.md"
  ghr_git "${ghr_repo}" "${ghr_home}" add README.md
  ghr_git "${ghr_repo}" "${ghr_home}" commit -q -m 'feat: seed repository'
}

ghr_init_bare_remote() {
  if [ "$#" -ne 1 ]; then
    printf 'ghr_init_bare_remote requires <remote-path>\n' >&2
    return 2
  fi
  ghr_remote=$1
  "${GHR_GIT}" init --bare -q "${ghr_remote}"
}

ghr_make_commit() {
  if [ "$#" -lt 5 ]; then
    printf 'ghr_make_commit requires <repo> <home> <rel-path> <content> <message>\n' >&2
    return 2
  fi
  ghr_repo=$1
  ghr_home=$2
  ghr_rel=$3
  ghr_content=$4
  ghr_message=$5
  printf '%s\n' "${ghr_content}" >"${ghr_repo}/${ghr_rel}"
  ghr_git "${ghr_repo}" "${ghr_home}" add "${ghr_rel}"
  ghr_git "${ghr_repo}" "${ghr_home}" commit -q -m "${ghr_message}"
}

ghr_install_runner() {
  if [ "$#" -lt 4 ]; then
    printf 'ghr_install_runner requires <repo> <home> <installer> <hook-list>\n' >&2
    return 2
  fi
  ghr_repo=$1
  ghr_home=$2
  ghr_installer=$3
  ghr_hooks=$4
  ghr_in_repo "${ghr_repo}" "${ghr_home}" "${ghr_installer}" --hooks "${ghr_hooks}"
}

ghr_write_part() {
  if [ "$#" -lt 4 ]; then
    printf 'ghr_write_part requires <repo> <hook-name> <order> <slug>\n' >&2
    return 2
  fi
  ghr_repo=$1
  ghr_hook=$2
  ghr_order=$3
  ghr_slug=$4
  ghr_dir="${ghr_repo}/.githooks/${ghr_hook}.d"
  "${GHR_MKDIR}" -p "${ghr_dir}"
  ghr_path="${ghr_dir}/${ghr_order}-${ghr_slug}.sh"
  {
    printf '#!/bin/sh\n'
    printf 'set -eu\n'
    "${GHR_CAT}"
  } >"${ghr_path}"
  "${GHR_CHMOD}" 755 "${ghr_path}"
  printf '%s\n' "${ghr_path}"
}

ghr_read_or_empty() {
  if [ "$#" -ne 1 ]; then
    printf 'ghr_read_or_empty requires <path>\n' >&2
    return 2
  fi
  ghr_file=$1
  if [ -f "${ghr_file}" ]; then
    "${GHR_CAT}" -- "${ghr_file}"
  fi
}
