#!/bin/sh
# Comprehensive TAP tests for git hook runner toolkit.
# Usage: sh tests/test_git_hooks_runner.sh

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)

candidate_root=$(CDPATH= cd -- "${TEST_DIR}/.." && pwd)
if [ -f "${candidate_root}/install.sh" ] && [ -d "${candidate_root}/examples" ]; then
  REPO_ROOT=${candidate_root}
  LIB_PATH="${REPO_ROOT}/tests/lib/git_test_helpers.sh"
  INSTALLER="${REPO_ROOT}/install.sh"
else
  REPO_ROOT=$(CDPATH= cd -- "${TEST_DIR}/../../.." && pwd)
  LIB_PATH="${REPO_ROOT}/scripts/.githooks/tests/lib/git_test_helpers.sh"
  if [ ! -f "${LIB_PATH}" ]; then
    LIB_PATH="${REPO_ROOT}/tests/lib/git_test_helpers.sh"
  fi
  INSTALLER="${REPO_ROOT}/scripts/.githooks/install.sh"
fi

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

version_ge() {
  if [ "$#" -ne 2 ]; then
    return 1
  fi
  version_ge_have=$1
  version_ge_need=$2
  version_ge_index=1
  while :; do
    version_ge_have_part=$(printf '%s' "$version_ge_have" | cut -d. -f"$version_ge_index")
    version_ge_need_part=$(printf '%s' "$version_ge_need" | cut -d. -f"$version_ge_index")
    [ -n "$version_ge_have_part" ] || version_ge_have_part=0
    [ -n "$version_ge_need_part" ] || version_ge_need_part=0
    if [ "$version_ge_have_part" -gt "$version_ge_need_part" ] 2>/dev/null; then
      return 0
    fi
    if [ "$version_ge_have_part" -lt "$version_ge_need_part" ] 2>/dev/null; then
      return 1
    fi
    version_ge_index=$((version_ge_index + 1))
    version_ge_have_next=$(printf '%s' "$version_ge_have" | cut -d. -f"$version_ge_index")
    version_ge_need_next=$(printf '%s' "$version_ge_need" | cut -d. -f"$version_ge_index")
    if [ -z "$version_ge_have_next" ] && [ -z "$version_ge_need_next" ]; then
      return 0
    fi
    if [ "$version_ge_index" -gt 8 ]; then
      return 0
    fi
  done
}

get_git_version() {
  git --version 2>/dev/null | awk '{print $NF}'
}

GIT_VERSION=$(get_git_version)
REQUIRED_VERSION=2.40.0

if [ -z "$GIT_VERSION" ]; then
  printf '1..0\n'
  diag 'SKIP git binary unavailable'
  exit 0
fi

if ! version_ge "$GIT_VERSION" "$REQUIRED_VERSION"; then
  printf '1..0\n'
  diag "SKIP requires git >= $REQUIRED_VERSION (found $GIT_VERSION)"
  exit 0
fi

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

