#!/bin/sh
# shell library: shared logic for watch-configured-actions hooks

# shellcheck disable=SC2034 # library defines globals consumed by callers

# Requires lib/common.sh to be sourced beforehand.

WATCH_ACTIONS_DELIM_PATTERN=$(printf '\036')
WATCH_ACTIONS_DELIM_COMMAND=$(printf '\037')

watch_actions_init() {
  if [ "$#" -lt 1 ]; then
    githooks_die "watch_actions_init requires hook name"
  fi

  WATCH_ACTIONS_HOOK_NAME=$1
  WATCH_ACTIONS_REPO_ROOT=$(githooks_repo_top)
  WATCH_ACTIONS_HOOKS_ROOT=$(githooks_hooks_root)
  WATCH_ACTIONS_CENTRAL_DIR="${WATCH_ACTIONS_HOOKS_ROOT%/}/config"
  WATCH_ACTIONS_CENTRAL_HINT="${WATCH_ACTIONS_CENTRAL_DIR%/}/watch-configured-actions.yml"

  cd "${WATCH_ACTIONS_REPO_ROOT}" || githooks_die "watch-configured-actions: unable to enter repo root"

  WATCH_ACTIONS_CHANGED_FILE_LOG=$(mktemp "${TMPDIR:-/tmp}/githooks-watch-files.XXXXXX") || \
    githooks_die "Failed to allocate changed files log"
  WATCH_ACTIONS_TRIGGER_LOG=$(mktemp "${TMPDIR:-/tmp}/githooks-watch-triggers.XXXXXX") || \
    githooks_die "Failed to allocate trigger log"
  WATCH_ACTIONS_RULE_NAMES_FILE=$(mktemp "${TMPDIR:-/tmp}/githooks-watch-names.XXXXXX") || \
    githooks_die "Failed to allocate rule names log"
  WATCH_ACTIONS_RULE_PATTERNS_FILE=$(mktemp "${TMPDIR:-/tmp}/githooks-watch-patterns.XXXXXX") || \
    githooks_die "Failed to allocate rule patterns log"
  WATCH_ACTIONS_RULE_COMMANDS_FILE=$(mktemp "${TMPDIR:-/tmp}/githooks-watch-commands.XXXXXX") || \
    githooks_die "Failed to allocate rule commands log"
  WATCH_ACTIONS_RULE_CONTINUES_FILE=$(mktemp "${TMPDIR:-/tmp}/githooks-watch-continues.XXXXXX") || \
    githooks_die "Failed to allocate rule continues log"

  WATCH_ACTIONS_TEMPFILES="${WATCH_ACTIONS_CHANGED_FILE_LOG} ${WATCH_ACTIONS_TRIGGER_LOG} \
${WATCH_ACTIONS_RULE_NAMES_FILE} ${WATCH_ACTIONS_RULE_PATTERNS_FILE} \
${WATCH_ACTIONS_RULE_COMMANDS_FILE} ${WATCH_ACTIONS_RULE_CONTINUES_FILE}"

  WATCH_ACTIONS_RULE_COUNT=0
  WATCH_ACTIONS_TRIGGERED=0
  WATCH_ACTIONS_FAIL_STATUS=0
  WATCH_ACTIONS_LEGACY_NOTICE_EMITTED=0
  WATCH_ACTIONS_CONFIG_LOAD_DIAG=""

  trap "watch_actions_cleanup" EXIT HUP INT TERM

  if [ "${GITHOOKS_WATCH_DEBUG:-0}" = "1" ]; then
    githooks_log_info "watch-configured-actions debug: CHANGED_FILE_LOG=${WATCH_ACTIONS_CHANGED_FILE_LOG}"
  fi
}

watch_actions_cleanup() {
  if [ "${GITHOOKS_WATCH_PRESERVE_TMP:-0}" = "1" ]; then
    return 0
  fi
  if [ -n "${WATCH_ACTIONS_TEMPFILES:-}" ]; then
    # shellcheck disable=SC2086
    rm -f ${WATCH_ACTIONS_TEMPFILES} 2>/dev/null || true
  fi
}

