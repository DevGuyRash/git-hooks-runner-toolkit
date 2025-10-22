#!/bin/sh
# Lightweight assertions for Bats tests.

bats_die() {
  printf '%s\n' "$1" >&2
  return 1
}

assert_success() {
  if [ "${status:-0}" -ne 0 ]; then
    bats_die "expected command to succeed (status 0), got ${status:-} | output: ${output:-<empty>}"
    return 1
  fi
}

assert_failure() {
  if [ "${status:-1}" -eq 0 ]; then
    bats_die 'expected command to fail but it succeeded'
    return 1
  fi
}

assert_output_contains() {
  _needle=$1
  case "${output:-}" in
    *"${_needle}"*)
      ;;
    *)
      bats_die "expected output to contain '${_needle}' | output: ${output:-<empty>}"
      return 1
      ;;
  esac
}

assert_output_not_contains() {
  _needle=$1
  case "${output:-}" in
    *"${_needle}"*)
      bats_die "expected output to omit '${_needle}' | output: ${output:-<empty>}"
      return 1
      ;;
    *)
      ;;
  esac
}

assert_file_exists() {
  if [ ! -e "$1" ]; then
    bats_die "expected path to exist: $1"
    return 1
  fi
}

assert_file_not_exists() {
  if [ -e "$1" ]; then
    bats_die "expected path to be absent: $1"
    return 1
  fi
}

assert_manifest_value_equals() {
  if [ "$#" -ne 2 ]; then
    bats_die 'assert_manifest_value_equals requires <key> <expected>'
    return 1
  fi
  _key=$1
  _expected=$2
  _actual=$(git_repo_manifest_value "${_key}" || true)
  if [ "${_actual}" != "${_expected}" ]; then
    bats_die "expected manifest ${_key}=${_expected}, got ${_actual:-<unset>}"
    return 1
  fi
}

