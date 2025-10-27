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

example_git_crypt_enforce_run() {
  mode=$1
  TEST_FAILURE_DIAG=''
  tuple=$(ghr_mk_sandbox) || {
    TEST_FAILURE_DIAG='failed to create sandbox'
    return 1
  }
  old_ifs=$IFS
  IFS='|'
  set -- ${tuple}
  IFS=$old_ifs
  base=$1
  repo=$2
  remote=$3
  home=$4

  example_cleanup_git_crypt() {
    ghr_cleanup_sandbox "$base"
  }
  trap example_cleanup_git_crypt EXIT

  rc=0

  parts_dir=''

  if [ "$rc" -eq 0 ]; then
    if ! ghr_init_repo "$repo" "$home"; then
      TEST_FAILURE_DIAG='git init failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    printf 'secrets.env filter=git-crypt diff=git-crypt -text\n' >"$repo/.gitattributes"
    ghr_git "$repo" "$home" add .gitattributes
    ghr_git "$repo" "$home" commit -q -m 'chore: configure git-crypt attributes'
  fi

  if [ "$rc" -eq 0 ]; then
    if [ "$mode" = 'ephemeral' ]; then
      if ! ghr_in_repo "$repo" "$home" "$INSTALLER" install --mode ephemeral --hooks pre-commit; then
        TEST_FAILURE_DIAG='ephemeral install failed'
        rc=1
      else
        parts_dir="$repo/.git/.githooks/parts/pre-commit.d"
      fi
    else
      if ! ghr_install_runner "$repo" "$home" "$INSTALLER" 'pre-commit'; then
        TEST_FAILURE_DIAG='runner install failed'
        rc=1
      else
        parts_dir="$repo/.githooks/pre-commit.d"
      fi
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_in_repo "$repo" "$home" "$INSTALLER" stage add examples --hook pre-commit --name git-crypt-enforce; then
      TEST_FAILURE_DIAG='stage add failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if [ ! -d "$parts_dir" ]; then
      TEST_FAILURE_DIAG='git-crypt parts directory missing after staging'
      rc=1
    else
      part_path=$(find "$parts_dir" -maxdepth 1 -type f -name '*git-crypt-enforce*.sh' | head -n 1)
      if [ -z "$part_path" ]; then
        TEST_FAILURE_DIAG='git-crypt part not staged'
        rc=1
      fi
    fi
  fi

  out="$repo/commit.out"
  err="$repo/commit.err"

  if [ "$rc" -eq 0 ]; then
    printf 'plain secret\n' >"$repo/secrets.env"
    ghr_git "$repo" "$home" add secrets.env
    commit_status=0
    ghr_in_repo "$repo" "$home" git commit -m 'feat: add secret' >"$out" 2>"$err" || commit_status=$?
    if [ "$commit_status" -eq 0 ]; then
      TEST_FAILURE_DIAG='commit unexpectedly succeeded without git-crypt'
      rc=1
    else
      err_output=$(ghr_read_or_empty "$err")
      case "$err_output" in
        *'refusing plaintext for protected paths'*) : ;;
        *) TEST_FAILURE_DIAG='error output missing plaintext refusal diagnostic'; rc=1 ;;
      esac
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    mkdir -p "$repo/bin"
    cat <<'SH' >"$repo/bin/git-crypt"
#!/bin/sh
if [ "$1" = 'status' ] && [ "$2" = '-f' ]; then
  exit 0
fi
exit 0
SH
    chmod 755 "$repo/bin/git-crypt"
    printf '\000GITCRYPT\000payload\n' >"$repo/secrets.env"
    ghr_git "$repo" "$home" add secrets.env
    if ! ghr_in_repo "$repo" "$home" PATH="$repo/bin:$PATH" git commit -m 'feat: add encrypted secret'; then
      TEST_FAILURE_DIAG='commit failed despite encrypted payload'
      rc=1
    else
      log_subject=$(ghr_git "$repo" "$home" log -1 --pretty=%s)
      if [ "$log_subject" != 'feat: add encrypted secret' ]; then
        TEST_FAILURE_DIAG='latest commit subject mismatch'
        rc=1
      fi
    fi
  fi

  trap - EXIT
  ghr_cleanup_sandbox "$base"
  return "$rc"
}

example_test_git_crypt_enforce_standard() {
  example_git_crypt_enforce_run 'standard'
}

example_test_git_crypt_enforce_ephemeral() {
  example_git_crypt_enforce_run 'ephemeral'
}

example_register 'git-crypt enforcement blocks plaintext and allows encrypted blobs' example_test_git_crypt_enforce_standard
example_register 'git-crypt enforcement succeeds in ephemeral mode' example_test_git_crypt_enforce_ephemeral

if [ "${EXAMPLE_TEST_RUN_MODE:-standalone}" = "standalone" ]; then
  if example_run_self; then
    exit 0
  fi
  exit 1
fi
