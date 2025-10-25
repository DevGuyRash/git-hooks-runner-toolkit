#!/usr/bin/env bats

load '../helpers/assertions.sh'

setup_file() {
  HELP_SNAPSHOT="${BATS_TEST_DIRNAME}/lib/help_snapshot.sh"
  HELP_FIXTURE_DIR="${BATS_TEST_DIRNAME}/output/help"
  export HELP_SNAPSHOT HELP_FIXTURE_DIR
  if [ ! -f "${HELP_SNAPSHOT}" ]; then
    bats_die "help snapshot script missing: ${HELP_SNAPSHOT}"
  fi
}

_list_surfaces() {
  run sh "${HELP_SNAPSHOT}" list
  assert_success
  HELP_SURFACE_LINES=()
  while IFS= read -r _surface_line; do
    [ -n "${_surface_line}" ] || continue
    HELP_SURFACE_LINES+=("${_surface_line}")
  done <<EOF
${output}
EOF
}

_surface_fields() {
  local entry="$1"
  local _old_ifs=${IFS}
  IFS='|'
  read -r SURFACE_ID SURFACE_FIXTURE SURFACE_COMMAND <<EOF
${entry}
EOF
  IFS=${_old_ifs}
}

_surface_commands_for() {
  local needle="$1"
  local line
  for line in "${HELP_SURFACE_LINES[@]}"; do
    _surface_fields "${line}"
    if [ "${SURFACE_ID}" = "${needle}" ]; then
      printf '%s\n' "${SURFACE_COMMAND}"
      return 0
    fi
  done
  return 1
}

_surfaces_cover_command() {
  local command="$1"
  local line
  for line in "${HELP_SURFACE_LINES[@]}"; do
    _surface_fields "${line}"
    if [ -z "${SURFACE_COMMAND}" ]; then
      continue
    fi
    set -- ${SURFACE_COMMAND}
    if [ "$#" -eq 0 ]; then
      continue
    fi
    if [ "$1" = "${command}" ]; then
      return 0
    fi
    if [ "$1" = "help" ] && [ "$2" = "${command}" ]; then
      return 0
    fi
    if [ "${command}" = "help" ] && [ "$1" = "--help" ]; then
      return 0
    fi
  done
  return 1
}

_surfaces_cover_stage_subcommand() {
  local sub="$1"
  local line
  for line in "${HELP_SURFACE_LINES[@]}"; do
    _surface_fields "${line}"
    if [ -z "${SURFACE_COMMAND}" ]; then
      continue
    fi
    set -- ${SURFACE_COMMAND}
    if [ "$#" -eq 0 ]; then
      continue
    fi
    if [ "$1" = "stage" ]; then
      if [ "$2" = "${sub}" ]; then
        return 0
      fi
      if [ "$2" = "--help" ] && [ "$3" = "${sub}" ]; then
        return 0
      fi
      if [ "$2" = "help" ] && [ "$3" = "${sub}" ]; then
        return 0
      fi
    fi
    if [ "$1" = "help" ] && [ "$2" = "stage" ] && [ "$3" = "${sub}" ]; then
      return 0
    fi
  done
  return 1
}

_surfaces_cover_scoped_subcommand() {
  local scope="$1"
  local sub="$2"
  local line
  for line in "${HELP_SURFACE_LINES[@]}"; do
    _surface_fields "${line}"
    if [ -z "${SURFACE_COMMAND}" ]; then
      continue
    fi
    set -- ${SURFACE_COMMAND}
    if [ "$#" -eq 0 ]; then
      continue
    fi
    if [ "$1" = "${scope}" ]; then
      if [ "$2" = "${sub}" ]; then
        return 0
      fi
      if [ "$2" = "--help" ] && [ "$3" = "${sub}" ]; then
        return 0
      fi
      if [ "$2" = "help" ] && [ "$3" = "${sub}" ]; then
        return 0
      fi
    fi
    if [ "$1" = "help" ] && [ "$2" = "${scope}" ] && [ "$3" = "${sub}" ]; then
      return 0
    fi
  done
  return 1
}

_capture_stdout_section() {
  printf '%s\n' "$1" | awk '
    BEGIN { in_stdout=0 }
    /^# stdout$/ { in_stdout=1; next }
    /^# stderr$/ { in_stdout=0; exit }
    in_stdout { print }
  '
}

@test 'fixtures exist for each help surface' {
  _list_surfaces
  for line in "${HELP_SURFACE_LINES[@]}"; do
    _surface_fields "${line}"
    local path="${HELP_FIXTURE_DIR}/${SURFACE_FIXTURE}.txt"
    if [ ! -f "${path}" ]; then
      bats_die "missing fixture ${SURFACE_FIXTURE} for surface ${SURFACE_ID}"
    fi
  done
}

@test 'help surfaces match stored fixtures' {
  _list_surfaces
  for line in "${HELP_SURFACE_LINES[@]}"; do
    _surface_fields "${line}"
    local path="${HELP_FIXTURE_DIR}/${SURFACE_FIXTURE}.txt"
    run "${HELP_SNAPSHOT}" capture "${SURFACE_ID}"
    assert_success
    local actual_tmp
    actual_tmp=$(mktemp)
    printf '%s\n' "${output}" >"${actual_tmp}"
    local diff_tmp
    diff_tmp=$(mktemp)
    if ! diff -u "${path}" "${actual_tmp}" >"${diff_tmp}"; then
      local diff_out
      diff_out=$(cat "${diff_tmp}")
      rm -f "${actual_tmp}" "${diff_tmp}"
      bats_die "$SURFACE_ID fixture drift detected. Regenerate with: tests/audit/lib/help_snapshot.sh update\n${diff_out}"
    fi
    rm -f "${actual_tmp}" "${diff_tmp}"
  done
}

