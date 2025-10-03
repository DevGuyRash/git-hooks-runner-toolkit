#!/bin/sh
# Example hook part: execute configured commands when matching files change.
# Supports YAML or JSON configuration (via yq/jq) and inline shell-defined rules.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
LIB_PATH="${SCRIPT_DIR}/../lib/common.sh"
if [ ! -f "${LIB_PATH}" ]; then
  printf '[hook-runner] ERROR: watch-configured-actions helper missing common library at %s\n' "${LIB_PATH}" >&2
  exit 1
fi
# shellcheck source=scripts/git-hooks/lib/common.sh
. "${LIB_PATH}"

if githooks_is_bare_repo; then
  githooks_log_info "watch-configured-actions example not applicable to bare repositories"
  exit 0
fi

REPO_ROOT=$(githooks_repo_top)
cd "${REPO_ROOT}" || exit 1

HOOK_NAME=${GITHOOKS_HOOK_NAME:-$(basename "${0:-watch-configured-actions}")}
HOOK_ARG1=${1-}
HOOK_ARG2=${2-}
HOOK_ARG3=${3-}

CHANGED_FILE_LOG=$(mktemp "${TMPDIR:-/tmp}/githooks-watch-files.XXXXXX") || exit 1
TRIGGER_LOG=$(mktemp "${TMPDIR:-/tmp}/githooks-watch-triggers.XXXXXX") || exit 1
RULE_NAMES_FILE=$(mktemp "${TMPDIR:-/tmp}/githooks-watch-names.XXXXXX") || exit 1
RULE_PATTERNS_FILE=$(mktemp "${TMPDIR:-/tmp}/githooks-watch-patterns.XXXXXX") || exit 1
RULE_COMMANDS_FILE=$(mktemp "${TMPDIR:-/tmp}/githooks-watch-commands.XXXXXX") || exit 1
RULE_CONTINUES_FILE=$(mktemp "${TMPDIR:-/tmp}/githooks-watch-continues.XXXXXX") || exit 1

cleanup_all() {
  if [ "${GITHOOKS_WATCH_PRESERVE_TMP:-0}" = "1" ]; then
    return 0
  fi
  rm -f "${CHANGED_FILE_LOG}" "${TRIGGER_LOG}" \
    "${RULE_NAMES_FILE}" "${RULE_PATTERNS_FILE}" "${RULE_COMMANDS_FILE}" "${RULE_CONTINUES_FILE}"
}
trap cleanup_all EXIT HUP INT TERM

if [ "${GITHOOKS_WATCH_DEBUG:-0}" = "1" ]; then
  githooks_log_info "watch-configured-actions debug: CHANGED_FILE_LOG=${CHANGED_FILE_LOG}"
fi

RULE_COUNT=0
DELIM_PATTERN=$(printf '\036')
DELIM_COMMAND=$(printf '\037')

# Define inline rules here if desired (see README for format).
WATCH_INLINE_RULES_DEFAULT=${WATCH_INLINE_RULES_DEFAULT:-""}

append_rule() {
  rule_name=$1
  rule_patterns=$2
  rule_commands=$3
  rule_continue=$4

  RULE_COUNT=$((RULE_COUNT + 1))
  printf '%s\n' "${rule_name}" >>"${RULE_NAMES_FILE}"
  printf '%s\n' "${rule_patterns}" >>"${RULE_PATTERNS_FILE}"
  printf '%s\n' "${rule_commands}" >>"${RULE_COMMANDS_FILE}"
  printf '%s\n' "${rule_continue}" >>"${RULE_CONTINUES_FILE}"
}

trim_spaces() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

pattern_to_regex() {
  input_pattern=$1
  printf '%s\n' "${input_pattern}" | awk '
    {
      regex="^"
      len=length($0)
      i=1
      while (i <= len) {
        c=substr($0, i, 1)
        if (c == "*") {
          if (i < len && substr($0, i + 1, 1) == "*") {
            regex=regex ".*"
            i+=2
            continue
          }
          regex=regex "[^/]*"
          i+=1
          continue
        }
        if (c == "?") {
          regex=regex "[^/]"
          i+=1
          continue
        }
        if (c ~ /[.^$+(){}[\]|\\]/) {
          regex=regex "\\" c
          i+=1
          continue
        }
        regex=regex c
        i+=1
      }
      regex=regex "$"
      print regex
    }'
}

