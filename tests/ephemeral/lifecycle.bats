#!/usr/bin/env bats

load '../helpers/git_repo.sh'
load '../helpers/assertions.sh'
load '../audit/lib/lifecycle_matrix.sh'

setup_file() {
  local base_tmp
  base_tmp="${BATS_FILE_TMPDIR:-${TMPDIR:-/tmp}}"
  AUDIT_MATRIX_TMPDIR=$(mktemp -d "${base_tmp%/}/ephemeral-matrix.XXXXXX") || bats_die 'unable to create lifecycle audit matrix temp directory'
  AUDIT_MATRIX_FILE="${AUDIT_MATRIX_TMPDIR}/cli-matrix.ndjson"
  export AUDIT_MATRIX_FILE
  lifecycle_matrix_use "${AUDIT_MATRIX_FILE}"
}

teardown_file() {
  if [ -n "${AUDIT_MATRIX_TMPDIR:-}" ] && [ -d "${AUDIT_MATRIX_TMPDIR}" ]; then
    rm -rf "${AUDIT_MATRIX_TMPDIR}"
  fi
  unset AUDIT_MATRIX_TMPDIR AUDIT_MATRIX_FILE
}

setup() {
  if ! git_repo_setup; then
    skip 'sandbox setup unavailable'
  fi
  if ! git_repo_init; then
    git_repo_teardown
    bats_die 'failed to initialise repository'
  fi
  INSTALLER_BIN=$(git_repo_installer_path)
}

teardown() {
  git_repo_teardown
}

@test 'ephemeral install is idempotent' {
  run git_repo_exec "${INSTALLER_BIN}" install --mode ephemeral --hooks pre-commit
  assert_success

  stub_path="${GIT_REPO_WORK}/.git/.githooks/pre-commit"
  manifest_path="${GIT_REPO_WORK}/.git/.githooks/manifest.sh"
  assert_file_exists "${stub_path}"
  assert_file_exists "${manifest_path}"

  run git_repo_exec "${INSTALLER_BIN}" install --mode ephemeral --hooks pre-commit
  assert_success

  hooks_path=$(git_repo_git config --local --get core.hooksPath)
  if [ "${hooks_path}" != '.git/.githooks' ]; then
    bats_die "expected core.hooksPath to remain .git/.githooks, got ${hooks_path}"
  fi

  assert_manifest_value_equals MANAGED_HOOKS 'pre-commit'
  previous=$(git_repo_manifest_value PREVIOUS_CORE_HOOKS_PATH || true)
  if [ "${previous}" != '.git/.githooks' ]; then
    bats_die "expected previous hooks path to remain .git/.githooks, got ${previous}"
  fi

  assert_hooks_path_restored install-ephemeral '.git/.githooks'
  assert_overlay_precedence install-ephemeral 'ephemeral-first'
}

@test 'ephemeral assets persist across git reset --hard' {
  run git_repo_exec "${INSTALLER_BIN}" install --mode ephemeral --hooks pre-commit
  assert_success

  hooks_path=$(git_repo_git config --local --get core.hooksPath)
  if [ "${hooks_path}" != '.git/.githooks' ]; then
    bats_die "expected hooks path to be .git/.githooks after install, got ${hooks_path}"
  fi

  printf 'payload\n' > "${GIT_REPO_WORK}/payload.txt"
  run git_repo_git add payload.txt
  assert_success
  run git_repo_git commit -m 'feat: add payload before reset'
  assert_success

  run git_repo_git reset --hard HEAD~1
  assert_success

  assert_file_exists "${GIT_REPO_WORK}/.git/.githooks/pre-commit"
  assert_file_exists "${GIT_REPO_WORK}/.git/.githooks/manifest.sh"
  assert_file_exists "${GIT_REPO_WORK}/.git/.githooks/_runner.sh"

  hooks_after_reset=$(git_repo_git config --local --get core.hooksPath)
  if [ "${hooks_after_reset}" != '.git/.githooks' ]; then
    bats_die "expected hooks path to persist, got ${hooks_after_reset}"
  fi

  managed_after_reset=$(git_repo_manifest_value MANAGED_HOOKS || true)
  if [ "${managed_after_reset}" != 'pre-commit' ]; then
    bats_die "expected managed hooks to persist, got ${managed_after_reset:-<unset>}"
  fi

  assert_hooks_path_restored install-ephemeral '.git/.githooks'
  assert_overlay_precedence install-ephemeral 'ephemeral-first'
}

@test 'uninstall restores prior hooksPath and cleans ephemeral root' {
  git_repo_git config --local core.hooksPath '.git/custom-hooks'

  run git_repo_exec "${INSTALLER_BIN}" install --mode ephemeral --hooks pre-commit
  assert_success

  assert_manifest_value_equals PREVIOUS_CORE_HOOKS_PATH '.git/custom-hooks'
  hooks_path=$(git_repo_git config --local --get core.hooksPath)
  if [ "${hooks_path}" != '.git/.githooks' ]; then
    bats_die "expected hooks path to switch to .git/.githooks, got ${hooks_path}"
  fi

  run git_repo_exec "${INSTALLER_BIN}" uninstall --mode ephemeral
  assert_success

  restored=$(git_repo_git config --local --get core.hooksPath)
  if [ "${restored}" != '.git/custom-hooks' ]; then
    bats_die "expected hooks path to restore to .git/custom-hooks, got ${restored}"
  fi

  assert_file_not_exists "${GIT_REPO_WORK}/.git/.githooks/_runner.sh"
  assert_file_not_exists "${GIT_REPO_WORK}/.git/.githooks/manifest.sh"
  if [ -d "${GIT_REPO_WORK}/.git/.githooks" ]; then
    bats_die 'expected ephemeral root directory to be removed after uninstall'
  fi

  assert_hooks_path_restored uninstall-ephemeral '<unset>'
}

