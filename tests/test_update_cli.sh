#!/bin/sh
# TAP tests for the githooks update subcommand covering standard and Ephemeral Mode.

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${TEST_DIR}/.." && pwd)
LIB_PATH="${REPO_ROOT}/tests/lib/git_test_helpers.sh"
INSTALLER="${REPO_ROOT}/install.sh"

if [ ! -f "${LIB_PATH}" ]; then
  printf '1..0\n'
  printf '# Bail out! missing helper library at %s\n' "${LIB_PATH}" >&2
  exit 127
fi
if [ ! -x "${INSTALLER}" ]; then
  printf '1..0\n'
  printf '# Bail out! missing installer at %s\n' "${INSTALLER}" >&2
  exit 127
fi

# shellcheck source=tests/lib/git_test_helpers.sh
. "${LIB_PATH}"

PASS=0
FAIL=0
TOTAL=0
TEST_FAILURE_DIAG=''

diag() {
  printf '# %s\n' "$*"
}

ok() {
  PASS=$((PASS + 1))
  printf 'ok %d - %s\n' "${TOTAL}" "$1"
}

not_ok() {
  FAIL=$((FAIL + 1))
  printf 'not ok %d - %s\n' "${TOTAL}" "$1"
  if [ "${2:-}" != '' ]; then
    diag "$2"
  fi
}

tap_plan() {
  printf '1..%d\n' "$1"
}

parse_tuple() {
  tuple_value=$1
  old_ifs=$IFS
  IFS='|'
  set -- $tuple_value
  IFS=$old_ifs
  parsed_base=$1
  parsed_repo=$2
  parsed_remote=$3
  parsed_home=$4
}

cleanup_and_return() {
  cleanup_target=$1
  cleanup_status=$2
  trap - EXIT
  ghr_cleanup_sandbox "$cleanup_target"
  return "$cleanup_status"
}

