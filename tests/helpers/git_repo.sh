#!/bin/sh
# Repository sandbox helpers for Bats integration tests.

if [ -n "${BATS_TEST_DIRNAME:-}" ]; then
  _git_repo_project_root=$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)
else
  _git_repo_project_root=$(cd "$(dirname "$0")/../.." && pwd -P)
fi

if [ -z "${GIT_REPO_PROJECT_ROOT:-}" ]; then
  GIT_REPO_PROJECT_ROOT=${_git_repo_project_root}
fi

GIT_REPO_INSTALLER="${GIT_REPO_PROJECT_ROOT}/install.sh"
GIT_REPO_HELPER_LIB="${GIT_REPO_PROJECT_ROOT}/tests/lib/git_test_helpers.sh"

if [ -f "${GIT_REPO_HELPER_LIB}" ]; then
  . "${GIT_REPO_HELPER_LIB}"
  GIT_REPO_HELPERS_AVAILABLE=1
else
  printf '%s\n' "# Bats git repo helpers unavailable at ${GIT_REPO_HELPER_LIB}" >&2
  GIT_REPO_HELPERS_AVAILABLE=0
fi

git_repo_parse_tuple() {
  if [ "$#" -ne 1 ]; then
    return 1
  fi
  _git_repo_tuple=$1
  _git_repo_old_ifs=$IFS
  IFS='|'
  set -- ${_git_repo_tuple}
  IFS=${_git_repo_old_ifs}
  GIT_REPO_BASE=$1
  GIT_REPO_WORK=$2
  GIT_REPO_REMOTE=$3
  GIT_REPO_HOME=$4
}

git_repo_setup() {
  if [ "${GIT_REPO_HELPERS_AVAILABLE}" -ne 1 ]; then
    return 1
  fi
  _git_repo_tuple=$(ghr_mk_sandbox) || return 1
  git_repo_parse_tuple "${_git_repo_tuple}" || return 1
  export GIT_REPO_BASE GIT_REPO_WORK GIT_REPO_REMOTE GIT_REPO_HOME
}

git_repo_teardown() {
  if [ -n "${GIT_REPO_BASE:-}" ]; then
    ghr_cleanup_sandbox "${GIT_REPO_BASE}"
  fi
  unset GIT_REPO_BASE GIT_REPO_WORK GIT_REPO_REMOTE GIT_REPO_HOME
}

git_repo_init() {
  if [ -z "${GIT_REPO_WORK:-}" ] || [ -z "${GIT_REPO_HOME:-}" ]; then
    return 1
  fi
  ghr_init_repo "${GIT_REPO_WORK}" "${GIT_REPO_HOME}"
}

git_repo_git() {
  if [ -z "${GIT_REPO_WORK:-}" ] || [ -z "${GIT_REPO_HOME:-}" ]; then
    return 1
  fi
  ghr_git "${GIT_REPO_WORK}" "${GIT_REPO_HOME}" "$@"
}

git_repo_exec() {
  if [ -z "${GIT_REPO_WORK:-}" ] || [ -z "${GIT_REPO_HOME:-}" ]; then
    return 1
  fi
  ghr_in_repo "${GIT_REPO_WORK}" "${GIT_REPO_HOME}" "$@"
}

git_repo_project_root() {
  printf '%s\n' "${GIT_REPO_PROJECT_ROOT}"
}

git_repo_installer_path() {
  printf '%s\n' "${GIT_REPO_INSTALLER}"
}

git_repo_manifest_path() {
  if [ -z "${GIT_REPO_WORK:-}" ]; then
    return 1
  fi
  printf '%s\n' "${GIT_REPO_WORK}/.git/.githooks/manifest.sh"
}

git_repo_manifest_value() {
  if [ "$#" -ne 1 ]; then
    return 1
  fi
  _git_repo_key=$1
  _git_repo_manifest=$(git_repo_manifest_path) || return 1
  if [ ! -f "${_git_repo_manifest}" ]; then
    return 1
  fi
  (
    # shellcheck disable=SC1090
    . "${_git_repo_manifest}"
    eval "printf '%s\\n' \"\${${_git_repo_key}-}\""
  )
}

