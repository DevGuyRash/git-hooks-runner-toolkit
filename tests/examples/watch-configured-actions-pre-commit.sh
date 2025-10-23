#!/bin/sh
# githooks-stage: pre-commit
# shellcheck shell=sh

set -eu

if [ -n "${EXAMPLE_CURRENT_SCRIPT:-}" ]; then
  example_source="${EXAMPLE_CURRENT_SCRIPT}"
else
  example_source=$0
  if [ ! -f "${example_source}" ] && [ "$#" -gt 0 ] && [ -f "$1" ]; then
    example_source=$1
  fi
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "${example_source}")" && pwd)
# shellcheck source=tests/examples/common.sh
. "${SCRIPT_DIR}/common.sh"

example_tests_init

example_test_watch_configured_actions_pre_commit_runs_with_central_config() {
  TEST_FAILURE_DIAG=''
  tuple=$(ghr_mk_sandbox) || {
    TEST_FAILURE_DIAG='failed to create sandbox'
    return 1
  }
  old_ifs=$IFS
  IFS='|'
  set -- ${tuple}
  IFS=${old_ifs}
  base_dir=$1
  repo_dir=$2
  remote_dir=$3
  home_dir=$4

  example_cleanup_watch_configured_actions_pre_commit() {
    ghr_cleanup_sandbox "${base_dir}"
  }
  trap example_cleanup_watch_configured_actions_pre_commit EXIT

  rc=0

  if [ "${rc}" -eq 0 ]; then
    if ! ghr_init_repo "${repo_dir}" "${home_dir}"; then
      TEST_FAILURE_DIAG='git init failed'
      rc=1
    fi
  fi

  if [ "${rc}" -eq 0 ]; then
    if ! ghr_install_runner "${repo_dir}" "${home_dir}" "${INSTALLER}" 'pre-commit'; then
      TEST_FAILURE_DIAG='runner install failed'
      rc=1
    fi
  fi

  if [ "${rc}" -eq 0 ]; then
    if ! ghr_in_repo "${repo_dir}" "${home_dir}" \
      "${INSTALLER}" stage add examples --hook pre-commit --name watch-configured-actions-pre-commit; then
      TEST_FAILURE_DIAG='stage add failed'
      rc=1
    fi
  fi

  config_path="${repo_dir}/.git/hooks/config/watch-configured-actions.yml"
  part_path="${repo_dir}/.githooks/pre-commit.d/watch-configured-actions-pre-commit.sh"

  if [ "${rc}" -eq 0 ]; then
    if [ ! -f "${config_path}" ]; then
      TEST_FAILURE_DIAG='central config not staged in standard mode'
      rc=1
    else
      src_sum=$(cksum <"${EXAMPLES_DIR}/config/watch-configured-actions.yml" 2>/dev/null || printf '')
      dest_sum=$(cksum <"${config_path}" 2>/dev/null || printf '')
      if [ -z "${src_sum}" ] || [ -z "${dest_sum}" ] || [ "${src_sum}" != "${dest_sum}" ]; then
        TEST_FAILURE_DIAG='standard config contents differ from example asset'
        rc=1
      fi
    fi
  fi

  if [ "${rc}" -eq 0 ]; then
    cat <<'YAML' >"${config_path}"
- name: staged-json
  patterns:
    - "src/*.json"
  commands:
    - "printf 'json-check\n' >> precommit.log"
YAML
  fi

  if [ "${rc}" -eq 0 ]; then
    if [ ! -f "${part_path}" ]; then
      TEST_FAILURE_DIAG='pre-commit part not staged'
      rc=1
    fi
  fi

  if [ "${rc}" -eq 0 ]; then
    mkdir -p "${repo_dir}/src"
    printf '{"alpha":1}\n' >"${repo_dir}/src/config.json"
    if ! ghr_git "${repo_dir}" "${home_dir}" add src/config.json; then
      TEST_FAILURE_DIAG='failed to stage config.json'
      rc=1
    fi
  fi

  if [ "${rc}" -eq 0 ]; then
    if ! ghr_in_repo "${repo_dir}" "${home_dir}" \
      GITHOOKS_WATCH_MARK_FILE=.git/watch-config.mark \
      git commit -q -m 'feat: trigger pre-commit'; then
      TEST_FAILURE_DIAG='git commit failed'
      rc=1
    fi
  fi

  log_file="${repo_dir}/precommit.log"
  mark_file="${repo_dir}/.git/watch-config.mark"

  if [ "${rc}" -eq 0 ]; then
    if [ ! -f "${log_file}" ]; then
      TEST_FAILURE_DIAG='precommit log not created'
      rc=1
    else
      case $(ghr_read_or_empty "${log_file}") in
        *'json-check'*) : ;;
        *)
          TEST_FAILURE_DIAG='precommit log missing expected entry'
          rc=1
          ;;
      esac
    fi
  fi

  if [ "${rc}" -eq 0 ]; then
    if [ ! -f "${mark_file}" ]; then
      TEST_FAILURE_DIAG='mark file not created for pre-commit'
      rc=1
    else
      mark_contents=$(ghr_read_or_empty "${mark_file}")
      case "${mark_contents}" in
        *'hook=pre-commit'*) : ;;
        *) TEST_FAILURE_DIAG='mark file missing hook entry'; rc=1 ;;
      esac
      if [ "${rc}" -eq 0 ]; then
        case "${mark_contents}" in
          *'trigger=staged-json:'*) : ;;
          *) TEST_FAILURE_DIAG='mark file missing staged-json trigger'; rc=1 ;;
        esac
      fi
    fi
  fi

  trap - EXIT
  ghr_cleanup_sandbox "${base_dir}"
  return "${rc}"
}

