#!/bin/sh
# Aggregate audit findings from the CLI matrix output.
# Regenerate fixtures with: tests/audit/report.sh

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)
PROJECT_ROOT=$(CDPATH='' cd "${SCRIPT_DIR}/../.." && pwd -P)

HELP_SNAPSHOT="${SCRIPT_DIR}/lib/help_snapshot.sh"

usage() {
  cat <<'USAGE'
usage: report.sh [--matrix <path>] [--json <path>] [--text <path>]

Generate deterministic JSON and text summaries highlighting audit issues.
Defaults:
  --matrix tests/audit/output/cli-matrix.ndjson
  --json   tests/audit/output/audit-findings.json
  --text   tests/audit/output/audit-findings.txt
USAGE
}

MATRIX_FILE="${SCRIPT_DIR}/output/cli-matrix.ndjson"
JSON_OUTPUT="${SCRIPT_DIR}/output/audit-findings.json"
TEXT_OUTPUT="${SCRIPT_DIR}/output/audit-findings.txt"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --matrix)
      [ "$#" -ge 2 ] || { usage >&2; exit 1; }
      MATRIX_FILE=$2
      shift 2
      ;;
    --json)
      [ "$#" -ge 2 ] || { usage >&2; exit 1; }
      JSON_OUTPUT=$2
      shift 2
      ;;
    --text)
      [ "$#" -ge 2 ] || { usage >&2; exit 1; }
      TEXT_OUTPUT=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
done

if [ ! -f "${MATRIX_FILE}" ]; then
  printf '%s\n' "report: matrix file not found at ${MATRIX_FILE}" >&2
  exit 1
fi

if [ ! -f "${HELP_SNAPSHOT}" ]; then
  printf '%s\n' "report: help snapshot helper missing at ${HELP_SNAPSHOT}" >&2
  exit 1
fi

JSON_DIR=$(dirname "${JSON_OUTPUT}")
TEXT_DIR=$(dirname "${TEXT_OUTPUT}")

if [ ! -d "${JSON_DIR}" ]; then
  mkdir -p "${JSON_DIR}" || {
    printf '%s\n' "report: unable to create directory ${JSON_DIR}" >&2
    exit 1
  }
fi

if [ ! -d "${TEXT_DIR}" ]; then
  mkdir -p "${TEXT_DIR}" || {
    printf '%s\n' "report: unable to create directory ${TEXT_DIR}" >&2
    exit 1
  }
fi

ALIAS_MAP='{"alias-init":"install-dry-run","alias-add":"stage-add-hook","alias-remove":"stage-remove-all"}'

tmp_cases=''
tmp_surfaces=''

cleanup() {
  if [ -n "${tmp_cases}" ] && [ -f "${tmp_cases}" ]; then
    rm -f "${tmp_cases}"
  fi
  if [ -n "${tmp_surfaces}" ] && [ -f "${tmp_surfaces}" ]; then
    rm -f "${tmp_surfaces}"
  fi
}

trap cleanup EXIT INT TERM HUP

