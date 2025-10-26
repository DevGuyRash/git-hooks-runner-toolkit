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
  ghr_root=$(${GHR_MKTEMP} -d "${TMPDIR:-/tmp}/.githooks-runner.XXXXXX") || return 1
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
  ghr_in_repo "${ghr_repo}" "${ghr_home}" "${ghr_installer}" install --hooks "${ghr_hooks}"
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

ghr_manifest_path_for_repo() {
  if [ "$#" -ne 1 ]; then
    printf 'ghr_manifest_path_for_repo requires <repo>\n' >&2
    return 2
  fi
  ghr_repo=$1
  printf '%s/.git/.githooks/manifest.sh\n' "${ghr_repo%/}"
}

ghr_manifest_value() {
  if [ "$#" -ne 2 ]; then
    printf 'ghr_manifest_value requires <repo> <key>\n' >&2
    return 2
  fi
  ghr_repo=$1
  ghr_key=$2
  ghr_manifest=$(ghr_manifest_path_for_repo "${ghr_repo}")
  if [ ! -f "${ghr_manifest}" ]; then
    return 1
  fi
  (
    # shellcheck disable=SC1090
    . "${ghr_manifest}"
    eval "printf '%s\\n' \"\${${ghr_key}-}\""
  )
}

ghr_manifest_snapshot() {
  if [ "$#" -ne 1 ]; then
    printf 'ghr_manifest_snapshot requires <repo>\n' >&2
    return 2
  fi
  ghr_repo=$1
  ghr_manifest=$(ghr_manifest_path_for_repo "${ghr_repo}")
  if [ ! -f "${ghr_manifest}" ]; then
    return 1
  fi
  ghr_keys=""
  while IFS= read -r ghr_line; do
    case "${ghr_line}" in
      ''|'#'*)
        continue
        ;;
    esac
    ghr_key=${ghr_line%%=*}
    if [ -z "${ghr_keys}" ]; then
      ghr_keys=${ghr_key}
    else
      ghr_keys="${ghr_keys} ${ghr_key}"
    fi
  done <"${ghr_manifest}"
  (
    set -eu
    # shellcheck disable=SC1090
    . "${ghr_manifest}"
    for ghr_key in ${ghr_keys}; do
      eval "ghr_value=\"\${${ghr_key}-}\""
      printf '%s=%s\n' "${ghr_key}" "${ghr_value}"
    done
  )
}

ghr_overlay_resolve_roots() {
  if [ "$#" -ne 2 ]; then
    printf 'ghr_overlay_resolve_roots requires <repo> <home>\n' >&2
    return 2
  fi
  ghr_repo=$1
  ghr_home=$2
  ghr_in_repo "${ghr_repo}" "${ghr_home}" \
    PROJECT_ROOT="${GIT_REPO_PROJECT_ROOT:-}" \
    GIT_REPO_PROJECT_ROOT="${GIT_REPO_PROJECT_ROOT:-}" \
    sh -eu <<'SH'
project=${PROJECT_ROOT:-${GIT_REPO_PROJECT_ROOT:-}}
if [ -z "${project}" ]; then
  exit 0
fi
common="${project}/lib/common.sh"
lifecycle="${project}/lib/ephemeral_lifecycle.sh"
overlay="${project}/lib/ephemeral_overlay.sh"
if [ ! -f "${common}" ] || [ ! -f "${lifecycle}" ] || [ ! -f "${overlay}" ]; then
  exit 0
fi
# shellcheck disable=SC1090
. "${common}"
# shellcheck disable=SC1090
. "${lifecycle}"
# shellcheck disable=SC1090
. "${overlay}"

precedence=$(ephemeral_manifest_get PRECEDENCE_MODE || true)
if [ -n "${precedence}" ]; then
  export GITHOOKS_EPHEMERAL_PRECEDENCE="${precedence}"
fi

roots=$(ephemeral_overlay_resolve_roots)
printf '%s\n' "${roots}" | sed 's/\\n/\n/g'
SH
}

ghr_overlay_log_dump() {
  if [ "$#" -ne 2 ]; then
    printf 'ghr_overlay_log_dump requires <repo> <home>\n' >&2
    return 2
  fi
  ghr_repo=$1
  ghr_home=$2
  ghr_in_repo "${ghr_repo}" "${ghr_home}" \
    PROJECT_ROOT="${GIT_REPO_PROJECT_ROOT:-}" \
    GIT_REPO_PROJECT_ROOT="${GIT_REPO_PROJECT_ROOT:-}" \
    sh -eu <<'SH'
project=${PROJECT_ROOT:-${GIT_REPO_PROJECT_ROOT:-}}
if [ -z "${project}" ]; then
  exit 0
fi
common="${project}/lib/common.sh"
lifecycle="${project}/lib/ephemeral_lifecycle.sh"
overlay="${project}/lib/ephemeral_overlay.sh"
if [ ! -f "${common}" ] || [ ! -f "${lifecycle}" ] || [ ! -f "${overlay}" ]; then
  exit 0
fi
# shellcheck disable=SC1090
. "${common}"
# shellcheck disable=SC1090
. "${lifecycle}"
# shellcheck disable=SC1090
. "${overlay}"

precedence=$(ephemeral_manifest_get PRECEDENCE_MODE || true)
if [ -n "${precedence}" ]; then
  export GITHOOKS_EPHEMERAL_PRECEDENCE="${precedence}"
fi

roots=$(ephemeral_overlay_resolve_roots)
mode_value=${precedence:-$(ephemeral_precedence_mode)}
if [ -z "${roots}" ]; then
  printf '[hook-runner] INFO: Ephemeral overlay order (%s): <none>\n' "${mode_value}"
  exit 0
fi
printf '[hook-runner] INFO: Ephemeral overlay order (%s):\n' "${mode_value}"
index=0
printf '%s\n' "${roots}" | sed 's/\\n/\n/g' | while IFS= read -r path; do
  [ -n "${path}" ] || continue
  index=$((index + 1))
  if [ -d "${path}" ]; then
    state=present
  else
    state=missing
  fi
  printf '[hook-runner] INFO:   [%d] %s (%s)\n' "${index}" "${path}" "${state}"
done
SH
}

ghr_environment_snapshot() {
  if [ "$#" -ne 2 ]; then
    printf 'ghr_environment_snapshot requires <repo> <home>\n' >&2
    return 2
  fi
  ghr_repo=$1
  ghr_home=$2
  ghr_in_repo "${ghr_repo}" "${ghr_home}" sh -eu <<'SH'
env_keys="PWD HOME PATH TMPDIR SHELL USER LOGNAME GIT_REPO_WORK GIT_REPO_HOME GIT_REPO_BASE GIT_REPO_REMOTE"
for env_key in ${env_keys}; do
  eval "env_value=\"\${${env_key}-}\""
  printf '%s=%s\n' "${env_key}" "${env_value}"
done
if command -v git >/dev/null 2>&1; then
  git_version=$(git --version 2>/dev/null || printf 'unknown')
  printf 'GIT_VERSION=%s\n' "${git_version}"
else
  printf 'GIT_VERSION=missing\n'
fi
printf 'UNAME_S=%s\n' "$(uname -s 2>/dev/null || printf 'unknown')"
SH
}
