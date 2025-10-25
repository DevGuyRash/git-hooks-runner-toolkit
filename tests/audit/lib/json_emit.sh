#!/bin/sh
# Lightweight JSON emission helpers for NDJSON output.
# All functions are POSIX-sh compatible and avoid external dependencies.

# shellcheck shell=sh

json_emit_escape() {
  # Escape characters that need JSON encoding.
  _json_input=${1-}
  # Use printf + sed to avoid non-POSIX parameter expansion edge cases.
  printf '%s' "${_json_input}" |
    sed \
      -e 's/\\/\\\\/g' \
      -e 's/"/\\"/g' \
      -e 's/\r/\\r/g' \
      -e 's/\n/\\n/g' \
      -e 's/\t/\\t/g'
}

json_emit_array_from_lines() {
  # Convert newline-separated entries into a JSON array of strings.
  _json_lines=${1-}
  _json_first=1
  printf '['
  if [ -n "${_json_lines}" ]; then
    _json_old_ifs=${IFS}
    _json_nl=$(printf '\n_')
    IFS=${_json_nl%_}
    set -f
    for _json_line in ${_json_lines}; do
      [ -n "${_json_line}" ] || continue
      _json_item=$(json_emit_escape "${_json_line}")
      if [ ${_json_first} -eq 1 ]; then
        printf '"%s"' "${_json_item}"
        _json_first=0
      else
        printf ',"%s"' "${_json_item}"
      fi
    done
    set +f
    IFS=${_json_old_ifs}
  fi
  printf ']'
}

json_emit_object_begin() {
  printf '{'
  JSON_EMIT_FIRST_PAIR=1
}

json_emit_object_pair() {
  # Usage: json_emit_object_pair key value [raw]
  _json_key=${1-}
  _json_value=${2-}
  _json_raw=${3-}
  [ -n "${_json_key}" ] || return 1
  if [ "${JSON_EMIT_FIRST_PAIR:-1}" -eq 1 ]; then
    JSON_EMIT_FIRST_PAIR=0
  else
    printf ','
  fi
  printf '"%s":' "$(json_emit_escape "${_json_key}")"
  if [ "${_json_raw}" = 'raw' ]; then
    printf '%s' "${_json_value}"
  else
    printf '"%s"' "$(json_emit_escape "${_json_value}")"
  fi
}

json_emit_object_end() {
  printf '}'
}

json_emit_case_record() {
  # Convenience wrapper specifically for audit case records.
  # Parameters:
  #   $1 - case id
  #   $2 - command name
  #   $3 - newline-separated args
  #   $4 - exit code
  #   $5 - stdout checksum
  #   $6 - stderr checksum
  #   $7 - hooks path
  #   $8 - newline-separated overlay roots
  #   $9 - newline-separated notes
  json_emit_object_begin
  json_emit_object_pair 'id' "${1-}"
  json_emit_object_pair 'command' "${2-}"
  json_emit_object_pair 'args' "$(json_emit_array_from_lines "${3-}")" 'raw'
  json_emit_object_pair 'exit_code' "${4-}" 'raw'
  json_emit_object_pair 'stdout_crc' "${5-}"
  json_emit_object_pair 'stderr_crc' "${6-}"
  json_emit_object_pair 'hooks_path' "${7-}"
  json_emit_object_pair 'overlay_roots' "$(json_emit_array_from_lines "${8-}")" 'raw'
  json_emit_object_pair 'notes' "$(json_emit_array_from_lines "${9-}")" 'raw'
  json_emit_object_end
  printf '\n'
}
