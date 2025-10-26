#!/bin/sh
# Orchestrate the audit matrix, Bats suites, and findings report.

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)
PROJECT_ROOT=$(CDPATH='' cd "${SCRIPT_DIR}/../.." && pwd -P)

MATRIX_SCRIPT="${SCRIPT_DIR}/cli_matrix.sh"
HELP_SUITE="${SCRIPT_DIR}/cli_help.bats"
LIFECYCLE_SUITE="${SCRIPT_DIR}/lifecycle.bats"
REPORT_SCRIPT="${SCRIPT_DIR}/report.sh"

DEFAULT_OUTPUT_DIR="${SCRIPT_DIR}/output"
DEFAULT_MATRIX="${DEFAULT_OUTPUT_DIR}/cli-matrix.ndjson"
DEFAULT_JSON="${DEFAULT_OUTPUT_DIR}/audit-findings.json"
DEFAULT_TEXT="${DEFAULT_OUTPUT_DIR}/audit-findings.txt"

BATS_BIN=${BATS_BIN:-bats}
ALLOW_KNOWN=0
MATRIX_PATH="${DEFAULT_MATRIX}"
JSON_PATH="${DEFAULT_JSON}"
TEXT_PATH="${DEFAULT_TEXT}"
RUN_HELP=1
RUN_LIFECYCLE=1

usage() {
  cat <<'USAGE'
usage: tests/audit/run.sh [options]

Run the full audit pipeline (matrix → help suite → lifecycle suite → report).

Options:
  --matrix <path>       Override matrix artifact path (default: tests/audit/output/cli-matrix.ndjson)
  --json <path>         Override JSON findings path (default: tests/audit/output/audit-findings.json)
  --text <path>         Override text findings path (default: tests/audit/output/audit-findings.txt)
  --bats <path>         Explicit bats executable (default: bats on PATH)
  --skip-help           Skip cli_help.bats
  --skip-lifecycle      Skip lifecycle.bats
  --allow-known         Do not fail even when findings contain fail/missing entries
  -h, --help            Show this help message
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --matrix)
      [ "$#" -ge 2 ] || { printf '%s\n' 'run.sh: --matrix requires a value' >&2; exit 1; }
      MATRIX_PATH=$2
      shift 2
      ;;
    --json)
      [ "$#" -ge 2 ] || { printf '%s\n' 'run.sh: --json requires a value' >&2; exit 1; }
      JSON_PATH=$2
      shift 2
      ;;
    --text)
      [ "$#" -ge 2 ] || { printf '%s\n' 'run.sh: --text requires a value' >&2; exit 1; }
      TEXT_PATH=$2
      shift 2
      ;;
    --bats)
      [ "$#" -ge 2 ] || { printf '%s\n' 'run.sh: --bats requires a value' >&2; exit 1; }
      BATS_BIN=$2
      shift 2
      ;;
    --skip-help)
      RUN_HELP=0
      shift
      ;;
    --skip-lifecycle)
      RUN_LIFECYCLE=0
      shift
      ;;
    --allow-known)
      ALLOW_KNOWN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
done

log_step() {
  printf '==> %s\n' "$1"
}

ensure_executable() {
  if [ ! -x "$1" ]; then
    printf '%s\n' "run.sh: missing executable script at $1" >&2
    exit 127
  fi
}

ensure_executable "${MATRIX_SCRIPT}"
ensure_executable "${REPORT_SCRIPT}"

if [ "${RUN_HELP}" -eq 1 ]; then
  if [ ! -f "${HELP_SUITE}" ]; then
    printf '%s\n' "run.sh: missing help test suite at ${HELP_SUITE}" >&2
    exit 127
  fi
fi

if [ "${RUN_LIFECYCLE}" -eq 1 ]; then
  if [ ! -f "${LIFECYCLE_SUITE}" ]; then
    printf '%s\n' "run.sh: missing lifecycle test suite at ${LIFECYCLE_SUITE}" >&2
    exit 127
  fi
fi

if ! command -v "${BATS_BIN}" >/dev/null 2>&1; then
  printf '%s\n' "run.sh: bats executable '${BATS_BIN}' not found" >&2
  exit 127
fi