test_pre_commit_executes_in_lexical_order() {
  TEST_FAILURE_DIAG=''
  tuple=$(ghr_mk_sandbox) || {
    TEST_FAILURE_DIAG='failed to create sandbox'
    return 1
  }
  parse_tuple "$tuple"
  trap 'ghr_cleanup_sandbox "$parsed_base"' EXIT
  rc=0

  order_log="$parsed_repo/order.log"

  if [ "$rc" -eq 0 ] && ! ghr_init_repo "$parsed_repo" "$parsed_home"; then
    TEST_FAILURE_DIAG='git init failed'
    rc=1
  fi

  if [ "$rc" -eq 0 ] && ! ghr_install_runner "$parsed_repo" "$parsed_home" "$INSTALLER" 'pre-commit'; then
    TEST_FAILURE_DIAG='runner install failed'
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    : >"$order_log"
    if ! ghr_write_part "$parsed_repo" pre-commit 10 first <<'PART'
log_file="$GITHOOKS_REPO_ROOT/order.log"
printf 'first
' >>"$log_file"
PART
    then
      TEST_FAILURE_DIAG='failed to write first part'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_write_part "$parsed_repo" pre-commit 20 middle <<'PART'
log_file="$GITHOOKS_REPO_ROOT/order.log"
printf 'middle
' >>"$log_file"
PART
    then
      TEST_FAILURE_DIAG='failed to write middle part'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_write_part "$parsed_repo" pre-commit 30 last <<'PART'
log_file="$GITHOOKS_REPO_ROOT/order.log"
printf 'last
' >>"$log_file"
PART
    then
      TEST_FAILURE_DIAG='failed to write final part'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ] && ! ghr_make_commit "$parsed_repo" "$parsed_home" 'alpha.txt' 'alpha' 'feat: trigger pre-commit'; then
    TEST_FAILURE_DIAG='commit failed unexpectedly'
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    count=0
    first_line=''
    second_line=''
    third_line=''
    if [ -f "$order_log" ]; then
      while IFS= read -r entry; do
        count=$((count + 1))
        case $count in
          1) first_line=$entry ;;
          2) second_line=$entry ;;
          3) third_line=$entry ;;
        esac
      done <"$order_log"
    fi
    if [ "$count" -ne 3 ]; then
      TEST_FAILURE_DIAG="expected 3 log entries, got $count"
      rc=1
    elif [ "$first_line" != 'first' ] || [ "$second_line" != 'middle' ] || [ "$third_line" != 'last' ]; then
      TEST_FAILURE_DIAG="lexical order mismatch: $first_line $second_line $third_line"
      rc=1
    fi
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

# Additional test functions follow (converted to POSIX sh).

test_pre_commit_failure_stops_sequence() {
  TEST_FAILURE_DIAG=''
  tuple=$(ghr_mk_sandbox) || {
    TEST_FAILURE_DIAG='failed to create sandbox'
    return 1
  }
  parse_tuple "$tuple"
  trap 'ghr_cleanup_sandbox "$parsed_base"' EXIT
  rc=0
  failure_log="$parsed_repo/failure.log"
  commit_out="$parsed_repo/commit.out"
  commit_err="$parsed_repo/commit.err"
  commit_status=0
  exit_code=0

  if [ "$rc" -eq 0 ] && ! ghr_init_repo "$parsed_repo" "$parsed_home"; then
    TEST_FAILURE_DIAG='git init failed'
    rc=1
  fi

  if [ "$rc" -eq 0 ] && ! ghr_install_runner "$parsed_repo" "$parsed_home" "$INSTALLER" 'pre-commit'; then
    TEST_FAILURE_DIAG='runner install failed'
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    : >"$failure_log"
    if ! ghr_write_part "$parsed_repo" pre-commit 10 first <<'PART'
log_file="${GITHOOKS_REPO_ROOT}/failure.log"
printf 'first\n' >>"${log_file}"
PART
    then
      TEST_FAILURE_DIAG='failed to write first part'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_write_part "$parsed_repo" pre-commit 20 fail <<'PART'
log_file="${GITHOOKS_REPO_ROOT}/failure.log"
printf 'fail\n' >>"${log_file}"
exit 42
PART
    then
      TEST_FAILURE_DIAG='failed to write failing part'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_write_part "$parsed_repo" pre-commit 30 skipped <<'PART'
printf 'skipped\n' >>"${GITHOOKS_REPO_ROOT}/failure.log"
PART
    then
      TEST_FAILURE_DIAG='failed to write trailing part'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    printf 'change\n' >"$parsed_repo/failing.txt"
    if ! ghr_git "$parsed_repo" "$parsed_home" add failing.txt; then
      TEST_FAILURE_DIAG='failed to stage failing.txt'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    ghr_in_repo "$parsed_repo" "$parsed_home" git commit -m 'feat: should abort' >"$commit_out" 2>"$commit_err" || commit_status=$?
    if [ "$commit_status" -eq 0 ]; then
      out_contents=$(ghr_read_or_empty "$commit_out")
      err_contents=$(ghr_read_or_empty "$commit_err")
      log_snapshot=$(ghr_read_or_empty "$failure_log")
      TEST_FAILURE_DIAG=$(printf 'commit unexpectedly succeeded\nstdout:\n%s\nstderr:\n%s\nlog:\n%s' "$out_contents" "$err_contents" "$log_snapshot")
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    exit_code=$commit_status
    if [ "$exit_code" -eq 0 ]; then
      TEST_FAILURE_DIAG='pre-commit returned zero despite failing part'
      rc=1
    elif [ "$exit_code" -ne 1 ]; then
      TEST_FAILURE_DIAG=$(printf 'unexpected commit exit: %s' "$exit_code")
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    count=0
    first_line=''
    second_line=''
    if [ -f "$failure_log" ]; then
      while IFS= read -r line; do
        count=$((count + 1))
        case $count in
          1) first_line=$line ;;
          2) second_line=$line ;;
        esac
      done <"$failure_log"
    fi
    if [ "$count" -ne 2 ] || [ "$first_line" != 'first' ] || [ "$second_line" != 'fail' ]; then
      log_snapshot=$(ghr_read_or_empty "$failure_log")
      TEST_FAILURE_DIAG=$(printf 'unexpected log contents:\n%s' "$log_snapshot")
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    err_contents=$(ghr_read_or_empty "$commit_err")
    case "$err_contents" in
      *'part failed'* ) ;;
      * )
        TEST_FAILURE_DIAG='runner error output missing failure marker'
        rc=1
        ;;
    esac
  fi

  if [ "$rc" -eq 0 ]; then
    head_subject=$(ghr_git "$parsed_repo" "$parsed_home" log -1 --pretty=%s)
    if [ "$head_subject" != 'feat: seed repository' ]; then
      TEST_FAILURE_DIAG='HEAD advanced despite failing hook'
      rc=1
    fi
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