@test 'coverage enumerates commands and subcommands' {
  _list_surfaces

  local status_failures=()
  local line
  for line in "${HELP_SURFACE_LINES[@]}"; do
    _surface_fields "${line}"
    run sh "${HELP_SNAPSHOT}" capture "${SURFACE_ID}"
    local capture_output
    capture_output="${output}"
    local capture_status
    capture_status=$(printf '%s\n' "${capture_output}" | awk '
      /^# status$/ { getline; print; exit }
    ')
    if [ -z "${capture_status}" ]; then
      bats_die "unable to parse status for ${SURFACE_ID}"
    fi
    if [ "${capture_status}" != "0" ]; then
      status_failures+=("${SURFACE_ID}=${capture_status}")
    fi
  done

  local coverage_errors=()
  if [ "${#status_failures[@]}" -ne 0 ]; then
    coverage_errors+=("help surfaces exit non-zero: ${status_failures[*]}")
  fi

  run sh "${HELP_SNAPSHOT}" capture global-flag
  assert_success
  local global_stdout
  global_stdout=$(_capture_stdout_section "${output}")
  local commands
  commands=$(printf '%s\n' "${global_stdout}" | awk '
    /^COMMAND OVERVIEW$/ { section=1; next }
    section && /^$/ { exit }
    section && /^[[:space:]]+[A-Za-z0-9-]+[[:space:]]*$/ {
      gsub(/^[[:space:]]+/, "")
      print
    }
  ')

  local missing=()
  local cmd
  while IFS= read -r cmd; do
    [ -n "${cmd}" ] || continue
    if ! _surfaces_cover_command "${cmd}"; then
      missing+=("${cmd}")
    fi
  done <<EOF
${commands}
EOF
  if [ "${#missing[@]}" -ne 0 ]; then
    coverage_errors+=("missing help coverage for commands: ${missing[*]}")
  fi

  run sh "${HELP_SNAPSHOT}" capture stage-flag
  assert_success
  local stage_stdout
  stage_stdout=$(_capture_stdout_section "${output}")
  local stage_missing=()
  local stage_sub
  while IFS= read -r stage_sub; do
    [ -n "${stage_sub}" ] || continue
    if [ "${stage_sub}" = "help" ]; then
      continue
    fi
    if ! _surfaces_cover_stage_subcommand "${stage_sub}"; then
      stage_missing+=("${stage_sub}")
    fi
  done <<EOF
$(printf '%s\n' "${stage_stdout}" | awk '
  /^SUBCOMMANDS$/ { section=1; next }
  section && /^$/ { exit }
  section && /^[[:space:]]+[A-Za-z0-9-]+[[:space:]]*$/ {
    gsub(/^[[:space:]]+/, "")
    print
  }
')
EOF
  if [ "${#stage_missing[@]}" -ne 0 ]; then
    coverage_errors+=("missing stage coverage for: ${stage_missing[*]}")
  fi

  run sh "${HELP_SNAPSHOT}" capture hooks-flag
  assert_success
  local hooks_stdout
  hooks_stdout=$(_capture_stdout_section "${output}")
  local hooks_missing=()
  local hook_sub
  while IFS= read -r hook_sub; do
    [ -n "${hook_sub}" ] || continue
    if [ "${hook_sub}" = "help" ]; then
      continue
    fi
    if ! _surfaces_cover_scoped_subcommand "hooks" "${hook_sub}"; then
      hooks_missing+=("${hook_sub}")
    fi
  done <<EOF
$(printf '%s\n' "${hooks_stdout}" | awk '
  /^SUBCOMMANDS$/ { section=1; next }
  section && /^$/ { exit }
  section && /^[[:space:]]+[A-Za-z0-9-]+[[:space:]]*$/ {
    gsub(/^[[:space:]]+/, "")
    print
  }
')
EOF
  if [ "${#hooks_missing[@]}" -ne 0 ]; then
    coverage_errors+=("missing hooks coverage for: ${hooks_missing[*]}")
  fi

  run sh "${HELP_SNAPSHOT}" capture config-flag
  assert_success
  local config_stdout
  config_stdout=$(_capture_stdout_section "${output}")
  local config_missing=()
  local config_sub
  while IFS= read -r config_sub; do
    [ -n "${config_sub}" ] || continue
    if [ "${config_sub}" = "help" ]; then
      continue
    fi
    if ! _surfaces_cover_scoped_subcommand "config" "${config_sub}"; then
      config_missing+=("${config_sub}")
    fi
  done <<EOF
$(printf '%s\n' "${config_stdout}" | awk '
  /^SUBCOMMANDS$/ { section=1; next }
  section && /^$/ { exit }
  section && /^[[:space:]]+[A-Za-z0-9-]+[[:space:]]*$/ {
    gsub(/^[[:space:]]+/, "")
    print
  }
')
EOF
  if [ "${#config_missing[@]}" -ne 0 ]; then
    coverage_errors+=("missing config coverage for: ${config_missing[*]}")
  fi

  if [ "${#coverage_errors[@]}" -ne 0 ]; then
    bats_die "${coverage_errors[*]}"
  fi
}

@test 'legacy aliases emit help fixtures' {
  _list_surfaces
  local aliases=(legacy-init-flag legacy-add-flag legacy-remove-flag)
  local alias
  for alias in "${aliases[@]}"; do
    if ! _surface_commands_for "${alias}" >/dev/null; then
      bats_die "missing legacy fixture for ${alias}"
    fi
  done
}
