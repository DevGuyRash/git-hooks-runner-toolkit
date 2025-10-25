#!/usr/bin/env bats

load '../helpers/assertions.sh'
load '../audit/lib/lifecycle_matrix.sh'

setup_file() {
  local base_tmp
  base_tmp="${BATS_FILE_TMPDIR:-${TMPDIR:-/tmp}}"
  AUDIT_MATRIX_TMPDIR=$(mktemp -d "${base_tmp%/}/audit-matrix.XXXXXX") || bats_die 'unable to create audit matrix temp directory'
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

@test 'ephemeral installs adopt managed hooks path' {
  assert_hooks_path_restored install-ephemeral '.git/.githooks'
  assert_hooks_path_restored install-ephemeral-hooks '.git/.githooks'
  assert_hooks_path_restored install-ephemeral-overlay-versioned '.git/.githooks'
  assert_hooks_path_restored install-ephemeral-overlay-merge '.git/.githooks'
}

@test 'ephemeral uninstall permutations respect hooks path lineage' {
  assert_hooks_path_restored uninstall-ephemeral '<unset>'
  assert_hooks_path_restored uninstall-ephemeral-dry-run '.git/.githooks'
}

@test 'ephemeral overlay precedence remains stable across permutations' {
  assert_overlay_precedence install-ephemeral 'ephemeral-first'
  assert_overlay_precedence install-ephemeral-hooks 'ephemeral-first'
  assert_overlay_precedence install-ephemeral-overlay-versioned 'versioned-first'
  assert_overlay_precedence install-ephemeral-overlay-merge 'merge'
  assert_overlay_precedence uninstall-ephemeral-dry-run 'ephemeral-first'
}