test_prepare_commit_msg_mutation() {
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

  if [ "$rc" -eq 0 ] && ! ghr_install_runner "$parsed_repo" "$parsed_home" "$INSTALLER" 'prepare-commit-msg'; then
    TEST_FAILURE_DIAG='runner install failed'
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_write_part "$parsed_repo" prepare-commit-msg 10 annotate <<'PART'
msg_file="$1"
printf '\n[prepared-by-hook]\n' >>"$msg_file"
PART
    then
      TEST_FAILURE_DIAG='failed to write prepare-commit-msg part'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ] && ! ghr_make_commit "$parsed_repo" "$parsed_home" 'prepare.txt' 'data' 'chore: trigger prepare'; then
    TEST_FAILURE_DIAG='commit failed during prepare test'
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    msg=$(ghr_git "$parsed_repo" "$parsed_home" log -1 --pretty=%B)
    case "$msg" in
      *'[prepared-by-hook]'* ) ;;
      * )
        TEST_FAILURE_DIAG='commit message missing hook annotation'
        rc=1
        ;;
    esac
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

test_post_merge_runs_after_merge_commit() {
  TEST_FAILURE_DIAG=''
  tuple=$(ghr_mk_sandbox) || {
    TEST_FAILURE_DIAG='failed to create sandbox'
    return 1
  }
  parse_tuple "$tuple"
  trap 'ghr_cleanup_sandbox "$parsed_base"' EXIT
  rc=0
  merge_log="$parsed_repo/merge.log"
  base_branch=''

  if [ "$rc" -eq 0 ] && ! ghr_init_repo "$parsed_repo" "$parsed_home"; then
    TEST_FAILURE_DIAG='git init failed'
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    base_branch=$(ghr_git "$parsed_repo" "$parsed_home" symbolic-ref --short HEAD 2>/dev/null || printf '')
  fi

  if [ "$rc" -eq 0 ] && ! ghr_install_runner "$parsed_repo" "$parsed_home" "$INSTALLER" 'post-merge'; then
    TEST_FAILURE_DIAG='runner install failed'
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_write_part "$parsed_repo" post-merge 10 logmerge <<'PART'
log_file="${GITHOOKS_REPO_ROOT}/merge.log"
printf '%s %s\n' "$(git rev-parse --short HEAD)" "$GITHOOKS_HOOK_NAME" >>"${log_file}"
PART
    then
      TEST_FAILURE_DIAG='failed to write post-merge part'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ] && ! ghr_git "$parsed_repo" "$parsed_home" checkout -b feature >/dev/null 2>&1; then
    TEST_FAILURE_DIAG='failed to create feature branch'
    rc=1
  fi

  if [ "$rc" -eq 0 ] && ! ghr_make_commit "$parsed_repo" "$parsed_home" 'feature.txt' 'feature' 'feat: feature change'; then
    TEST_FAILURE_DIAG='failed to create feature commit'
    rc=1
  fi

  if [ "$rc" -eq 0 ] && ! ghr_git "$parsed_repo" "$parsed_home" checkout "$base_branch" >/dev/null 2>&1; then
    TEST_FAILURE_DIAG='failed to checkout base branch'
    rc=1
  fi

  if [ "$rc" -eq 0 ] && ! ghr_make_commit "$parsed_repo" "$parsed_home" 'base.txt' 'base' 'feat: base change'; then
    TEST_FAILURE_DIAG='failed to create base commit'
    rc=1
  fi

  if [ "$rc" -eq 0 ] && ! ghr_git "$parsed_repo" "$parsed_home" merge --no-ff feature -q -m 'merge feature'; then
    TEST_FAILURE_DIAG='git merge failed'
    rc=1
  fi

  if [ "$rc" -eq 0 ] && [ ! -s "$merge_log" ]; then
    TEST_FAILURE_DIAG='post-merge log not written'
    rc=1
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

