#!/bin/sh
# TAP tests covering CLI ergonomics for install.sh subcommand-based staging (add).

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

test_add_examples_sources_parts() {
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
    if ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" stage add examples; then
      TEST_FAILURE_DIAG='installer add examples failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    target="$parsed_repo/.githooks/pre-commit.d/git-crypt-enforce.sh"
    if [ ! -x "$target" ]; then
      TEST_FAILURE_DIAG='expected pre-commit example was not staged via add examples'
      rc=1
    fi
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

test_add_for_specific_hook_filters() {
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
    if ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" stage add examples --hook pre-commit; then
      TEST_FAILURE_DIAG='installer stage add examples with --hook failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    target="$parsed_repo/.githooks/pre-commit.d/git-crypt-enforce.sh"
    if [ ! -x "$target" ]; then
      TEST_FAILURE_DIAG='expected staged file missing after stage add with --hook pre-commit'
      rc=1
    fi
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

test_add_dry_run_prevents_changes() {
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
    if ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" stage add examples --dry-run; then
      :
    else
      TEST_FAILURE_DIAG='installer add examples --dry-run failed'
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

test_add_with_for_hook_filters_sources() {
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
    if ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" stage add examples --hook pre-commit; then
      TEST_FAILURE_DIAG='stage add with --hook command failed'
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
      TEST_FAILURE_DIAG='unexpected dependency-sync staged when filtering by hook pre-commit'
      rc=1
    fi
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

test_add_dry_run_emits_plan_summary() {
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
    if ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" stage add examples --dry-run >"$summary_file"; then
      TEST_FAILURE_DIAG='stage add examples --dry-run summary command failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    plan_lines=$(grep 'PLAN:' "$summary_file" || true)
    if [ -z "$plan_lines" ]; then
      TEST_FAILURE_DIAG='summary output missing PLAN lines'
      rc=1
    fi
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

test_add_no_legacy_warnings() {
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
    if ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" stage add examples --dry-run >"$log_file" 2>&1; then
      :
    else
      TEST_FAILURE_DIAG='stage add examples --dry-run failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if grep -qi 'legacy' "$log_file"; then
      TEST_FAILURE_DIAG='unexpected legacy warning printed'
      rc=1
    fi
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

test_add_with_csv_hook_filters() {
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
    if ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" stage add examples --hook post-merge,post-rewrite; then
      TEST_FAILURE_DIAG='installer add examples with CSV hooks failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    post_merge_part="$parsed_repo/.githooks/post-merge.d/dependency-sync.sh"
    post_rewrite_part="$parsed_repo/.githooks/post-rewrite.d/dependency-sync.sh"
    meta_post_merge="$parsed_repo/.githooks/post-merge.d/metadata-apply.sh"
    meta_post_rewrite="$parsed_repo/.githooks/post-rewrite.d/metadata-apply.sh"
    if [ ! -x "$post_merge_part" ] || [ ! -x "$post_rewrite_part" ]; then
      TEST_FAILURE_DIAG='CSV hook filter did not stage dependency-sync for both hooks'
      rc=1
    elif [ ! -x "$meta_post_merge" ] || [ ! -x "$meta_post_rewrite" ]; then
      TEST_FAILURE_DIAG='CSV hook filter missed metadata apply script for one or more hooks'
      rc=1
    fi
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

test_add_with_name_filter_selects_single_part() {
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
    if ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" stage add examples --name git-crypt-enforce; then
      TEST_FAILURE_DIAG='stage add with --name git-crypt-enforce failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    target="$parsed_repo/.githooks/pre-commit.d/git-crypt-enforce.sh"
    if [ ! -x "$target" ]; then
      TEST_FAILURE_DIAG='name filter did not stage expected part'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    unexpected="$parsed_repo/.githooks/post-merge.d/dependency-sync.sh"
    if [ -e "$unexpected" ]; then
      TEST_FAILURE_DIAG='name filter staged unexpected dependency-sync part'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    meta_post_merge="$parsed_repo/.githooks/post-merge.d/metadata-apply.sh"
    if [ -e "$meta_post_merge" ]; then
      TEST_FAILURE_DIAG='name filter staged metadata apply despite mismatch'
      rc=1
    fi
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

test_add_with_name_glob_matches_multiple_parts() {
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
    if ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" stage add examples --name 'metadata-*'; then
      TEST_FAILURE_DIAG="stage add with --name 'metadata-*' failed"
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    meta_post_merge="$parsed_repo/.githooks/post-merge.d/metadata-apply.sh"
    meta_post_rewrite="$parsed_repo/.githooks/post-rewrite.d/metadata-apply.sh"
    if [ ! -x "$meta_post_merge" ] || [ ! -x "$meta_post_rewrite" ]; then
      TEST_FAILURE_DIAG='glob name filter did not stage metadata apply for expected hooks'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    unexpected="$parsed_repo/.githooks/pre-commit.d/git-crypt-enforce.sh"
    if [ -e "$unexpected" ]; then
      TEST_FAILURE_DIAG='glob name filter staged unrelated pre-commit part'
      rc=1
    fi
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

test_add_from_vendored_toolkit_skips_duplicate_runner_copy() {
  TEST_FAILURE_DIAG=''
  tuple=$(ghr_mk_sandbox) || {
    TEST_FAILURE_DIAG='failed to create sandbox'
    return 1
  }
  parse_tuple "$tuple"
  trap 'ghr_cleanup_sandbox "$parsed_base"' EXIT
  rc=0
  stdout_log="$parsed_repo/stage.out"
  stderr_log="$parsed_repo/stage.err"

  if [ "$rc" -eq 0 ] && ! ghr_init_repo "$parsed_repo" "$parsed_home"; then
    TEST_FAILURE_DIAG='git init failed'
    rc=1
  fi

  vendor_dir="$parsed_repo/.githooks"

  if [ "$rc" -eq 0 ]; then
    if ! mkdir -p "$vendor_dir"; then
      TEST_FAILURE_DIAG='failed to create vendored directory'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! cp "$REPO_ROOT/install.sh" "$vendor_dir/install.sh"; then
      TEST_FAILURE_DIAG='failed to copy install.sh into vendored directory'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! cp "$REPO_ROOT/_runner.sh" "$vendor_dir/_runner.sh"; then
      TEST_FAILURE_DIAG='failed to copy runner into vendored directory'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! cp -R "$REPO_ROOT/lib" "$vendor_dir/"; then
      TEST_FAILURE_DIAG='failed to copy lib directory into vendored directory'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! cp -R "$REPO_ROOT/examples" "$vendor_dir/"; then
      TEST_FAILURE_DIAG='failed to copy examples directory into vendored directory'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! chmod 755 "$vendor_dir/install.sh" "$vendor_dir/_runner.sh"; then
      TEST_FAILURE_DIAG='failed to mark vendored scripts executable'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ghr_in_repo "$parsed_repo" "$parsed_home" ./.githooks/install.sh stage add examples --name 'git-crypt-enforce' >"$stdout_log" 2>"$stderr_log"; then
      :
    else
      TEST_FAILURE_DIAG=$(printf 'vendored stage add failed\nstdout:\n%s\nstderr:\n%s' "$(ghr_read_or_empty "$stdout_log")" "$(ghr_read_or_empty "$stderr_log")")
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    staged_part="$parsed_repo/.githooks/pre-commit.d/git-crypt-enforce.sh"
    if [ ! -x "$staged_part" ]; then
      TEST_FAILURE_DIAG='vendored stage add did not stage expected part'
      rc=1
    fi
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

test_stage_remove_by_name() {
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
    if ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" stage add examples --hook pre-commit; then
      TEST_FAILURE_DIAG='stage add examples --hook pre-commit failed before remove'
      rc=1
    fi
  fi

  part_path="$parsed_repo/.githooks/pre-commit.d/git-crypt-enforce.sh"

  if [ "$rc" -eq 0 ] && [ ! -f "$part_path" ]; then
    TEST_FAILURE_DIAG='expected staged part missing before removal'
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" stage remove pre-commit git-crypt-enforce; then
      TEST_FAILURE_DIAG='stage remove command failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ] && [ -f "$part_path" ]; then
    TEST_FAILURE_DIAG='stage remove did not delete targeted part'
    rc=1
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

test_unstage_removes_matching_parts() {
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
    if ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" stage add examples --name 'dependency-sync'; then
      TEST_FAILURE_DIAG='stage add dependency-sync failed before unstage'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    for hook in post-merge post-rewrite post-checkout post-commit; do
      part_path="$parsed_repo/.githooks/${hook}.d/dependency-sync.sh"
      if [ ! -x "$part_path" ]; then
        TEST_FAILURE_DIAG="expected staged part missing for $hook before unstage"
        rc=1
        break
      fi
    done
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" stage unstage examples --name 'dependency-sync'; then
      TEST_FAILURE_DIAG='stage unstage dependency-sync failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    for hook in post-merge post-rewrite post-checkout post-commit; do
      part_path="$parsed_repo/.githooks/${hook}.d/dependency-sync.sh"
      if [ -e "$part_path" ]; then
        TEST_FAILURE_DIAG="unstage left dependency-sync in $hook"
        rc=1
        break
      fi
    done
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

test_unstage_dry_run_preserves_files() {
  TEST_FAILURE_DIAG=''
  tuple=$(ghr_mk_sandbox) || {
    TEST_FAILURE_DIAG='failed to create sandbox'
    return 1
  }
  parse_tuple "$tuple"
  trap 'ghr_cleanup_sandbox "$parsed_base"' EXIT
  rc=0
  plan_file="$parsed_repo/unstage-plan.out"

  if [ "$rc" -eq 0 ] && ! ghr_init_repo "$parsed_repo" "$parsed_home"; then
    TEST_FAILURE_DIAG='git init failed'
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" stage add examples --name 'dependency-sync'; then
      TEST_FAILURE_DIAG='stage add dependency-sync failed before dry-run'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" stage unstage examples --name 'dependency-sync' --dry-run >"$plan_file"; then
      TEST_FAILURE_DIAG='stage unstage --dry-run command failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    plan_lines=$(grep 'PLAN:' "$plan_file" || true)
    if [ -z "$plan_lines" ]; then
      TEST_FAILURE_DIAG='unstage dry-run missing PLAN output'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    for hook in post-merge post-rewrite post-checkout post-commit; do
      part_path="$parsed_repo/.githooks/${hook}.d/dependency-sync.sh"
      if [ ! -x "$part_path" ]; then
        TEST_FAILURE_DIAG="unstage dry-run removed file from $hook"
        rc=1
        break
      fi
    done
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

test_uninstall_does_not_remove_vendored_library() {
  TEST_FAILURE_DIAG=''
  tuple=$(ghr_mk_sandbox) || {
    TEST_FAILURE_DIAG='failed to create sandbox'
    return 1
  }
  parse_tuple "$tuple"
  trap 'ghr_cleanup_sandbox "$parsed_base"' EXIT
  rc=0
  vendor_dir="$parsed_repo/.githooks"

  if [ "$rc" -eq 0 ] && ! ghr_init_repo "$parsed_repo" "$parsed_home"; then
    TEST_FAILURE_DIAG='git init failed'
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    if ! mkdir -p "$vendor_dir"; then
      TEST_FAILURE_DIAG='failed to create vendored directory'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! cp "$REPO_ROOT/install.sh" "$vendor_dir/install.sh"; then
      TEST_FAILURE_DIAG='failed to copy install.sh into vendored directory'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! cp "$REPO_ROOT/_runner.sh" "$vendor_dir/_runner.sh"; then
      TEST_FAILURE_DIAG='failed to copy runner into vendored directory'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! cp -R "$REPO_ROOT/lib" "$vendor_dir/"; then
      TEST_FAILURE_DIAG='failed to copy lib directory into vendored directory'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! cp -R "$REPO_ROOT/examples" "$vendor_dir/"; then
      TEST_FAILURE_DIAG='failed to copy examples directory into vendored directory'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! chmod 755 "$vendor_dir/install.sh" "$vendor_dir/_runner.sh"; then
      TEST_FAILURE_DIAG='failed to chmod vendored scripts'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_in_repo "$parsed_repo" "$parsed_home" ./.githooks/install.sh uninstall; then
      TEST_FAILURE_DIAG='vendored uninstall command failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if [ ! -f "$vendor_dir/lib/common.sh" ]; then
      TEST_FAILURE_DIAG='vendored uninstall removed lib/common.sh'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_in_repo "$parsed_repo" "$parsed_home" ./.githooks/install.sh stage add examples --name 'git-crypt-enforce'; then
      TEST_FAILURE_DIAG='vendored stage add failed after uninstall'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    staged_part="$parsed_repo/.githooks/pre-commit.d/git-crypt-enforce.sh"
    if [ ! -x "$staged_part" ]; then
      TEST_FAILURE_DIAG='vendored stage add did not stage expected part after uninstall'
      rc=1
    fi
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

test_stage_list_outputs_entries() {
  TEST_FAILURE_DIAG=''
  tuple=$(ghr_mk_sandbox) || {
    TEST_FAILURE_DIAG='failed to create sandbox'
    return 1
  }
  parse_tuple "$tuple"
  trap 'ghr_cleanup_sandbox "$parsed_base"' EXIT
  rc=0
  list_file="$parsed_repo/list.out"

  if [ "$rc" -eq 0 ] && ! ghr_init_repo "$parsed_repo" "$parsed_home"; then
    TEST_FAILURE_DIAG='git init failed'
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" stage add examples --hook pre-commit; then
      TEST_FAILURE_DIAG='stage add for list verification failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" stage list >"$list_file"; then
      TEST_FAILURE_DIAG='stage list command failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! grep -q '^HOOK[[:space:]]\{1,\}PART$' "$list_file"; then
      TEST_FAILURE_DIAG='stage list output missing header'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! grep -q '^pre-commit[[:space:]]\{1,\}git-crypt-enforce\.sh$' "$list_file"; then
      TEST_FAILURE_DIAG='stage list output missing expected entry'
      rc=1
    fi
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

test_global_help_and_version() {
  TEST_FAILURE_DIAG=''
  tuple=$(ghr_mk_sandbox) || {
    TEST_FAILURE_DIAG='failed to create sandbox'
    return 1
  }
  parse_tuple "$tuple"
  trap 'ghr_cleanup_sandbox "$parsed_base"' EXIT
  rc=0
  version_file="$parsed_repo/version.out"
  help_file="$parsed_repo/help.out"

  if [ "$rc" -eq 0 ] && ! ghr_init_repo "$parsed_repo" "$parsed_home"; then
    TEST_FAILURE_DIAG='git init failed'
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" --version >"$version_file"; then
      TEST_FAILURE_DIAG='--version command failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! grep -q 'githooks-runner' "$version_file"; then
      TEST_FAILURE_DIAG='--version output missing identifier'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" --help stage >"$help_file"; then
      TEST_FAILURE_DIAG='--help stage command failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! grep -q '^NAME' "$help_file"; then
      TEST_FAILURE_DIAG='--help stage output missing NAME header'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! grep -q 'SUBCOMMANDS' "$help_file"; then
      TEST_FAILURE_DIAG='--help stage output missing subcommand section'
      rc=1
    fi
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

test_hooks_list_specific() {
  TEST_FAILURE_DIAG=''
  tuple=$(ghr_mk_sandbox) || {
    TEST_FAILURE_DIAG='failed to create sandbox'
    return 1
  }
  parse_tuple "$tuple"
  trap 'ghr_cleanup_sandbox "$parsed_base"' EXIT
  rc=0
  hooks_file="$parsed_repo/hooks.out"

  if [ "$rc" -eq 0 ] && ! ghr_init_repo "$parsed_repo" "$parsed_home"; then
    TEST_FAILURE_DIAG='git init failed'
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" stage add examples --hook pre-commit; then
      TEST_FAILURE_DIAG='stage add for hooks list failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" hooks list pre-commit >"$hooks_file"; then
      TEST_FAILURE_DIAG='hooks list pre-commit command failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! grep -q '^HOOK' "$hooks_file"; then
      TEST_FAILURE_DIAG='hooks list output missing header'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! grep -q '^pre-commit' "$hooks_file"; then
      TEST_FAILURE_DIAG='hooks list output missing target hook'
      rc=1
    fi
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

test_stage_help_subcommands() {
  TEST_FAILURE_DIAG=''
  tuple=$(ghr_mk_sandbox) || {
    TEST_FAILURE_DIAG='failed to create sandbox'
    return 1
  }
  parse_tuple "$tuple"
  trap 'ghr_cleanup_sandbox "$parsed_base"' EXIT
  rc=0
  help_stage_add="$parsed_repo/help-stage-add.out"
  help_stage_add_arg="$parsed_repo/help-stage-add-arg.out"

  if [ "$rc" -eq 0 ] && ! ghr_init_repo "$parsed_repo" "$parsed_home"; then
    TEST_FAILURE_DIAG='git init failed'
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" stage help add >"$help_stage_add"; then
      TEST_FAILURE_DIAG='stage help add command failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! grep -q 'githooks stage add - Copy hook parts' "$help_stage_add"; then
      TEST_FAILURE_DIAG='stage help add output missing MAN-style heading'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_in_repo "$parsed_repo" "$parsed_home" "$INSTALLER" stage add help >"$help_stage_add_arg"; then
      TEST_FAILURE_DIAG='stage add help invocation failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! grep -q 'OPTIONS' "$help_stage_add_arg"; then
      TEST_FAILURE_DIAG='stage add help output missing OPTIONS section'
      rc=1
    fi
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

TOTAL_TESTS=18

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

run_test 'stage add examples sources parts' test_add_examples_sources_parts
run_test 'stage add for specific hook filters examples' test_add_for_specific_hook_filters
run_test 'stage add --dry-run avoids filesystem changes' test_add_dry_run_prevents_changes
run_test 'stage add with --hook filters sources' test_add_with_for_hook_filters_sources
run_test 'stage add --dry-run emits plan summary lines' test_add_dry_run_emits_plan_summary
run_test 'stage add interface does not print legacy warnings' test_add_no_legacy_warnings
run_test 'stage add with CSV hooks stages matching examples' test_add_with_csv_hook_filters
run_test 'stage add with --name filters to one part' test_add_with_name_filter_selects_single_part
run_test 'stage add with glob name filter stages matching scripts' test_add_with_name_glob_matches_multiple_parts
run_test 'stage add from vendored toolkit skips duplicate runner copy' test_add_from_vendored_toolkit_skips_duplicate_runner_copy
run_test 'stage remove accepts bare names' test_stage_remove_by_name
run_test 'stage unstage removes matching parts' test_unstage_removes_matching_parts
run_test 'stage unstage --dry-run reports plan without changes' test_unstage_dry_run_preserves_files
run_test 'uninstall retains vendored library for restaging' test_uninstall_does_not_remove_vendored_library
run_test 'stage list prints header and entries' test_stage_list_outputs_entries
run_test 'global help and version flags respond' test_global_help_and_version
run_test 'hooks list pre-commit shows summary' test_hooks_list_specific
run_test 'stage help supports MAN output' test_stage_help_subcommands

diag "Pass=${PASS} Fail=${FAIL} Total=$((PASS+FAIL))"
if [ "$FAIL" -eq 0 ]; then
  exit 0
fi
exit 1
