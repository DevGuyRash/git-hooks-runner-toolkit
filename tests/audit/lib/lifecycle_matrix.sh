#!/usr/bin/env bash
# Shared helpers for lifecycle matrix assertions built on audit NDJSON output.

set -u

_lifecycle_lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
_lifecycle_project_root=$(cd "${_lifecycle_lib_dir}/../../.." && pwd -P)
PYTHON_BIN=${PYTHON:-python3}
_lifecycle_default_matrix="${_lifecycle_project_root}/tests/audit/output/cli-matrix.ndjson"
_lifecycle_matrix_generator="${_lifecycle_project_root}/tests/audit/cli_matrix.sh"
_lifecycle_overlay_lib="${_lifecycle_project_root}/lib/ephemeral_overlay.sh"

if [ -f "${_lifecycle_overlay_lib}" ]; then
  # shellcheck disable=SC1090
  . "${_lifecycle_overlay_lib}"
fi

lifecycle_matrix_use() {
  local candidate="${1:-}"
  if [ -z "${candidate}" ]; then
    candidate="${AUDIT_MATRIX_FILE:-${_lifecycle_default_matrix}}"
  fi
  if [ ! -f "${candidate}" ]; then
    local parent
    parent=$(dirname "${candidate}")
    if [ ! -d "${parent}" ]; then
      mkdir -p "${parent}" || bats_die "unable to create matrix directory: ${parent}"
    fi
    if [ ! -x "${_lifecycle_matrix_generator}" ]; then
      bats_die "matrix generator missing: ${_lifecycle_matrix_generator}"
    fi
    MATRIX_OUTPUT="${candidate}" "${_lifecycle_matrix_generator}" >/dev/null 2>&1 || {
      rm -f "${candidate}"
      bats_die "failed to compute matrix artifact at ${candidate}"
    }
  fi
  LIFECYCLE_MATRIX_FILE="${candidate}"
}

lifecycle_matrix_require() {
  if [ -z "${LIFECYCLE_MATRIX_FILE:-}" ]; then
    lifecycle_matrix_use
  fi
}

lifecycle_matrix_python() {
  lifecycle_matrix_require
  "${PYTHON_BIN}" - "$LIFECYCLE_MATRIX_FILE" "$@" <<'PY'
import json
import sys

path = sys.argv[1]
args = sys.argv[2:]

with open(path, encoding='utf-8') as handle:
    records = [json.loads(line) for line in handle if line.strip()]

command = args[0]

if command == 'exists':
    case_id = args[1]
    sys.exit(0 if any(rec['id'] == case_id for rec in records) else 1)

if command == 'string':
    case_id, field = args[1:3]
    for rec in records:
        if rec['id'] == case_id:
            value = rec.get(field, '')
            if value is None:
                value = ''
            sys.stdout.write(str(value))
            sys.exit(0)
    sys.exit(1)

if command == 'list':
    case_id, field = args[1:3]
    for rec in records:
        if rec['id'] == case_id:
            value = rec.get(field) or []
            for entry in value:
                text = str(entry).replace('\\n', '\n')
                sys.stdout.write(text + '\n')
            sys.exit(0)
    sys.exit(1)

if command == 'case-ids':
    prefix = args[1]
    for rec in records:
        if rec['id'].startswith(prefix):
            sys.stdout.write(rec['id'] + '\n')
    sys.exit(0)

sys.stderr.write('unknown lifecycle_matrix_python command\n')
sys.exit(2)
PY
}

lifecycle_matrix_case_exists() {
  lifecycle_matrix_python exists "$1"
}

expect_lifecycle_case() {
  local case_id="$1"
  if ! lifecycle_matrix_case_exists "${case_id}"; then
    bats_die "matrix missing case: ${case_id}"
  fi
}

lifecycle_matrix_hooks_path() {
  lifecycle_matrix_python string "$1" hooks_path
}

lifecycle_matrix_exit_code() {
  lifecycle_matrix_python string "$1" exit_code
}

lifecycle_matrix_overlay_roots() {
  lifecycle_matrix_python list "$1" overlay_roots
}

lifecycle_matrix_notes() {
  lifecycle_matrix_python list "$1" notes
}

lifecycle_matrix_precedence_note() {
  local case_id="$1"
  local note
  while IFS= read -r note; do
    [ -n "${note}" ] || continue
    case "${note}" in
      precedence:*)
        printf '%s' "${note#precedence:}"
        return 0
        ;;
    esac
  done <<EOF