test_post_checkout_records_branch_switch() {
  TEST_FAILURE_DIAG=''
  tuple=$(ghr_mk_sandbox) || {
    TEST_FAILURE_DIAG='failed to create sandbox'
    return 1
  }
  parse_tuple "$tuple"
  trap 'ghr_cleanup_sandbox "$parsed_base"' EXIT
  rc=0
  base_branch=''
  checkout_log="$parsed_repo/checkout.log"

  if [ "$rc" -eq 0 ] && ! ghr_init_repo "$parsed_repo" "$parsed_home"; then
    TEST_FAILURE_DIAG='git init failed'
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    base_branch=$(ghr_git "$parsed_repo" "$parsed_home" symbolic-ref --short HEAD 2>/dev/null || printf '')
  fi

  if [ "$rc" -eq 0 ] && ! ghr_install_runner "$parsed_repo" "$parsed_home" "$INSTALLER" 'post-checkout'; then
    TEST_FAILURE_DIAG='runner install failed'
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_write_part "$parsed_repo" post-checkout 10 record <<'PART'
log_file="${GITHOOKS_REPO_ROOT}/checkout.log"
printf '%s %s %s\n' "$1" "$2" "$3" >>"${log_file}"
PART
    then
      TEST_FAILURE_DIAG='failed to write post-checkout part'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ] && ! ghr_git "$parsed_repo" "$parsed_home" checkout -b feature >/dev/null 2>&1; then
    TEST_FAILURE_DIAG='failed to create feature branch'
    rc=1
  fi

  if [ "$rc" -eq 0 ] && ! ghr_make_commit "$parsed_repo" "$parsed_home" 'checkout.txt' 'branch' 'feat: branch work'; then
    TEST_FAILURE_DIAG='failed to create branch commit'
    rc=1
  fi

  if [ "$rc" -eq 0 ] && ! ghr_git "$parsed_repo" "$parsed_home" checkout "$base_branch" >/dev/null 2>&1; then
    TEST_FAILURE_DIAG='failed to checkout base branch'
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    entry_count=0
    last_entry=''
    if [ -f "$checkout_log" ]; then
      while IFS= read -r entry; do
        entry_count=$((entry_count + 1))
        last_entry=$entry
      done <"$checkout_log"
    fi
    if [ "$entry_count" -eq 0 ]; then
      TEST_FAILURE_DIAG='post-checkout hook did not record switch'
      rc=1
    else
      set -- $last_entry
      if [ "$#" -lt 3 ]; then
        TEST_FAILURE_DIAG="unexpected checkout log format: $last_entry"
        rc=1
      elif [ "$3" != '1' ]; then
        TEST_FAILURE_DIAG="expected branch checkout flag 1, got $3"
        rc=1
      fi
    fi
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

