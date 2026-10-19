#!/bin/sh
# General-purpose wrapper: run a command (or read stdin/file), print output,
# and convert PASS/FAIL-like signals into an exit code.

set -eu

print_output=1
fail_re='FAIL'
pass_re='PASS'
output_file=''

usage() {
  cat <<'USAGE'
Usage:
  exit-code-from-output.sh [--fail REGEX] [--pass REGEX] [--file PATH] [--no-print] -- cmd [args...]
  exit-code-from-output.sh [--fail REGEX] [--pass REGEX] [--file PATH] [--no-print] < input

Defaults:
  --fail 'FAIL'   Exit 1 if output matches this pattern.
  --pass 'PASS'   Exit 0 if output matches this pattern.

Behavior:
  - If fail pattern matches, exit 1.
  - Else if pass pattern matches, exit 0.
  - Else exit 1.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --fail)
      fail_re=$2
      shift 2
      ;;
    --pass)
      pass_re=$2
      shift 2
      ;;
    --file)
      output_file=$2
      shift 2
      ;;
    --no-print)
      print_output=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

if [ -n "${output_file}" ]; then
  if [ ! -f "${output_file}" ]; then
    printf 'exit-code-from-output: missing file %s\n' "${output_file}" >&2
    exit 2
  fi
  output=$(cat "${output_file}")
elif [ "$#" -gt 0 ]; then
  output=$("$@" 2>&1)
else
  output=$(cat)
fi

if [ "${print_output}" -eq 1 ]; then
  printf '%s\n' "${output}"
fi

if [ -n "${fail_re}" ] && printf '%s\n' "${output}" | grep -E -q "${fail_re}"; then
  exit 1
fi
if [ -n "${pass_re}" ] && printf '%s\n' "${output}" | grep -E -q "${pass_re}"; then
  exit 0
fi

exit 1