run_with_jq() {
  tmp_cases=$(mktemp "${TMPDIR:-/tmp}/audit-cases.XXXXXX") || return 1
  tmp_surfaces=$(mktemp "${TMPDIR:-/tmp}/audit-surfaces.XXXXXX") || return 1

  if ! jq -s '.' "${MATRIX_FILE}" >"${tmp_cases}"; then
    return 1
  fi

  if ! sh "${HELP_SNAPSHOT}" list | jq -R -s 'split("\n") | map(select(length>0)) | map(split("|")) | map({id: .[0], fixture: .[1], command: (.[2] // "")})' >"${tmp_surfaces}"; then
    return 1
  fi

  if ! jq -n \
    --slurpfile cases "${tmp_cases}" \
    --slurpfile surfaces "${tmp_surfaces}" \
    --argjson alias_map "${ALIAS_MAP}" \
    'def normalize_list($list):
       if ($list | length) == 1 and ($list[0] | type) == "array" then
         $list[0]
       else
         $list
       end;
     def flatten_list($list):
       reduce $list[]? as $item ([]; . + ($item | gsub("\\\\n"; "\n") | split("\n")))
       | map(select(length>0));
     (normalize_list($cases)) as $cases
     | (normalize_list($surfaces)) as $surfaces
     | def case_args_tokens($case):
       flatten_list($case.args // []);
     def case_notes($case):
       flatten_list($case.notes // []);
     def issue_rank($type):
       if $type == "log-truncation" then 0
       elif $type == "flag-gap" then 1
       elif $type == "coverage-gap" then 2
       elif $type == "alias-divergence" then 3
       else 99 end;
     def case_command_suffix($case):
       (case_args_tokens($case) | if length > 0 then " " + (join(" ")) else "" end);
     def cases_map:
       reduce $cases[] as $case ({}; .[$case.id] = $case);
     def args_map:
       reduce $cases[] as $case ({}; .[(case_args_tokens($case) | join(" "))] = $case.id);
     def has_note($notes; $substr):
       any($notes[]?; contains($substr));
     def log_truncation:
       [ $cases[] |
         (case_notes(.)) as $notes |
         select(has_note($notes; "overlay-truncated")) |
         { issue_type: "log-truncation",
           case_id: .id,
           details: ("Overlay roots truncated for `githooks" + (case_command_suffix(.)) + "`") } ];
     def coverage_gap:
       [ $cases[] |
         (case_notes(.)) as $notes |
         select((.exit_code != 0) or has_note($notes; "setup-failed") or has_note($notes; "execution-skipped")) |
         { issue_type: "coverage-gap",
           case_id: .id,
           details: ("Exit " + (.exit_code|tostring) +
             (if ($notes | length) > 0 then " notes: " + ($notes | join(", ")) else "" end)) } ];
     def alias_divergence:
       [ $alias_map | to_entries[] |
         (cases_map[.key]) as $alias |
         (cases_map[.value]) as $canon |
         select($alias != null and $canon != null) |
         select(($alias.exit_code != $canon.exit_code) or ($alias.stdout_crc != $canon.stdout_crc) or ($alias.stderr_crc != $canon.stderr_crc)) |
         { issue_type: "alias-divergence",
           case_id: $alias.id,
           details: ("Alias `" + $alias.id + "` diverges from `" + $canon.id + "` (exit " +
             ($alias.exit_code|tostring) + "/" + ($canon.exit_code|tostring) +
             ", stdout " + $alias.stdout_crc + "/" + $canon.stdout_crc +
             ", stderr " + $alias.stderr_crc + "/" + $canon.stderr_crc + ")") } ];
     def flag_gap:
       (args_map) as $lookup |
       (reduce $surfaces[] as $surface ({items: [], seen: {}};
         ($surface.command // "") as $cmd |
         (if $cmd == "" then [] else ($cmd | split(" ") | map(select(length>0))) end) as $tokens |
         ($tokens | join(" ")) as $key |
         if ($lookup[$key] // null) != null or (.seen[$key] // false) then .
         else { items: (.items + [{ issue_type: "flag-gap",
                                     case_id: ("surface:" + $surface.id),
                                     details: ("No matrix coverage for `githooks" + (if $cmd == "" then "" else " " + $cmd end) + "` (fixture " + $surface.fixture + ")") }]),
                seen: (.seen + { ($key): true }) }
         end
       )).items;
     (log_truncation + flag_gap + coverage_gap + alias_divergence)
     | sort_by([issue_rank(.issue_type), .case_id])
    ' >"${JSON_OUTPUT}"; then
    return 1
  fi

  if ! jq -r '
      def section($data; $type):
        ($data | map(select(.issue_type == $type))) as $items |
        $type + "\n" +
        (if ($items | length) == 0 then "- none" else ($items | map("- " + .case_id + ": " + .details) | join("\n")) end);
      . as $data |
      ["log-truncation","flag-gap","coverage-gap","alias-divergence"]
      | map(section($data; .))
      | join("\n\n") + "\n"
    ' "${JSON_OUTPUT}" >"${TEXT_OUTPUT}"; then
    return 1
  fi

  return 0
}

run_with_python() {
  MATRIX_INPUT="${MATRIX_FILE}" \
  JSON_OUTPUT_PATH="${JSON_OUTPUT}" \
  TEXT_OUTPUT_PATH="${TEXT_OUTPUT}" \
  HELP_SNAPSHOT_PATH="${HELP_SNAPSHOT}" \
  python3 <<'PY'
import json
import os
import subprocess
import sys
from pathlib import Path

matrix = Path(os.environ['MATRIX_INPUT'])
json_out = Path(os.environ['JSON_OUTPUT_PATH'])
text_out = Path(os.environ['TEXT_OUTPUT_PATH'])
help_snapshot = Path(os.environ['HELP_SNAPSHOT_PATH'])
alias_map = {"alias-init": "install-dry-run", "alias-add": "stage-add-hook", "alias-remove": "stage-remove-all"}

def flatten(items):
    result = []
    if not items:
        return result
    for item in items:
        item = item.replace('\\n', '\n')
        for chunk in item.split('\n'):
            chunk = chunk.strip()
            if chunk:
                result.append(chunk)
    return result

cases = []
with matrix.open() as handle:
    for line in handle:
        line = line.strip()
        if not line:
            continue
        record = json.loads(line)
        record['__tokens'] = flatten(record.get('args'))
        record['__notes'] = flatten(record.get('notes'))
        cases.append(record)

cases_by_id = {case['id']: case for case in cases}
args_map = {" ".join(case['__tokens']): case['id'] for case in cases}

def command_suffix(tokens):
    return (" " + " ".join(tokens)) if tokens else ""

issues = []

for case in cases:
    if any('overlay-truncated' in note for note in case['__notes']):
        issues.append({
            'issue_type': 'log-truncation',
            'case_id': case['id'],
            'details': f"Overlay roots truncated for `githooks{command_suffix(case['__tokens'])}`"
        })

for case in cases:
    notes = case['__notes']
    if case.get('exit_code', 0) != 0 or any('setup-failed' in note or 'execution-skipped' in note for note in notes):
        detail = f"Exit {case.get('exit_code', 0)}"
        if notes:
            detail += " notes: " + ", ".join(notes)
        issues.append({
            'issue_type': 'coverage-gap',
            'case_id': case['id'],
            'details': detail
        })

for alias_id, canonical_id in alias_map.items():
    alias_case = cases_by_id.get(alias_id)
    canonical_case = cases_by_id.get(canonical_id)
    if not alias_case or not canonical_case:
        continue
    if (alias_case.get('exit_code') != canonical_case.get('exit_code') or
            alias_case.get('stdout_crc') != canonical_case.get('stdout_crc') or
            alias_case.get('stderr_crc') != canonical_case.get('stderr_crc')):
        issues.append({
            'issue_type': 'alias-divergence',
            'case_id': alias_case['id'],
            'details': (
                f"Alias `{alias_case['id']}` diverges from `{canonical_case['id']}` "
                f"(exit {alias_case.get('exit_code')} / {canonical_case.get('exit_code')}, "
                f"stdout {alias_case.get('stdout_crc')} / {canonical_case.get('stdout_crc')}, "
                f"stderr {alias_case.get('stderr_crc')} / {canonical_case.get('stderr_crc')})"
            )
        })

try:
    surface_proc = subprocess.run(
        [str(help_snapshot), 'list'],
        check=True,
        capture_output=True,
        text=True,
    )
except subprocess.CalledProcessError as err:
    sys.stderr.write(f"report: failed to list help surfaces: {err}\n")
    sys.exit(1)

seen_keys = set()
for line in surface_proc.stdout.splitlines():
    if not line.strip():
        continue
    parts = line.split('|', 2)
    if len(parts) != 3:
        continue
    surface_id, fixture, command = parts
    command = command.strip()
    tokens = [token for token in command.split(' ') if token]
    key = ' '.join(tokens)
    if key in args_map or key in seen_keys:
        continue
    issues.append({
        'issue_type': 'flag-gap',
        'case_id': f'surface:{surface_id}',
        'details': f"No matrix coverage for `githooks{(' ' + command) if command else ''}` (fixture {fixture})"
    })
    seen_keys.add(key)

type_order = {'log-truncation': 0, 'flag-gap': 1, 'coverage-gap': 2, 'alias-divergence': 3}
issues.sort(key=lambda item: (type_order.get(item['issue_type'], 99), item['case_id']))

with json_out.open('w') as handle:
    json.dump(issues, handle, indent=2, sort_keys=True)
    handle.write('\n')

order = ['log-truncation', 'flag-gap', 'coverage-gap', 'alias-divergence']
lines = []
for issue_type in order:
    lines.append(issue_type)
    entries = [issue for issue in issues if issue['issue_type'] == issue_type]
    if entries:
        for entry in entries:
            lines.append(f"- {entry['case_id']}: {entry['details']}")
    else:
        lines.append('- none')
    lines.append('')

if lines and lines[-1] == '':
    lines = lines[:-1]

text_out.write_text('\n'.join(lines) + '\n')
PY
}

if command -v jq >/dev/null 2>&1; then
  if ! run_with_jq; then
    cleanup
    printf '%s\n' 'report: jq processing failed, falling back to python' >&2
    run_with_python
  fi
else
  run_with_python
fi