test_post_rewrite_logs_commit_pairs() {
  TEST_FAILURE_DIAG=''
  tuple=$(ghr_mk_sandbox) || {
    TEST_FAILURE_DIAG='failed to create sandbox'
    return 1
  }
  parse_tuple "$tuple"
  trap 'ghr_cleanup_sandbox "$parsed_base"' EXIT
  rc=0
  rewrite_log="$parsed_repo/rewrite.log"

  if [ "$rc" -eq 0 ] && ! ghr_init_repo "$parsed_repo" "$parsed_home"; then
    TEST_FAILURE_DIAG='git init failed'
    rc=1
  fi

  if [ "$rc" -eq 0 ] && ! ghr_install_runner "$parsed_repo" "$parsed_home" "$INSTALLER" 'post-rewrite'; then
    TEST_FAILURE_DIAG='runner install failed'
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_write_part "$parsed_repo" post-rewrite 10 capture <<'PART'
log_file="${GITHOOKS_REPO_ROOT}/rewrite.log"
cat >"${log_file}"
PART
    then
      TEST_FAILURE_DIAG='failed to write post-rewrite part'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ] && ! ghr_make_commit "$parsed_repo" "$parsed_home" 'rewrite.txt' 'rewrite' 'feat: rewrite base'; then
    TEST_FAILURE_DIAG='failed to create rewrite commit'
    rc=1
  fi

  if [ "$rc" -eq 0 ] && ! ghr_in_repo "$parsed_repo" "$parsed_home" git commit --amend --no-edit >/dev/null 2>&1; then
    TEST_FAILURE_DIAG='amend commit failed'
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    first_line=''
    if [ -f "$rewrite_log" ]; then
      IFS= read -r first_line <"$rewrite_log"
    fi
    if [ "$first_line" = '' ]; then
      TEST_FAILURE_DIAG='post-rewrite log empty'
      rc=1
    else
      set -- $first_line
      if [ "$#" -lt 2 ]; then
        TEST_FAILURE_DIAG="unexpected post-rewrite payload: $first_line"
        rc=1
      else
        new_head=$(ghr_git "$parsed_repo" "$parsed_home" rev-parse HEAD)
        if [ "$2" != "$new_head" ]; then
          TEST_FAILURE_DIAG='new commit hash mismatch in rewrite log'
          rc=1
        fi
      fi
    fi
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