record_trigger() {
  printf '%s\n' "$1" >>"${TRIGGER_LOG}"
}

write_mark_file() {
  mark=${GITHOOKS_WATCH_MARK_FILE:-}
  if [ -z "${mark}" ] || [ "${TRIGGERED}" -eq 0 ]; then
    return 0
  fi
  case "${mark}" in
    /*) mark_path=${mark} ;;
    *) mark_path="${REPO_ROOT%/}/${mark}" ;;
  esac
  mkdir -p "$(dirname "${mark_path}")"
  changed_count=$(grep -c '.' "${CHANGED_FILE_LOG}" 2>/dev/null || true)
  {
    printf 'hook=%s\n' "${HOOK_NAME}"
    while IFS= read -r note_line || [ -n "${note_line}" ]; do
      [ -n "${note_line}" ] || continue
      printf 'trigger=%s\n' "${note_line}"
    done <"${TRIGGER_LOG}"
    printf 'changed-count=%s\n' "${changed_count}"
    while IFS= read -r changed_line || [ -n "${changed_line}" ]; do
      [ -n "${changed_line}" ] || continue
      printf 'changed=%s\n' "${changed_line}"
    done <"${CHANGED_FILE_LOG}"
  } >"${mark_path}"
}

collect_changed_files() {
  append_from_diff() {
    "$@" 2>/dev/null | while IFS= read -r rel_path; do
      [ -n "${rel_path}" ] || continue
      printf '%s\n' "${rel_path}" >>"${CHANGED_FILE_LOG}"
    done
  }

  case "${HOOK_NAME}" in
    post-merge)
      if git rev-parse --verify ORIG_HEAD >/dev/null 2>&1; then
        append_from_diff git diff-tree -r --name-only --no-commit-id ORIG_HEAD HEAD
      fi
      ;;
    post-rewrite)
      stdin_map=${GITHOOKS_STDIN_FILE:-}
      have_maps=0
      if [ -n "${stdin_map}" ] && [ -s "${stdin_map}" ]; then
        while IFS= read -r map_line; do
          set -- ${map_line}
          old_ref=$1
          new_ref=$2
          if [ -n "${old_ref}" ] && [ -n "${new_ref}" ]; then
            have_maps=1
            append_from_diff git diff --name-only "${old_ref}" "${new_ref}"
          fi
        done <"${stdin_map}"
      fi
      if [ "${have_maps}" -eq 0 ]; then
        if git rev-parse --verify ORIG_HEAD >/dev/null 2>&1; then
          append_from_diff git diff --name-only ORIG_HEAD HEAD
        fi
        if [ ! -s "${CHANGED_FILE_LOG}" ] && git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
          append_from_diff git diff --name-only HEAD~1 HEAD
        fi
      fi
      ;;
    post-checkout)
      old_ref=${HOOK_ARG1}
      new_ref=${HOOK_ARG2}
      checkout_flag=${HOOK_ARG3}
      if [ "${checkout_flag}" = "1" ] && [ -n "${old_ref}" ] && [ -n "${new_ref}" ]; then
        append_from_diff git diff-tree -r --name-only --no-commit-id "${old_ref}" "${new_ref}"
      fi
      ;;
    post-commit)
      if git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
        append_from_diff git diff --name-only HEAD~1 HEAD
      else
        append_from_diff git diff-tree -r --name-only --no-commit-id HEAD
      fi
      ;;
    *)
      githooks_log_info "watch-configured-actions example: hook ${HOOK_NAME} not handled; skipping"
      ;;
  esac
}

parse_rule_line() {
  line=$1
  tab=$(printf '\t')
  name=${line%%${tab}*}
  rest=${line#*${tab}}
  if [ "${rest}" = "${line}" ]; then
    rest=''
  fi
  patterns=${rest%%${tab}*}
  rest=${rest#*${tab}}
  if [ "${rest}" = "${patterns}" ]; then
    rest=''
  fi
  commands=${rest%%${tab}*}
  continue_flag=${rest#*${tab}}
  if [ "${continue_flag}" = "${commands}" ]; then
    continue_flag=''
  fi
  name=$(trim_spaces "${name}")
  patterns=$(trim_spaces "${patterns}")
  commands=$(trim_spaces "${commands}")
  continue_flag=$(trim_spaces "${continue_flag}")
  if [ -z "${patterns}" ]; then
    githooks_log_warn "watch-configured-actions example: skipping rule '${name}' with no patterns"
    return 1
  fi
  if [ -z "${commands}" ]; then
    commands=""
  fi
  case "${continue_flag}" in
    true|1|yes|on) continue_flag=true ;;
    *) continue_flag=false ;;
  esac
  append_rule "${name}" "${patterns}" "${commands}" "${continue_flag}"
  return 0
}

load_config_rules() {
  config_path=$1
  ext=${config_path##*.}
  case "${ext}" in
    yml|yaml)
      if ! command -v yq >/dev/null 2>&1; then
        githooks_log_warn "watch-configured-actions example: yq not found; cannot parse ${config_path}"
        return 1
      fi
      yaml_filter='.[] | [ (.name // ""), ((.patterns // []) | join("\u001e")), ((.commands // []) | join("\u001f")), ((.continue_on_error // false) | tostring) ] | @tsv'
      if ! config_lines=$(yq eval -r "${yaml_filter}" "${config_path}" 2>/dev/null); then
        config_lines=$(yq -r "${yaml_filter}" "${config_path}" 2>/dev/null) || {
          githooks_log_warn "watch-configured-actions example: failed to parse ${config_path}"
          return 1
        }
      fi
      ;;
    json)
      if ! command -v jq >/dev/null 2>&1; then
        githooks_log_warn "watch-configured-actions example: jq not found; cannot parse ${config_path}"
        return 1
      fi
      config_lines=$(jq -r '.[] | [ (.name // ""), ((.patterns // []) | join("\u001e")), ((.commands // []) | join("\u001f")), (.continue_on_error // false) ] | @tsv' "${config_path}" 2>/dev/null) || {
        githooks_log_warn "watch-configured-actions example: failed to parse ${config_path}"
        return 1
      }
      ;;
    *)
      githooks_log_warn "watch-configured-actions example: unsupported config extension for ${config_path}"
      return 1
      ;;
  esac

  config_tmp=$(mktemp "${TMPDIR:-/tmp}/githooks-watch-config-lines.XXXXXX") || return 1
  printf '%s\n' "${config_lines}" >"${config_tmp}"
  while IFS= read -r cfg_line || [ -n "${cfg_line}" ]; do
    [ -n "${cfg_line}" ] || continue
    parse_rule_line "${cfg_line}"
  done <"${config_tmp}"
  rm -f "${config_tmp}"
  return 0
}

load_inline_rules() {
  inline_source=$1
  current_name=""
  current_patterns=""
  current_commands=""
  current_continue="false"
  before_count=${RULE_COUNT}
  inline_tmp=$(mktemp "${TMPDIR:-/tmp}/githooks-watch-inline.XXXXXX") || return 1
  printf '%s\n' "${inline_source}" >"${inline_tmp}"

  flush_rule() {
    if [ -z "${current_patterns}" ]; then
      current_name=""
      current_patterns=""
      current_commands=""
      current_continue="false"
      return 0
    fi
    if [ -z "${current_name}" ]; then
      current_name="inline-${RULE_COUNT}" 
    fi
    append_rule "${current_name}" "${current_patterns}" "${current_commands}" "${current_continue}"
    if [ "${GITHOOKS_WATCH_DEBUG:-0}" = "1" ]; then
      githooks_log_info "watch-configured-actions debug: inline rule '${current_name}' registered"
    fi
    current_name=""
    current_patterns=""
    current_commands=""
    current_continue="false"
    return 0
  }

  while IFS= read -r raw_line || [ -n "${raw_line}" ]; do
    line=$(trim_spaces "${raw_line}")
    if [ "${GITHOOKS_WATCH_DEBUG:-0}" = "1" ]; then
      githooks_log_info "watch-configured-actions debug: inline line='${line}'"
    fi
    [ -n "${line}" ] || { flush_rule; continue; }
    case "${line}" in
      \#*) continue ;;
      name=*)
        current_name=$(trim_spaces "${line#name=}")
        ;;
      patterns=*)
        value=$(trim_spaces "${line#patterns=}")
        value=$(printf '%s' "${value}" | tr ',' "${DELIM_PATTERN}")
        current_patterns="${value}"
        if [ "${GITHOOKS_WATCH_DEBUG:-0}" = "1" ]; then
          githooks_log_info "watch-configured-actions debug: inline patterns=${current_patterns}"
        fi
        ;;
      commands=*)
        cmd=$(trim_spaces "${line#commands=}")
        if [ -n "${current_commands}" ]; then
          current_commands="${current_commands}${DELIM_COMMAND}${cmd}"
        else
          current_commands="${cmd}"
        fi
        if [ "${GITHOOKS_WATCH_DEBUG:-0}" = "1" ]; then
          githooks_log_info "watch-configured-actions debug: inline command='${cmd}'"
        fi
        ;;
      continue_on_error=*)
        val=$(trim_spaces "${line#continue_on_error=}")
        case "${val}" in
          true|1|yes|on) current_continue="true" ;;
          *) current_continue="false" ;;
        esac
        ;;
      *)
        githooks_log_warn "watch-configured-actions example: unrecognised inline directive '${line}'"
        ;;
    esac
  done <"${inline_tmp}"
  rm -f "${inline_tmp}"
  flush_rule
  if [ "${RULE_COUNT}" -le "${before_count}" ]; then
    githooks_log_warn "watch-configured-actions example: inline rules provided but none parsed"
    return 1
  fi
  return 0
}

select_config_path() {
  candidate=${GITHOOKS_WATCH_CONFIG:-}
  if [ -n "${candidate}" ]; then
    case "${candidate}" in
      /*) maybe_path=${candidate} ;;
      *) maybe_path="${REPO_ROOT%/}/${candidate}" ;;
    esac
    if [ -f "${maybe_path}" ]; then
      printf '%s' "${maybe_path}"
      return 0
    fi
    githooks_log_warn "watch-configured-actions example: configured path ${maybe_path} not found"
  fi
  for option in \
    "${REPO_ROOT}/.githooks/watch-config.yml" \
    "${REPO_ROOT}/.githooks/watch-config.yaml" \
    "${REPO_ROOT}/.githooks/watch-config.json"; do
    if [ -f "${option}" ]; then
      printf '%s' "${option}"
      return 0
    fi
  done
  return 1
}

collect_changed_files

TRIGGERED=0
FAIL_STATUS=0

if ! grep -q '.' "${CHANGED_FILE_LOG}" 2>/dev/null; then
  githooks_log_info "watch-configured-actions example: no tracked changes detected for ${HOOK_NAME}"
  write_mark_file
  exit 0
fi

config_loaded=0
config_path=$(select_config_path || true)
if [ -n "${config_path}" ]; then
  if load_config_rules "${config_path}"; then
    config_loaded=1
  fi
fi

if [ "${config_loaded}" -eq 0 ]; then
  inline_rules=${WATCH_INLINE_RULES:-${WATCH_INLINE_RULES_DEFAULT}}
  if [ -n "${inline_rules}" ]; then
    if load_inline_rules "${inline_rules}"; then
      config_loaded=1
    fi
  fi
fi

if [ "${config_loaded}" -eq 0 ] || [ "${RULE_COUNT}" -eq 0 ]; then
  githooks_log_info "watch-configured-actions example: no rules configured"
  write_mark_file
  exit 0
fi

if [ "${GITHOOKS_WATCH_DEBUG:-0}" = "1" ]; then
  githooks_log_info "watch-configured-actions debug: loaded ${RULE_COUNT} rule(s)"
fi

index=1
while [ "${index}" -le "${RULE_COUNT}" ]; do
  rule_name=$(sed -n "${index}p" "${RULE_NAMES_FILE}" 2>/dev/null || printf '')
  pattern_set=$(sed -n "${index}p" "${RULE_PATTERNS_FILE}" 2>/dev/null || printf '')
  command_set=$(sed -n "${index}p" "${RULE_COMMANDS_FILE}" 2>/dev/null || printf '')
  continue_flag=$(sed -n "${index}p" "${RULE_CONTINUES_FILE}" 2>/dev/null || printf 'false')
  [ -n "${rule_name}" ] || rule_name="rule-${index}"

  match_count=0
  first_match=""

  saved_ifs=$IFS
  IFS=${DELIM_PATTERN}
  set -- dummy ${pattern_set}
  shift
  IFS=${saved_ifs}
  for pattern in "$@"; do
    pattern=$(trim_spaces "${pattern}")
    [ -n "${pattern}" ] || continue
    regex=$(pattern_to_regex "${pattern}" 2>/dev/null || printf '')
    [ -n "${regex}" ] || continue
    matches=$(grep -E "${regex}" "${CHANGED_FILE_LOG}" 2>/dev/null || printf '')
    if [ -n "${matches}" ]; then
      if [ -z "${first_match}" ]; then
        first_match=$(printf '%s\n' "${matches}" | head -n 1)
      fi
      count=$(printf '%s\n' "${matches}" | grep -c '.' || true)
      match_count=$((match_count + count))
      if [ "${GITHOOKS_WATCH_DEBUG:-0}" = "1" ]; then
        printf '%s\n' "${matches}" | while IFS= read -r matched || [ -n "${matched}" ]; do
          [ -n "${matched}" ] || continue
          githooks_log_info "watch-configured-actions debug: rule ${rule_name} pattern '${pattern}' matched '${matched}'"
        done
      fi
    elif [ "${GITHOOKS_WATCH_DEBUG:-0}" = "1" ]; then
      githooks_log_info "watch-configured-actions debug: rule ${rule_name} pattern '${pattern}' had no matches"
    fi
  done

  if [ "${match_count}" -eq 0 ]; then
    index=$((index + 1))
    continue
  fi

  TRIGGERED=1
  if [ -z "${first_match}" ]; then
    first_match=$(head -n 1 "${CHANGED_FILE_LOG}")

  fi
  record_trigger "${rule_name}: ${first_match}"

  saved_ifs=$IFS
  IFS=${DELIM_COMMAND}
  set -- dummy ${command_set}
  shift
  IFS=${saved_ifs}

  if [ "${#}" -eq 0 ] || [ -z "${1-}" ]; then
    githooks_log_info "watch-configured-actions example: ${rule_name} matched (${first_match}) but no commands configured"
    index=$((index + 1))
    continue
  fi

  githooks_log_info "watch-configured-actions example: ${rule_name} matched (${first_match}); running configured commands"

  command_failed=0
  for command_entry in "$@"; do
    command_entry=$(trim_spaces "${command_entry}")
    [ -n "${command_entry}" ] || continue
    githooks_log_info "watch-configured-actions example: executing (${rule_name}) -> ${command_entry}"
    if ! sh -c "${command_entry}"; then
      status=$?
      command_failed=1
      record_trigger "${rule_name}: command failed (${command_entry}) status=${status}"
      if [ "${continue_flag}" = "true" ]; then
        FAIL_STATUS=$((FAIL_STATUS | status))
        githooks_log_warn "watch-configured-actions example: command failed with exit ${status} (continue_on_error=true)"
        continue
      fi
      githooks_log_error "watch-configured-actions example: command failed with exit ${status}"
      write_mark_file
      exit "${status}"
    fi
  done

  if [ "${command_failed}" -eq 0 ]; then
    record_trigger "${rule_name}: commands completed"
  fi

  index=$((index + 1))
done

write_mark_file

if [ "${FAIL_STATUS}" -ne 0 ]; then
  exit 0
fi

if [ "${TRIGGERED}" -eq 0 ]; then
  githooks_log_info "watch-configured-actions example: no automation matched configured patterns"
fi

exit 0