example_test_watch_configured_actions_copies_config_ephemeral() {
  TEST_FAILURE_DIAG=''
  tuple=$(ghr_mk_sandbox) || {
    TEST_FAILURE_DIAG='failed to create sandbox'
    return 1
  }
  old_ifs=$IFS
  IFS='|'
  set -- ${tuple}
  IFS=${old_ifs}
  base_dir=$1
  repo_dir=$2
  remote_dir=$3
  home_dir=$4

  example_cleanup_watch_configured_actions_ephemeral() {
    ghr_cleanup_sandbox "${base_dir}"
  }
  trap example_cleanup_watch_configured_actions_ephemeral EXIT

  rc=0

  if [ "${rc}" -eq 0 ]; then
    if ! ghr_init_repo "${repo_dir}" "${home_dir}"; then
      TEST_FAILURE_DIAG='git init failed'
      rc=1
    fi
  fi

  if [ "${rc}" -eq 0 ]; then
    if ! ghr_in_repo "${repo_dir}" "${home_dir}" \
      "${INSTALLER}" install --mode ephemeral --hooks pre-commit; then
      TEST_FAILURE_DIAG='ephemeral install failed'
      rc=1
    fi
  fi

  if [ "${rc}" -eq 0 ]; then
    if ! ghr_in_repo "${repo_dir}" "${home_dir}" \
      "${INSTALLER}" stage add examples --hook pre-commit --name watch-configured-actions-pre-commit; then
      TEST_FAILURE_DIAG='stage add failed in ephemeral mode'
      rc=1
    fi
  fi

  config_path="${repo_dir}/.git/.githooks/config/watch-configured-actions.yml"
  part_path="${repo_dir}/.githooks/pre-commit.d/watch-configured-actions-pre-commit.sh"

  if [ "${rc}" -eq 0 ]; then
    if [ ! -f "${config_path}" ]; then
      TEST_FAILURE_DIAG='central config not staged in ephemeral mode'
      rc=1
    fi
  fi

  if [ "${rc}" -eq 0 ]; then
    if [ ! -f "${part_path}" ]; then
      TEST_FAILURE_DIAG='ephemeral pre-commit part not staged'
      rc=1
    fi
  fi

  if [ "${rc}" -eq 0 ]; then
    src_sum=$(cksum <"${EXAMPLES_DIR}/config/watch-configured-actions.yml" 2>/dev/null || printf '')
    dest_sum=$(cksum <"${config_path}" 2>/dev/null || printf '')
    if [ -z "${src_sum}" ] || [ -z "${dest_sum}" ] || [ "${src_sum}" != "${dest_sum}" ]; then
      TEST_FAILURE_DIAG='ephemeral config contents differ from example asset'
      rc=1
    fi
  fi

  trap - EXIT
  ghr_cleanup_sandbox "${base_dir}"
  return "${rc}"
}

example_register 'watch-configured-actions pre-commit runs with central config' example_test_watch_configured_actions_pre_commit_runs_with_central_config
example_register 'watch-configured-actions installer copies config in ephemeral mode' example_test_watch_configured_actions_copies_config_ephemeral

if [ "${EXAMPLE_TEST_RUN_MODE:-standalone}" = "standalone" ]; then
  if example_run_self; then
    exit 0
  fi
  exit 1
fi
