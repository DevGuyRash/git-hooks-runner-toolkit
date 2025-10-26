#!/usr/bin/env bats

load '../helpers/git_repo.sh'
load '../helpers/assertions.sh'

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

@test 'manifest snapshot exposes recorded metadata' {
  run git_repo_exec "${INSTALLER_BIN}" install --mode ephemeral --hooks pre-commit
  assert_success

  snapshot=$(git_repo_manifest_snapshot || true)
  if [ -z "${snapshot}" ]; then
    bats_die 'expected manifest snapshot output'
  fi

  case "${snapshot}" in
    *'INSTALL_MODE=ephemeral'*)
      ;;
    *)
      bats_die "expected INSTALL_MODE=ephemeral in snapshot | snapshot: ${snapshot}"
      ;;
  esac

  case "${snapshot}" in
    *'MANAGED_HOOKS=pre-commit'*)
      ;;
    *)
      bats_die 'expected managed hooks to record pre-commit'
      ;;
  esac
}

@test 'overlay helpers emit absolute roots and logs' {
  run git_repo_exec "${INSTALLER_BIN}" install --mode ephemeral --overlay merge --hooks pre-commit
  assert_success

  roots=$(git_repo_overlay_roots || true)
  if [ -z "${roots}" ]; then
    bats_die 'expected overlay roots output'
  fi

  roots_issue=0
  roots_nl=$(printf '\n_')
  old_ifs=${IFS}
  IFS=${roots_nl%_}
  set -f
  for entry in ${roots}; do
    [ -n "${entry}" ] || continue
    case "${entry}" in
      /*)
        ;;
      *)
        roots_issue=1
        ;;
    esac
  done
  set +f
  IFS=${old_ifs}
  if [ ${roots_issue} -ne 0 ]; then
    bats_die "expected overlay roots to be absolute | roots: ${roots}"
  fi

  log_output=$(git_repo_overlay_log || true)
  if [ -z "${log_output}" ]; then
    bats_die 'expected overlay log output'
  fi

  case "${log_output}" in
    *'Ephemeral overlay order'* )
      ;;
    *)
      bats_die 'expected overlay log banner'
      ;;
  esac

  case "${log_output}" in
    *'/.git/.githooks/parts'* )
      ;;
    *)
      bats_die 'expected overlay log to include ephemeral parts path'
      ;;
  esac

  case "${log_output}" in
    *'/.githooks'* )
      ;;
    *)
      bats_die 'expected overlay log to include versioned path'
      ;;
  esac
}

@test 'environment snapshot captures sandbox paths' {
  env_snapshot=$(git_repo_environment_snapshot || true)
  if [ -z "${env_snapshot}" ]; then
    bats_die 'expected environment snapshot output'
  fi

  case "${env_snapshot}" in
    *"PWD=${GIT_REPO_WORK}"*)
      ;;
    *)
      bats_die "expected PWD to reference sandbox work tree | env: ${env_snapshot}"
      ;;
  esac

  case "${env_snapshot}" in
    *"GIT_REPO_HOME=${GIT_REPO_HOME}"*)
      ;;
    *)
      bats_die 'expected environment snapshot to include GIT_REPO_HOME'
      ;;
  esac

  case "${env_snapshot}" in
    *'GIT_VERSION='*)
      ;;
    *)
      bats_die 'expected environment snapshot to surface git version metadata'
      ;;
  esac
}
