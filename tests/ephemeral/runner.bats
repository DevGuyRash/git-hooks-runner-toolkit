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

@test 'default overlay records ephemeral-first precedence' {
  run git_repo_exec "${INSTALLER_BIN}" install --mode ephemeral --hooks pre-commit
  assert_success

  assert_manifest_value_equals PRECEDENCE_MODE 'ephemeral-first'
  roots_value=$(git_repo_manifest_value ROOTS || true)
  if [ -z "${roots_value}" ]; then
    bats_die 'expected manifest to record overlay roots'
  fi

  after_ephemeral=${roots_value#*/.git/.githooks/parts}
  if [ "${after_ephemeral}" = "${roots_value}" ]; then
    bats_die "expected roots to include /.git/.githooks/parts, got ${roots_value}"
  fi
  case ${after_ephemeral} in
    */.githooks*)
      :
      ;;
    *)
      bats_die "expected /.githooks to appear after /.git/.githooks/parts in ${roots_value}"
      ;;
  esac
}

@test 'versioned-first overlay inverts precedence' {
  run git_repo_exec "${INSTALLER_BIN}" install --mode ephemeral --hooks pre-commit --overlay versioned-first
  assert_success

  assert_manifest_value_equals PRECEDENCE_MODE 'versioned-first'
  roots_value=$(git_repo_manifest_value ROOTS || true)
  if [ -z "${roots_value}" ]; then
    bats_die 'expected manifest to record overlay roots'
  fi

  after_versioned=${roots_value#*/.githooks}
  if [ "${after_versioned}" = "${roots_value}" ]; then
    bats_die "expected roots to include /.githooks, got ${roots_value}"
  fi
  case ${after_versioned} in
    */.git/.githooks/parts*)
      :
      ;;
    *)
      bats_die "expected /.git/.githooks/parts to appear after /.githooks in ${roots_value}"
      ;;
  esac
}