test_update_refreshes_standard_install() {
  TEST_FAILURE_DIAG=''
  tuple=$(ghr_mk_sandbox) || {
    TEST_FAILURE_DIAG='failed to create sandbox'
    return 1
  }
  parse_tuple "$tuple"
  trap 'ghr_cleanup_sandbox "$parsed_base"' EXIT
  rc=0

  if [ "$rc" -eq 0 ] && ! ghr_init_repo "$parsed_repo" "$parsed_home"; then
    TEST_FAILURE_DIAG='git init failed'
    rc=1
  fi

  if [ "$rc" -eq 0 ] && ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" install --hooks post-merge; then
    TEST_FAILURE_DIAG='install --hooks post-merge failed'
    rc=1
  fi

  if [ "$rc" -eq 0 ] && ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" stage add examples --hook post-merge --name watch-configured-actions; then
    TEST_FAILURE_DIAG='stage add examples failed'
    rc=1
  fi

  part_path="${parsed_repo}/.githooks/post-merge.d/watch-configured-actions.sh"
  config_path="${parsed_repo}/.git/hooks/config/watch-configured-actions.yml"
  custom_path="${parsed_repo}/.githooks/post-merge.d/custom-script.sh"

  if [ "$rc" -eq 0 ] && [ ! -f "$part_path" ]; then
    TEST_FAILURE_DIAG='staged part missing after stage add'
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    printf '#!/bin/sh\n# outdated payload\n' >"${part_path}"
    chmod 755 "${part_path}"
  fi

  if [ "$rc" -eq 0 ]; then
    if [ ! -f "${config_path}" ]; then
      TEST_FAILURE_DIAG='watch-configured-actions config missing after stage'
      rc=1
    else
      printf 'outdated: %s\n' "$(date -u '+%s')" >"${config_path}"
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    printf '#!/bin/sh\n# custom part\n' >"${custom_path}"
    chmod 755 "${custom_path}"
    custom_cksum=$(cksum "${custom_path}" | awk '{print $1}')
  fi

  if [ "$rc" -eq 0 ] && ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" update; then
    TEST_FAILURE_DIAG='update command failed for standard mode'
    rc=1
  fi

  src_part="${REPO_ROOT}/examples/watch-configured-actions.sh"
  if [ "$rc" -eq 0 ] && [ -f "${src_part}" ]; then
    src_cksum=$(cksum "${src_part}" | awk '{print $1}')
    part_cksum=$(cksum "${part_path}" | awk '{print $1}')
    if [ "${src_cksum}" != "${part_cksum}" ]; then
      TEST_FAILURE_DIAG='staged part did not refresh to match source after update'
      rc=1
    fi
  fi

  src_config="${REPO_ROOT}/examples/config/watch-configured-actions.yml"
  if [ "$rc" -eq 0 ] && [ -f "${src_config}" ]; then
    src_cfg_cksum=$(cksum "${src_config}" | awk '{print $1}')
    dest_cfg_cksum=$(cksum "${config_path}" | awk '{print $1}')
    if [ "${src_cfg_cksum}" != "${dest_cfg_cksum}" ]; then
      TEST_FAILURE_DIAG='config file did not refresh to match source after update'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    new_custom_cksum=$(cksum "${custom_path}" | awk '{print $1}')
    if [ "${custom_cksum}" != "${new_custom_cksum}" ]; then
      TEST_FAILURE_DIAG='custom staged script was unexpectedly modified'
      rc=1
    fi
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

test_update_refreshes_ephemeral_install() {
  TEST_FAILURE_DIAG=''
  tuple=$(ghr_mk_sandbox) || {
    TEST_FAILURE_DIAG='failed to create sandbox'
    return 1
  }
  parse_tuple "$tuple"
  trap 'ghr_cleanup_sandbox "$parsed_base"' EXIT
  rc=0

  if [ "$rc" -eq 0 ] && ! ghr_init_repo "$parsed_repo" "$parsed_home"; then
    TEST_FAILURE_DIAG='git init failed'
    rc=1
  fi

  if [ "$rc" -eq 0 ] && ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" install --mode ephemeral --hooks post-merge; then
    TEST_FAILURE_DIAG='ephemeral install failed'
    rc=1
  fi

  if [ "$rc" -eq 0 ] && ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" stage add examples --hook post-merge --name watch-configured-actions; then
    TEST_FAILURE_DIAG='stage add examples failed under ephemeral mode'
    rc=1
  fi

  parts_root="${parsed_repo}/.git/.githooks/parts"
  part_path="${parts_root}/post-merge.d/watch-configured-actions.sh"
  config_path="${parsed_repo}/.git/.githooks/config/watch-configured-actions.yml"
  custom_path="${parts_root}/post-merge.d/custom-ephemeral.sh"

  if [ "$rc" -eq 0 ] && [ ! -f "${part_path}" ]; then
    TEST_FAILURE_DIAG='staged part missing in Ephemeral Mode after stage'
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    printf '#!/bin/sh\n# stale ephemeral payload\n' >"${part_path}"
    chmod 755 "${part_path}"
  fi

  if [ "$rc" -eq 0 ]; then
    if [ ! -f "${config_path}" ]; then
      TEST_FAILURE_DIAG='ephemeral config missing after stage'
      rc=1
    else
      printf 'stale-config: %s\n' "$(date -u '+%s')" >"${config_path}"
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    printf '#!/bin/sh\n# custom ephemeral part\n' >"${custom_path}"
    chmod 755 "${custom_path}"
    custom_cksum=$(cksum "${custom_path}" | awk '{print $1}')
  fi

  update_log="${parsed_repo}/update-ephemeral.log"
  if [ "$rc" -eq 0 ] && ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" update --mode ephemeral >"${update_log}" 2>&1; then
    TEST_FAILURE_DIAG='update --mode ephemeral failed'
    rc=1
  fi

  if [ "$rc" -eq 0 ] && [ -f "${update_log}" ]; then
    while IFS= read -r update_line || [ -n "${update_line}" ]; do
      diag "ephemeral update: ${update_line}"
    done <"${update_log}"
  fi

  if [ "$rc" -eq 0 ]; then
    roots_value=$(ghr_manifest_value "$parsed_repo" ROOTS || true)
    diag "ephemeral roots: ${roots_value}"
  fi

  src_part="${REPO_ROOT}/examples/watch-configured-actions.sh"
  if [ "$rc" -eq 0 ] && [ -f "${src_part}" ]; then
    src_cksum=$(cksum "${src_part}" | awk '{print $1}')
    part_cksum=$(cksum "${part_path}" | awk '{print $1}')
    if [ "${src_cksum}" != "${part_cksum}" ]; then
      TEST_FAILURE_DIAG='ephemeral staged part did not refresh to match source'
      rc=1
    fi
  fi

  src_config="${REPO_ROOT}/examples/config/watch-configured-actions.yml"
  if [ "$rc" -eq 0 ] && [ -f "${src_config}" ]; then
    src_cfg_cksum=$(cksum "${src_config}" | awk '{print $1}')
    dest_cfg_cksum=$(cksum "${config_path}" | awk '{print $1}')
    if [ "${src_cfg_cksum}" != "${dest_cfg_cksum}" ]; then
      TEST_FAILURE_DIAG='ephemeral config did not refresh to match source'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    new_custom_cksum=$(cksum "${custom_path}" | awk '{print $1}')
    if [ "${custom_cksum}" != "${new_custom_cksum}" ]; then
      TEST_FAILURE_DIAG='custom ephemeral script was unexpectedly modified'
      rc=1
    fi
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

run_test() {
  name=$1
  func=$2
  TOTAL=$((TOTAL + 1))
  if ${func}; then
    ok "$name"
  else
    not_ok "$name" "${TEST_FAILURE_DIAG}"
  fi
}

TOTAL_TESTS=2
tap_plan "$TOTAL_TESTS"

run_test 'update refreshes staged parts in standard mode' test_update_refreshes_standard_install
run_test 'update refreshes staged parts in Ephemeral Mode' test_update_refreshes_ephemeral_install

exit 0