matrix_dir=$(dirname "${MATRIX_PATH}")
json_dir=$(dirname "${JSON_PATH}")
text_dir=$(dirname "${TEXT_PATH}")

[ -d "${matrix_dir}" ] || mkdir -p "${matrix_dir}" || {
  printf '%s\n' "run.sh: unable to create matrix directory ${matrix_dir}" >&2
  exit 1
}

[ -d "${json_dir}" ] || mkdir -p "${json_dir}" || {
  printf '%s\n' "run.sh: unable to create JSON directory ${json_dir}" >&2
  exit 1
}

[ -d "${text_dir}" ] || mkdir -p "${text_dir}" || {
  printf '%s\n' "run.sh: unable to create text directory ${text_dir}" >&2
  exit 1
}

log_step "Generating CLI matrix"
if ! MATRIX_OUTPUT="${MATRIX_PATH}" "${MATRIX_SCRIPT}"; then
  printf '%s\n' 'run.sh: cli_matrix.sh failed' >&2
  exit 1
fi

if [ "${RUN_HELP}" -eq 1 ]; then
  log_step "Running cli_help.bats"
  if ! "${BATS_BIN}" "${HELP_SUITE}"; then
    printf '%s\n' 'run.sh: cli_help.bats failed' >&2
    exit 1
  fi
fi

if [ "${RUN_LIFECYCLE}" -eq 1 ]; then
  log_step "Running lifecycle.bats"
  if ! "${BATS_BIN}" "${LIFECYCLE_SUITE}"; then
    printf '%s\n' 'run.sh: lifecycle.bats failed' >&2
    exit 1
  fi
fi

log_step "Building audit findings report"
if ! "${REPORT_SCRIPT}" --matrix "${MATRIX_PATH}" --json "${JSON_PATH}" --text "${TEXT_PATH}"; then
  printf '%s\n' 'run.sh: report.sh failed' >&2
  exit 1
fi

if [ ! -f "${JSON_PATH}" ]; then
  printf '%s\n' "run.sh: expected findings JSON missing at ${JSON_PATH}" >&2
  exit 1
fi

FAIL_TYPES='log-truncation coverage-gap alias-divergence'
MISSING_TYPES='flag-gap missing-test'

export FINDINGS_JSON="${JSON_PATH}"
export FAIL_TYPES
export MISSING_TYPES
export ALLOW_KNOWN

log_step "Evaluating audit findings"
python3 <<'PY'
import json
import os
import sys

path = os.environ['FINDINGS_JSON']
fail_types = set(filter(None, os.environ.get('FAIL_TYPES', '').split()))
missing_types = set(filter(None, os.environ.get('MISSING_TYPES', '').split()))
allow_known = os.environ.get('ALLOW_KNOWN', '0') == '1'

try:
    with open(path, encoding='utf-8') as handle:
        data = json.load(handle) or []
except FileNotFoundError:
    sys.stderr.write(f"run.sh: findings file missing at {path}\n")
    sys.exit(1)
except json.JSONDecodeError as err:
    sys.stderr.write(f"run.sh: unable to parse findings JSON: {err}\n")
    sys.exit(1)

if not isinstance(data, list):
    sys.stderr.write('run.sh: findings JSON must be a list\n')
    sys.exit(1)

fails = [entry for entry in data if entry.get('issue_type') in fail_types]
missing = [entry for entry in data if entry.get('issue_type') in missing_types]

def emit(title, entries):
    if not entries:
        return
    print(f"{title} ({len(entries)}):")
    for entry in entries:
        case_id = entry.get('case_id', '<unknown>')
        details = entry.get('details', '').strip()
        if details:
            print(f"  - {case_id}: {details}")
        else:
            print(f"  - {case_id}")
    print()

emit('Audit failures', fails)
emit('Missing coverage', missing)

if not fails and not missing:
    print('No audit failures detected.')

if allow_known or (not fails and not missing):
    sys.exit(0)

sys.exit(2)
PY
status=$?

if [ "${status}" -ne 0 ]; then
  printf '%s\n' "run.sh: audit findings present (see ${TEXT_PATH})" >&2
  exit "${status}"
fi

printf '%s\n' "Audit pipeline completed successfully. Findings written to ${JSON_PATH} and ${TEXT_PATH}."