$(lifecycle_matrix_notes "${case_id}")
EOF
  return 1
}

lifecycle_matrix_notes_contains() {
  local case_id="$1"
  local needle="$2"
  local note
  while IFS= read -r note; do
    [ -n "${note}" ] || continue
    if [ "${note}" = "${needle}" ]; then
      return 0
    fi
  done <<EOF
$(lifecycle_matrix_notes "${case_id}")
EOF
  return 1
}

assert_hooks_path_restored() {
  if [ "$#" -ne 2 ]; then
    bats_die 'assert_hooks_path_restored requires <case-id> <expected-path>'
  fi
  local case_id="$1"
  local expected="$2"
  expect_lifecycle_case "${case_id}"
  local actual
  actual=$(lifecycle_matrix_hooks_path "${case_id}") || bats_die "${case_id}: unable to read hooks_path"
  if [ "${actual}" != "${expected}" ]; then
    bats_die "${case_id}: expected hooks_path ${expected}, got ${actual:-<empty>}"
  fi
}

assert_overlay_precedence() {
  if [ "$#" -ne 2 ]; then
    bats_die 'assert_overlay_precedence requires <case-id> <expected-mode>'
  fi
  local case_id="$1"
  local expected_mode="$2"
  expect_lifecycle_case "${case_id}"

  local recorded_mode
  recorded_mode=$(lifecycle_matrix_precedence_note "${case_id}" || printf '')
  if [ -z "${recorded_mode}" ]; then
    bats_die "${case_id}: missing precedence note"
  fi
  if [ "${recorded_mode}" != "${expected_mode}" ]; then
    bats_die "${case_id}: expected precedence ${expected_mode}, got ${recorded_mode}"
  fi

  if lifecycle_matrix_notes_contains "${case_id}" 'overlay-truncated'; then
    bats_die "${case_id}: overlay logs flagged as truncated"
  fi

  local overlay_raw
  overlay_raw=$(lifecycle_matrix_overlay_roots "${case_id}" || printf '')
  if [ -z "${overlay_raw}" ]; then
    bats_die "${case_id}: expected overlay roots but none recorded"
  fi

  local overlay_count=0
  local first=''
  local second=''
  while IFS= read -r overlay_entry; do
    [ -n "${overlay_entry}" ] || continue
    local trimmed="${overlay_entry}"
    if command -v ephemeral_overlay_trim >/dev/null 2>&1; then
      trimmed=$(ephemeral_overlay_trim "${trimmed}")
    fi
    if [ -z "${trimmed}" ]; then
      bats_die "${case_id}: overlay root ${overlay_count} empty after trim"
    fi
    case "${trimmed}" in
      /*)
        ;;
      *)
        bats_die "${case_id}: overlay root missing leading slash: ${trimmed}"
        ;;
    esac
    overlay_count=$((overlay_count + 1))
    if [ "${overlay_count}" -eq 1 ]; then
      first="${trimmed}"
    elif [ "${overlay_count}" -eq 2 ]; then
      second="${trimmed}"
    fi
  done <<EOF
${overlay_raw}
EOF

  if [ "${overlay_count}" -lt 2 ]; then
    bats_die "${case_id}: expected at least two overlay roots, got ${overlay_count}"
  fi

  case "${expected_mode}" in
    ephemeral-first|merge)
      case "${first}" in
        */.git/.githooks/parts)
          ;;
        *)
          bats_die "${case_id}: first overlay root unexpected: ${first}"
          ;;
      esac
      case "${second}" in
        */.githooks)
          ;;
        *)
          bats_die "${case_id}: second overlay root unexpected: ${second}"
          ;;
      esac
      ;;
    versioned-first)
      case "${first}" in
        */.githooks)
          ;;
        *)
          bats_die "${case_id}: first overlay root unexpected: ${first}"
          ;;
      esac
      case "${second}" in
        */.git/.githooks/parts)
          ;;
        *)
          bats_die "${case_id}: second overlay root unexpected: ${second}"
          ;;
      esac
      ;;
    *)
      bats_die "${case_id}: unsupported expected precedence ${expected_mode}"
      ;;
  esac
}

assert_notes_include() {
  if [ "$#" -ne 2 ]; then
    bats_die 'assert_notes_include requires <case-id> <needle>'
  fi
  local case_id="$1"
  local needle="$2"
  if ! lifecycle_matrix_notes_contains "${case_id}" "${needle}"; then
    bats_die "${case_id}: expected note ${needle}"
  fi
}