test_pre_push_records_ref_updates() {
  TEST_FAILURE_DIAG=''
  tuple=$(ghr_mk_sandbox) || {
    TEST_FAILURE_DIAG='failed to create sandbox'
    return 1
  }
  parse_tuple "$tuple"
  trap 'ghr_cleanup_sandbox "$parsed_base"' EXIT
  rc=0
  branch=''
  push_log="$parsed_repo/push.log"

  if [ "$rc" -eq 0 ] && ! ghr_init_repo "$parsed_repo" "$parsed_home"; then
    TEST_FAILURE_DIAG='git init failed'
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    branch=$(ghr_git "$parsed_repo" "$parsed_home" symbolic-ref --short HEAD 2>/dev/null || printf '')
  fi

  if [ "$rc" -eq 0 ] && ! ghr_install_runner "$parsed_repo" "$parsed_home" "$INSTALLER" 'pre-push'; then
    TEST_FAILURE_DIAG='runner install failed'
    rc=1
  fi

  if [ "$rc" -eq 0 ] && ! ghr_init_bare_remote "$parsed_remote"; then
    TEST_FAILURE_DIAG='failed to initialise bare remote'
    rc=1
  fi

  if [ "$rc" -eq 0 ] && ! ghr_git "$parsed_repo" "$parsed_home" remote add origin "$parsed_remote"; then
    TEST_FAILURE_DIAG='failed to add remote'
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_write_part "$parsed_repo" pre-push 10 capture <<'PART'
log_file="${GITHOOKS_REPO_ROOT}/push.log"
cat >"${log_file}"
PART
    then
      TEST_FAILURE_DIAG='failed to write pre-push part'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ] && ! ghr_make_commit "$parsed_repo" "$parsed_home" 'push.txt' 'push' 'feat: push data'; then
    TEST_FAILURE_DIAG='failed to create push commit'
    rc=1
  fi

  if [ "$rc" -eq 0 ] && ! ghr_git "$parsed_repo" "$parsed_home" push origin "HEAD:${branch}" >/dev/null 2>&1; then
    TEST_FAILURE_DIAG='git push failed'
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    log_line=''
    if [ -f "$push_log" ]; then
      IFS= read -r log_line <"$push_log"
    fi
    if [ "$log_line" = '' ]; then
      TEST_FAILURE_DIAG='pre-push log empty'
      rc=1
    else
      set -- $log_line
      if [ "$#" -lt 4 ]; then
        TEST_FAILURE_DIAG="unexpected pre-push payload: $log_line"
        rc=1
      else
        local_ref=$1
        local_sha=$2
        remote_ref=$3
        remote_sha=$4
        expected_branch="refs/heads/$branch"
        case "$local_ref" in
          HEAD | "refs/heads/$branch" ) ;;
          * )
            TEST_FAILURE_DIAG="unexpected local ref: $local_ref"
            rc=1
            ;;
        esac
        if [ "$rc" -eq 0 ]; then
          expected_sha=$(ghr_git "$parsed_repo" "$parsed_home" rev-parse HEAD)
          if [ "$local_sha" != "$expected_sha" ]; then
            TEST_FAILURE_DIAG="local sha mismatch: $local_sha"
            rc=1
          fi
        fi
        if [ "$rc" -eq 0 ] && [ "$remote_ref" != "$expected_branch" ]; then
          TEST_FAILURE_DIAG="expected remote ref $expected_branch, got $remote_ref"
          rc=1
        fi
        if [ "$rc" -eq 0 ]; then
          case "$remote_sha" in
            0000000000000000000000000000000000000000 | "$expected_sha" ) ;;
            * )
              TEST_FAILURE_DIAG="unexpected remote sha: $remote_sha"
              rc=1
              ;;
          esac
        fi
      fi
    fi
  fi

  cleanup_and_return "$parsed_base" "$rc"
}

TOTAL_TESTS=7

tap_plan "$TOTAL_TESTS"

run_test 'pre-commit executes parts lexically' test_pre_commit_executes_in_lexical_order
run_test 'pre-commit failure halts execution and surfaces diagnostics' test_pre_commit_failure_stops_sequence
run_test 'prepare-commit-msg annotates commit messages' test_prepare_commit_msg_mutation
run_test 'post-merge fires on merge commits' test_post_merge_runs_after_merge_commit
run_test 'post-checkout captures branch transitions' test_post_checkout_records_branch_switch
run_test 'post-rewrite captures rewritten commit pairs' test_post_rewrite_logs_commit_pairs
run_test 'pre-push logs ref updates and remote info' test_pre_push_records_ref_updates

diag "Pass=${PASS} Fail=${FAIL} Total=$((PASS+FAIL))"
if [ "$FAIL" -eq 0 ]; then
  exit 0
fi
exit 1
