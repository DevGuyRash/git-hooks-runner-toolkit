#!/bin/sh
# TAP tests covering CLI ergonomics for install.sh stage functionality.

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
  printf 'ok %d - %s\n' "$TOTAL" "$1"
}

not_ok() {
  FAIL=$((FAIL + 1))
  printf 'not ok %d - %s\n' "$TOTAL" "$1"
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

test_stage_short_flag_with_value() {
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

  if [ "$rc" -eq 0 ]; then
    if ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" -s examples; then
      TEST_FAILURE_DIAG='installer -s examples failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    target="$parsed_repo/.githooks/pre-commit.d/git-crypt-enforce.sh"
    if [ ! -x "$target" ]; then
      TEST_FAILURE_DIAG='expected pre-commit example was not staged via -s'
      rc=1
    fi
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

test_stage_space_separated_values() {
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

  if [ "$rc" -eq 0 ]; then
    if ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" --stage examples --stage hook:pre-commit --stage name:git-crypt-enforce.sh --hooks pre-commit; then
      TEST_FAILURE_DIAG='installer --stage with space arguments failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    target="$parsed_repo/.githooks/pre-commit.d/git-crypt-enforce.sh"
    if [ ! -x "$target" ]; then
      TEST_FAILURE_DIAG='expected staged file missing after repeated --stage'
      rc=1
    fi
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

test_short_dry_run_prevents_changes() {
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

  if [ "$rc" -eq 0 ]; then
    if ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" -n -s examples; then
      :
    else
      TEST_FAILURE_DIAG='installer -n -s examples failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if [ -e "$parsed_repo/.githooks" ] || [ -e "$parsed_repo/.git/hooks/pre-commit" ]; then
      TEST_FAILURE_DIAG='dry-run still created staged artefacts'
      rc=1
    fi
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

test_granular_stage_flags() {
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

  if [ "$rc" -eq 0 ]; then
    if ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" --stage-source examples --stage-hook pre-commit --stage-name git-crypt-enforce.sh --hooks pre-commit; then
      TEST_FAILURE_DIAG='granular stage flags command failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    expected="$parsed_repo/.githooks/pre-commit.d/git-crypt-enforce.sh"
    if [ ! -x "$expected" ]; then
      TEST_FAILURE_DIAG='expected staged file missing for granular flags'
      rc=1
    fi
    if [ -e "$parsed_repo/.githooks/post-merge.d/dependency-sync.sh" ]; then
      TEST_FAILURE_DIAG='unexpected dependency-sync staged when filtering by name'
      rc=1
    fi
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

test_stage_summary_and_order() {
  TEST_FAILURE_DIAG=''
  tuple=$(ghr_mk_sandbox) || {
    TEST_FAILURE_DIAG='failed to create sandbox'
    return 1
  }
  parse_tuple "$tuple"
  trap 'ghr_cleanup_sandbox "$parsed_base"' EXIT
  rc=0
  summary_file="$parsed_repo/summary.out"

  if [ "$rc" -eq 0 ] && ! ghr_init_repo "$parsed_repo" "$parsed_home"; then
    TEST_FAILURE_DIAG='git init failed'
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" --stage-source examples --stage-name dependency-sync.sh --stage-order hook --stage-summary --dry-run >"$summary_file"; then
      TEST_FAILURE_DIAG='stage summary command failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    plan_lines=$(grep 'PLAN:' "$summary_file" || true)
    if [ -z "$plan_lines" ]; then
      TEST_FAILURE_DIAG='summary output missing PLAN lines'
      rc=1
    else
      first_line=$(printf '%s' "$plan_lines" | head -n1)
      last_line=$(printf '%s' "$plan_lines" | tail -n1)
      case "$first_line" in
        *hook=post-checkout*|*hook=post-commit*|*hook=post-merge*|*hook=post-rewrite*) : ;;
        *)
          TEST_FAILURE_DIAG='unexpected first PLAN line ordering'
          rc=1
          ;;
      esac
      case "$last_line" in
        *hook=post-commit*|*hook=post-rewrite*|*hook=post-checkout*|*hook=post-merge*) : ;;
        *)
          TEST_FAILURE_DIAG='unexpected last PLAN line ordering'
          rc=1
          ;;
      esac
    fi
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

test_legacy_selector_warning() {
  TEST_FAILURE_DIAG=''
  tuple=$(ghr_mk_sandbox) || {
    TEST_FAILURE_DIAG='failed to create sandbox'
    return 1
  }
  parse_tuple "$tuple"
  trap 'ghr_cleanup_sandbox "$parsed_base"' EXIT
  rc=0
  log_file="$parsed_repo/legacy.log"

  if [ "$rc" -eq 0 ] && ! ghr_init_repo "$parsed_repo" "$parsed_home"; then
    TEST_FAILURE_DIAG='git init failed'
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    if ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" --stage=examples,hook:pre-commit --dry-run >"$log_file" 2>&1; then
      :
    else
      TEST_FAILURE_DIAG='legacy selector command failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! grep -q 'legacy' "$log_file"; then
      TEST_FAILURE_DIAG='expected legacy warning missing'
      rc=1
    fi
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

test_stage_hook_name_csv() {
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

  if [ "$rc" -eq 0 ]; then
    if ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" \
      --stage-source examples \
      --stage-hook post-merge,post-rewrite \
      --stage-name dependency-sync.sh,metadata-apply.sh; then
      TEST_FAILURE_DIAG='installer with CSV hooks/names failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    post_merge_part="$parsed_repo/.githooks/post-merge.d/dependency-sync.sh"
    post_rewrite_part="$parsed_repo/.githooks/post-rewrite.d/dependency-sync.sh"
    meta_post_merge="$parsed_repo/.githooks/post-merge.d/metadata-apply.sh"
    if [ ! -x "$post_merge_part" ] || [ ! -x "$post_rewrite_part" ]; then
      TEST_FAILURE_DIAG='CSV hook filter did not stage both hooks'
      rc=1
    elif [ ! -x "$meta_post_merge" ]; then
      TEST_FAILURE_DIAG='CSV name filter missed metadata apply script'
      rc=1
    fi
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

TOTAL_TESTS=7

tap_plan "$TOTAL_TESTS"

run_test() {
  description=$1
  fn_name=$2
  TOTAL=$((TOTAL + 1))
  if "$fn_name"; then
    ok "$description"
  else
    not_ok "$description" "$TEST_FAILURE_DIAG"
  fi
  TEST_FAILURE_DIAG=''
}

run_test 'stage short flag accepts separate value' test_stage_short_flag_with_value
run_test 'multiple --stage arguments combine selectors' test_stage_space_separated_values
run_test 'short dry-run flag avoids filesystem changes' test_short_dry_run_prevents_changes
run_test 'granular stage flags filter sources/hooks/names' test_granular_stage_flags
run_test 'stage summary honours ordering requests' test_stage_summary_and_order
run_test 'legacy comma selectors emit warning' test_legacy_selector_warning
run_test 'CSV hook/name selectors expand as expected' test_stage_hook_name_csv

diag "Pass=${PASS} Fail=${FAIL} Total=$((PASS+FAIL))"
if [ "$FAIL" -eq 0 ]; then
  exit 0
fi
exit 1
