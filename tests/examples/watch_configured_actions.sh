#!/bin/sh
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

example_test_watch_configured_actions() {
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

  example_cleanup_watch_configured_actions() {
    ghr_cleanup_sandbox "${base_dir}"
  }
  trap example_cleanup_watch_configured_actions EXIT

  rc=0

  if [ "${rc}" -eq 0 ]; then
    if ! ghr_init_repo "${repo_dir}" "${home_dir}"; then
      TEST_FAILURE_DIAG='git init failed'
      rc=1
    fi
  fi

  if [ "${rc}" -eq 0 ]; then
    if ! ghr_install_runner "${repo_dir}" "${home_dir}" "${INSTALLER}" 'post-merge'; then
      TEST_FAILURE_DIAG='runner install failed'
      rc=1
    fi
  fi

  if [ "${rc}" -eq 0 ]; then
    parts_dir="${repo_dir}/.githooks/post-merge.d"
    mkdir -p "${parts_dir}"
    if ! cp "${EXAMPLES_DIR}/watch-configured-actions.sh" "${parts_dir}/40-watch-configured-actions.sh"; then
      TEST_FAILURE_DIAG='failed to copy watch-configured-actions example'
      rc=1
    else
      chmod 755 "${parts_dir}/40-watch-configured-actions.sh"
    fi
  fi

  if [ "${rc}" -eq 0 ]; then
    base_branch=$(ghr_git "${repo_dir}" "${home_dir}" symbolic-ref --short HEAD 2>/dev/null || printf 'master')
  fi

  if [ "${rc}" -eq 0 ]; then
    cat <<'YAML' >"${repo_dir}/.githooks/watch-config.yaml"
- name: json-yaml-shared
  patterns: ["*.json", "*.yaml"]
  commands:
    - "printf 'shared-json-yaml\n' >> log-a"
- name: yaml-extended
  patterns:
    - "*.yaml"
  commands:
    - "printf 'yaml-first\n' >> log-b; exit 1"
    - "printf 'yaml-second\n' >> log-b"
  continue_on_error: true
- name: yaml-md-shared
  patterns: ["*.yaml", "*.md"]
  commands:
    - "printf 'yaml-md-shared\n' >> log-c"
- name: yaml-only-no-cmds
  patterns:
    - "*.yaml"
YAML
  fi

  if [ "${rc}" -eq 0 ]; then
    if ! ghr_git "${repo_dir}" "${home_dir}" checkout -b feature >/dev/null 2>&1; then
      TEST_FAILURE_DIAG='failed to create feature branch'
      rc=1
    fi
  fi

  if [ "${rc}" -eq 0 ]; then
    printf '{"version": 1}
' >"${repo_dir}/config.json"
    printf 'name: example
' >"${repo_dir}/config.yaml"
    printf '# Docs
' >"${repo_dir}/README.md"
    ghr_git "${repo_dir}" "${home_dir}" add config.json config.yaml README.md
    ghr_git "${repo_dir}" "${home_dir}" commit -q -m 'feat: add watched files'
    ghr_git "${repo_dir}" "${home_dir}" checkout "${base_branch}" >/dev/null 2>&1
  fi

  inline_rules=$(cat <<'INLINE_RULES'
name=json-yaml-shared
patterns=*.json,*.yaml
commands=printf "shared-json-yaml\n" >> log-a

name=yaml-extended
patterns=*.yaml
commands=printf "yaml-first\n" >> log-b; exit 1
commands=printf "yaml-second\n" >> log-b
continue_on_error=true

name=yaml-md-shared
patterns=*.yaml,*.md
commands=printf "yaml-md-shared\n" >> log-c

name=yaml-only-no-cmds
patterns=*.yaml
INLINE_RULES
)

  if [ "${rc}" -eq 0 ]; then
    if ! ghr_in_repo "${repo_dir}" "${home_dir}" \
      WATCH_INLINE_RULES="${inline_rules}" \
      GITHOOKS_WATCH_MARK_FILE=".git/watch-config.mark" \
      git merge --no-ff feature -q -m 'merge feature'; then
      TEST_FAILURE_DIAG='git merge failed'
      rc=1
    fi
  fi

  if [ "${rc}" -eq 0 ]; then
    mark_file="${repo_dir}/.git/watch-config.mark"
    log_a="${repo_dir}/log-a"
    log_b="${repo_dir}/log-b"
    log_c="${repo_dir}/log-c"

    if [ ! -f "${mark_file}" ]; then
      TEST_FAILURE_DIAG='mark file not created'
      rc=1
    else
      mark_contents=$(ghr_read_or_empty "${mark_file}")
      case "${mark_contents}" in
        *'trigger=json-yaml-shared: config.json'*) : ;;
        *) TEST_FAILURE_DIAG='mark file missing json-yaml trigger'; rc=1 ;;
      esac
      if [ "${rc}" -eq 0 ]; then
        case "${mark_contents}" in
          *'trigger=yaml-extended: config.yaml'*) : ;;
          *) TEST_FAILURE_DIAG='mark file missing yaml-extended trigger'; rc=1 ;;
        esac
      fi
      if [ "${rc}" -eq 0 ]; then
        case "${mark_contents}" in
          *'trigger=yaml-md-shared: config.yaml'*) : ;;
          *) TEST_FAILURE_DIAG='mark file missing yaml-md-shared trigger'; rc=1 ;;
        esac
      fi
    fi

    if [ "${rc}" -eq 0 ]; then
      if [ ! -f "${log_a}" ]; then
        TEST_FAILURE_DIAG='log-a not created'
        rc=1
      else
        case $(ghr_read_or_empty "${log_a}") in
          *'shared-json-yaml'*) : ;;
          *) TEST_FAILURE_DIAG='log-a missing expected entry'; rc=1 ;;
        esac
      fi
    fi

    if [ "${rc}" -eq 0 ]; then
      if [ ! -f "${log_b}" ]; then
        TEST_FAILURE_DIAG='log-b not created'
        rc=1
      else
        logb=$(ghr_read_or_empty "${log_b}")
        case "${logb}" in
          *'yaml-first'*) : ;;
          *) TEST_FAILURE_DIAG='log-b missing first command entry'; rc=1 ;;
        esac
        if [ "${rc}" -eq 0 ]; then
          case "${logb}" in
            *'yaml-second'*) : ;;
            *) TEST_FAILURE_DIAG='log-b missing continuation command entry'; rc=1 ;;
          esac
        fi
      fi
    fi

    if [ "${rc}" -eq 0 ]; then
      if [ ! -f "${log_c}" ]; then
        TEST_FAILURE_DIAG='log-c not created'
        rc=1
      else
        case $(ghr_read_or_empty "${log_c}") in
          *'yaml-md-shared'*) : ;;
          *) TEST_FAILURE_DIAG='log-c missing expected entry'; rc=1 ;;
        esac
      fi
    fi
  fi

  trap - EXIT
  ghr_cleanup_sandbox "${base_dir}"
  return "${rc}"
}

example_register 'watch-configured-actions example executes configured commands and continues on error' example_test_watch_configured_actions

if [ "${EXAMPLE_TEST_RUN_MODE:-standalone}" = "standalone" ]; then
  if example_run_self; then
    exit 0
  fi
  exit 1
fi