watch_actions_append_changed_file() {
  if [ "$#" -ne 1 ]; then
    return 0
  fi
  file=$1
  [ -n "${file}" ] || return 0
  printf '%s\n' "${file}" >>"${WATCH_ACTIONS_CHANGED_FILE_LOG}"
}

watch_actions_trim() {
  if [ "$#" -eq 0 ]; then
    return 0
  fi
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

watch_actions_unescape_newlines() {
  if [ "$#" -ne 1 ]; then
    return 0
  fi
  printf '%s' "$1" | awk 'BEGIN{RS=""; ORS=""} {gsub(/\\n/, "\n"); print}'
}

watch_actions_pattern_to_regex() {
  if [ "$#" -ne 1 ]; then
    return 1
  fi
  printf '%s\n' "$1" | awk '
    function escape_char(ch) {
      if (ch ~ /[.^$+(){}[\]|\\]/) {
        return "\\" ch
      }
      return ch
    }
    {
      pattern=$0
      len=length(pattern)
      regex="^"
      i=1
      while (i <= len) {
        c=substr(pattern, i, 1)
        if (c == "*") {
          if (i < len && substr(pattern, i + 1, 1) == "*") {
            i+=2
            while (i <= len && substr(pattern, i, 1) == "*") {
              i+=1
            }
            if (i <= len && substr(pattern, i, 1) == "/") {
              regex=regex "([^/]+/)*"
              i+=1
            }
            else {
              regex=regex ".*"
            }
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
        if (c == "/") {
          regex=regex "/"
          i+=1
          continue
        }
        regex=regex escape_char(c)
        i+=1
      }
      regex=regex "$"
      print regex
    }'
}

watch_actions_append_rule() {
  if [ "$#" -ne 4 ]; then
    return 1
  fi
  WATCH_ACTIONS_RULE_COUNT=$((WATCH_ACTIONS_RULE_COUNT + 1))
  printf '%s\n' "$1" >>"${WATCH_ACTIONS_RULE_NAMES_FILE}"
  printf '%s\n' "$2" >>"${WATCH_ACTIONS_RULE_PATTERNS_FILE}"
  printf '%s\n' "$3" >>"${WATCH_ACTIONS_RULE_COMMANDS_FILE}"
  printf '%s\n' "$4" >>"${WATCH_ACTIONS_RULE_CONTINUES_FILE}"
}

watch_actions_record_trigger() {
  if [ "$#" -ne 1 ]; then
    return 0
  fi
  printf '%s\n' "$1" >>"${WATCH_ACTIONS_TRIGGER_LOG}"
}

watch_actions_write_mark_file() {
  mark=${GITHOOKS_WATCH_MARK_FILE:-}
  if [ -z "${mark}" ] || [ "${WATCH_ACTIONS_TRIGGERED}" -eq 0 ]; then
    return 0
  fi
  case "${mark}" in
    /*) mark_path=${mark} ;;
    *) mark_path="${WATCH_ACTIONS_REPO_ROOT%/}/${mark}" ;;
  esac
  mkdir -p "$(dirname "${mark_path}")"
  changed_count=$(grep -c '.' "${WATCH_ACTIONS_CHANGED_FILE_LOG}" 2>/dev/null || true)
  {
    printf 'hook=%s\n' "${WATCH_ACTIONS_HOOK_NAME}"
    while IFS= read -r note_line || [ -n "${note_line}" ]; do
      [ -n "${note_line}" ] || continue
      printf 'trigger=%s\n' "${note_line}"
    done <"${WATCH_ACTIONS_TRIGGER_LOG}"
    printf 'changed-count=%s\n' "${changed_count}"
    while IFS= read -r changed_line || [ -n "${changed_line}" ]; do
      [ -n "${changed_line}" ] || continue
      printf 'changed=%s\n' "${changed_line}"
    done <"${WATCH_ACTIONS_CHANGED_FILE_LOG}"
  } >"${mark_path}"
}

watch_actions_append_from_diff() {
  if [ "$#" -lt 1 ]; then
    return 0
  fi
  "$@" 2>/dev/null | while IFS= read -r rel_path; do
    [ -n "${rel_path}" ] || continue
    watch_actions_append_changed_file "${rel_path}"
  done
}

watch_actions_collect_post_event_changes() {
  hook_name=$1
  hook_arg1=${2-}
  hook_arg2=${3-}
  hook_arg3=${4-}

  case "${hook_name}" in
    post-merge)
      if git rev-parse --verify ORIG_HEAD >/dev/null 2>&1; then
        watch_actions_append_from_diff git diff-tree -r --name-only --no-commit-id ORIG_HEAD HEAD
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
            watch_actions_append_from_diff git diff --name-only "${old_ref}" "${new_ref}"
          fi
        done <"${stdin_map}"
      fi
      if [ "${have_maps}" -eq 0 ]; then
        if git rev-parse --verify ORIG_HEAD >/dev/null 2>&1; then
          watch_actions_append_from_diff git diff --name-only ORIG_HEAD HEAD
        fi
        if [ ! -s "${WATCH_ACTIONS_CHANGED_FILE_LOG}" ] && git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
          watch_actions_append_from_diff git diff --name-only HEAD~1 HEAD
        fi
      fi
      ;;
    post-checkout)
      old_ref=${hook_arg1}
      new_ref=${hook_arg2}
      checkout_flag=${hook_arg3}
      if [ "${checkout_flag}" = "1" ] && [ -n "${old_ref}" ] && [ -n "${new_ref}" ]; then
        watch_actions_append_from_diff git diff-tree -r --name-only --no-commit-id "${old_ref}" "${new_ref}"
      fi
      ;;
    post-commit)
      if git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
        watch_actions_append_from_diff git diff --name-only HEAD~1 HEAD
      else
        watch_actions_append_from_diff git diff-tree -r --name-only --no-commit-id HEAD
      fi
      ;;
    *)
      githooks_log_info "watch-configured-actions example: hook ${hook_name} not handled; skipping"
      ;;
  esac
}

watch_actions_collect_pre_commit_changes() {
  watch_actions_append_from_diff git diff --cached --name-only --diff-filter=ACMR
}

watch_actions_parse_rule_line() {
  if [ "$#" -ne 1 ]; then
    return 1
  fi
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
  name=$(watch_actions_trim "${name}")
  patterns=$(watch_actions_trim "${patterns}")
  commands=$(watch_actions_trim "${commands}")
  continue_flag=$(watch_actions_trim "${continue_flag}")
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
  watch_actions_append_rule "${name}" "${patterns}" "${commands}" "${continue_flag}"
  return 0
}

watch_actions_load_config_rules() {
  if [ "$#" -ne 1 ]; then
    return 1
  fi
  config_path=$1
  ext=${config_path##*.}

  WATCH_ACTIONS_CONFIG_LOAD_DIAG=""

  if [ ! -r "${config_path}" ]; then
    githooks_log_error "watch-configured-actions: unable to read ${config_path}; check install mode (persistent vs ephemeral)"
    return 1
  fi

  case "${ext}" in
    yml|yaml)
      if ! command -v yq >/dev/null 2>&1; then
        githooks_log_warn "watch-configured-actions example: yq not found; skipping ${config_path}"
        WATCH_ACTIONS_CONFIG_LOAD_DIAG="missing-yq"
        return 2
      fi
      yaml_filter='.[] | [ (.name // ""), ((.patterns // []) | join("\u001e")), ((.commands // []) | join("\u001f")), ((.continue_on_error // false) | tostring) ] | @tsv'
      if ! config_lines=$(yq eval -r "${yaml_filter}" "${config_path}" 2>/dev/null); then
        config_lines=$(yq -r "${yaml_filter}" "${config_path}" 2>/dev/null) || {
          githooks_log_error "watch-configured-actions: failed to parse ${config_path}; see docs/examples/watch-configured-actions.md"
          WATCH_ACTIONS_CONFIG_LOAD_DIAG="parse-error"
          return 1
        }
      fi
      ;;
    json)
      if ! command -v jq >/dev/null 2>&1; then
        githooks_log_warn "watch-configured-actions example: jq not found; skipping ${config_path}"
        WATCH_ACTIONS_CONFIG_LOAD_DIAG="missing-jq"
        return 2
      fi
      config_lines=$(jq -r '.[] | [ (.name // ""), ((.patterns // []) | join("\u001e")), ((.commands // []) | join("\u001f")), (.continue_on_error // false) ] | @tsv' "${config_path}" 2>/dev/null) || {
        githooks_log_error "watch-configured-actions: failed to parse ${config_path}; see docs/examples/watch-configured-actions.md"
        WATCH_ACTIONS_CONFIG_LOAD_DIAG="parse-error"
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
    if ! watch_actions_parse_rule_line "${cfg_line}"; then
      githooks_log_warn "watch-configured-actions example: rule skipped while parsing ${config_path}"
    fi
  done <"${config_tmp}"
  rm -f "${config_tmp}"
  return 0
}

watch_actions_load_inline_rules() {
  if [ "$#" -ne 1 ]; then
    return 1
  fi
  inline_source=$1
  current_name=""
  current_patterns=""
  current_commands=""
  current_continue="false"
  before_count=${WATCH_ACTIONS_RULE_COUNT}
  inline_tmp=$(mktemp "${TMPDIR:-/tmp}/githooks-watch-inline.XXXXXX") || return 1
  printf '%s\n' "${inline_source}" >"${inline_tmp}"

  watch_actions_inline_flush() {
    if [ -z "${current_patterns}" ]; then
      current_name=""
      current_patterns=""
      current_commands=""
      current_continue="false"
      return 0
    fi
    if [ -z "${current_name}" ]; then
      current_name="inline-${WATCH_ACTIONS_RULE_COUNT}"
    fi
    watch_actions_append_rule "${current_name}" "${current_patterns}" "${current_commands}" "${current_continue}"
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
    line=$(watch_actions_trim "${raw_line}")
    if [ "${GITHOOKS_WATCH_DEBUG:-0}" = "1" ]; then
      githooks_log_info "watch-configured-actions debug: inline line='${line}'"
    fi
    [ -n "${line}" ] || { watch_actions_inline_flush; continue; }
    case "${line}" in
      \#*) continue ;;
      name=*)
        current_name=$(watch_actions_trim "${line#name=}")
        ;;
      patterns=*)
        value=$(watch_actions_trim "${line#patterns=}")
        value=$(printf '%s' "${value}" | tr ',' "${WATCH_ACTIONS_DELIM_PATTERN}")
        current_patterns="${value}"
        ;;
      commands=*)
        cmd=$(watch_actions_trim "${line#commands=}")
        if [ -n "${current_commands}" ]; then
          current_commands="${current_commands}${WATCH_ACTIONS_DELIM_COMMAND}${cmd}"
        else
          current_commands="${cmd}"
        fi
        ;;
      continue_on_error=*)
        val=$(watch_actions_trim "${line#continue_on_error=}")
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
  watch_actions_inline_flush
  if [ "${WATCH_ACTIONS_RULE_COUNT}" -le "${before_count}" ]; then
    githooks_log_warn "watch-configured-actions example: inline rules provided but none parsed"
    return 1
  fi
  return 0
}

watch_actions_select_config_path() {
  candidate=${GITHOOKS_WATCH_CONFIG:-}
  if [ -n "${candidate}" ]; then
    case "${candidate}" in
      /*) maybe_path=${candidate} ;;
      *) maybe_path="${WATCH_ACTIONS_REPO_ROOT%/}/${candidate}" ;;
    esac
    if [ -f "${maybe_path}" ]; then
      WATCH_ACTIONS_SELECTED_CONFIG="${maybe_path}"
      WATCH_ACTIONS_CONFIG_SOURCE="override"
      return 0
    fi
    githooks_log_warn "watch-configured-actions example: configured path ${maybe_path} not found"
  fi

  for base in watch-configured-actions watch-config; do
    for ext in yml yaml json; do
      central_candidate="${WATCH_ACTIONS_CENTRAL_DIR}/${base}.${ext}"
      if [ -f "${central_candidate}" ]; then
        WATCH_ACTIONS_SELECTED_CONFIG="${central_candidate}"
        WATCH_ACTIONS_CONFIG_SOURCE="central"
        return 0
      fi
    done
  done

  for legacy in \
    "${WATCH_ACTIONS_REPO_ROOT}/.githooks/watch-configured-actions.yml" \
    "${WATCH_ACTIONS_REPO_ROOT}/.githooks/watch-configured-actions.yaml" \
    "${WATCH_ACTIONS_REPO_ROOT}/.githooks/watch-configured-actions.json" \
    "${WATCH_ACTIONS_REPO_ROOT}/.githooks/watch-config.yml" \
    "${WATCH_ACTIONS_REPO_ROOT}/.githooks/watch-config.yaml" \
    "${WATCH_ACTIONS_REPO_ROOT}/.githooks/watch-config.json"; do
    if [ -f "${legacy}" ]; then
      if [ "${WATCH_ACTIONS_LEGACY_NOTICE_EMITTED}" -eq 0 ]; then
        githooks_log_warn "watch-configured-actions example: using legacy config path ${legacy}; migrate to ${WATCH_ACTIONS_CENTRAL_HINT}"
        WATCH_ACTIONS_LEGACY_NOTICE_EMITTED=1
      fi
      WATCH_ACTIONS_SELECTED_CONFIG="${legacy}"
      WATCH_ACTIONS_CONFIG_SOURCE="legacy"
      return 0
    fi
  done

  WATCH_ACTIONS_SELECTED_CONFIG=""
  WATCH_ACTIONS_CONFIG_SOURCE="none"
  return 1
}

watch_actions_execute_rules() {
  if ! grep -q '.' "${WATCH_ACTIONS_CHANGED_FILE_LOG}" 2>/dev/null; then
    githooks_log_info "watch-configured-actions example: no tracked changes detected for ${WATCH_ACTIONS_HOOK_NAME}"
    watch_actions_write_mark_file
    return 0
  fi

  config_loaded=0
  if watch_actions_select_config_path; then
    if watch_actions_load_config_rules "${WATCH_ACTIONS_SELECTED_CONFIG}"; then
      config_loaded=1
    else
      load_status=$?
      case "${load_status}" in
        2)
          if [ -n "${WATCH_ACTIONS_CONFIG_LOAD_DIAG}" ]; then
            githooks_log_info "watch-configured-actions example: continuing without central config (${WATCH_ACTIONS_CONFIG_LOAD_DIAG})"
          fi
          ;;
        *)
          watch_actions_write_mark_file
          return 1
          ;;
      esac
    fi
  fi

  if [ "${config_loaded}" -eq 0 ]; then
    inline_rules=${WATCH_INLINE_RULES:-${WATCH_INLINE_RULES_DEFAULT:-}}
    if [ -n "${inline_rules}" ] && watch_actions_load_inline_rules "${inline_rules}"; then
      config_loaded=1
    fi
  fi

  if [ "${config_loaded}" -eq 0 ] || [ "${WATCH_ACTIONS_RULE_COUNT}" -eq 0 ]; then
    githooks_log_info "watch-configured-actions example: no rules configured; place config at ${WATCH_ACTIONS_CENTRAL_HINT}"
    watch_actions_write_mark_file
    return 0
  fi

  if [ "${GITHOOKS_WATCH_DEBUG:-0}" = "1" ]; then
    githooks_log_info "watch-configured-actions debug: loaded ${WATCH_ACTIONS_RULE_COUNT} rule(s)"
  fi

  index=1
  while [ "${index}" -le "${WATCH_ACTIONS_RULE_COUNT}" ]; do
    rule_name=$(sed -n "${index}p" "${WATCH_ACTIONS_RULE_NAMES_FILE}" 2>/dev/null || printf '')
    pattern_set=$(sed -n "${index}p" "${WATCH_ACTIONS_RULE_PATTERNS_FILE}" 2>/dev/null || printf '')
    command_set=$(sed -n "${index}p" "${WATCH_ACTIONS_RULE_COMMANDS_FILE}" 2>/dev/null || printf '')
    continue_flag=$(sed -n "${index}p" "${WATCH_ACTIONS_RULE_CONTINUES_FILE}" 2>/dev/null || printf 'false')
    [ -n "${rule_name}" ] || rule_name="rule-${index}"

    match_count=0
    first_match=""

    saved_ifs=$IFS
    IFS=${WATCH_ACTIONS_DELIM_PATTERN}
    set -- dummy ${pattern_set}
    shift
    IFS=${saved_ifs}
    for pattern in "$@"; do
      pattern=$(watch_actions_trim "${pattern}")
      [ -n "${pattern}" ] || continue
      regex=$(watch_actions_pattern_to_regex "${pattern}" 2>/dev/null || printf '')
      [ -n "${regex}" ] || continue
      matches=$(grep -E "${regex}" "${WATCH_ACTIONS_CHANGED_FILE_LOG}" 2>/dev/null || printf '')
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

    WATCH_ACTIONS_TRIGGERED=1
    if [ -z "${first_match}" ]; then
      first_match=$(head -n 1 "${WATCH_ACTIONS_CHANGED_FILE_LOG}")
    fi
    watch_actions_record_trigger "${rule_name}: ${first_match}"

    saved_ifs=$IFS
    IFS=${WATCH_ACTIONS_DELIM_COMMAND}
    set -- dummy ${command_set}
    shift
    IFS=${saved_ifs}

    if [ "$#" -eq 0 ] || [ -z "${1-}" ]; then
      githooks_log_info "watch-configured-actions example: ${rule_name} matched (${first_match}) but no commands configured"
      index=$((index + 1))
      continue
    fi

    githooks_log_info "watch-configured-actions example: ${rule_name} matched (${first_match}); running configured commands"

    command_failed=0
    for command_entry in "$@"; do
      command_entry=$(watch_actions_trim "${command_entry}")
      [ -n "${command_entry}" ] || continue
      command_entry=$(watch_actions_unescape_newlines "${command_entry}")
      githooks_log_info "watch-configured-actions example: executing (${rule_name}) -> ${command_entry}"
    if sh -c "${command_entry}"; then
      :
    else
      status=$?
      command_failed=1
      watch_actions_record_trigger "${rule_name}: command failed (${command_entry}) status=${status}"
      if [ "${continue_flag}" = "true" ]; then
        WATCH_ACTIONS_FAIL_STATUS=$((WATCH_ACTIONS_FAIL_STATUS | status))
        githooks_log_warn "watch-configured-actions example: command failed with exit ${status} (continue_on_error=true)"
        continue
      fi
      githooks_log_error "watch-configured-actions example: command failed with exit ${status}"
      watch_actions_write_mark_file
      return "${status}"
    fi
    done

    if [ "${command_failed}" -eq 0 ]; then
      watch_actions_record_trigger "${rule_name}: commands completed"
    fi

    index=$((index + 1))
  done

  watch_actions_write_mark_file

  if [ "${WATCH_ACTIONS_FAIL_STATUS}" -ne 0 ]; then
    return 0
  fi

  if [ "${WATCH_ACTIONS_TRIGGERED}" -eq 0 ]; then
    githooks_log_info "watch-configured-actions example: no automation matched configured patterns"
  fi

  return 0
}

watch_actions_run_post_event() {
  if [ "$#" -lt 1 ]; then
    githooks_die "watch_actions_run_post_event expects hook name"
  fi
  hook_name=$1
  shift
  watch_actions_init "${hook_name}"
  watch_actions_collect_post_event_changes "${hook_name}" "$@"
  watch_actions_execute_rules
}

watch_actions_run_pre_commit() {
  if [ "$#" -lt 1 ]; then
    githooks_die "watch_actions_run_pre_commit expects hook name"
  fi
  hook_name=$1
  shift
  watch_actions_init "${hook_name}"
  watch_actions_collect_pre_commit_changes "$@"
  watch_actions_execute_rules
}
