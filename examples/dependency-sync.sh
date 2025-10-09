#!/bin/sh
# githooks-stage: post-merge post-rewrite post-checkout post-commit
# Example hook part: detect dependency file changes and run matching installers.
# Intended for post-merge/post-rewrite/post-checkout hooks under the shared runner.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
LIB_PATH="${SCRIPT_DIR}/../lib/common.sh"
if [ ! -f "${LIB_PATH}" ]; then
  printf '[hook-runner] ERROR: dependency-sync helper missing common library at %s\n' "${LIB_PATH}" >&2
  exit 1
fi
# shellcheck source=scripts/.githooks/lib/common.sh
. "${LIB_PATH}"

if githooks_is_bare_repo; then
  githooks_log_info "dependency-sync example not applicable to bare repositories"
  exit 0
fi

REPO_ROOT=$(githooks_repo_top)
cd "${REPO_ROOT}" || exit 1

HOOK_NAME=${GITHOOKS_HOOK_NAME:-$(basename "${0:-dependency-sync}")}
HOOK_ARG1=${1-}
HOOK_ARG2=${2-}
HOOK_ARG3=${3-}

CHANGED_FILE_LOG=$(mktemp "${TMPDIR:-/tmp}/githooks-change-files.XXXXXX") || exit 1
TRIGGER_NOTE_LOG=$(mktemp "${TMPDIR:-/tmp}/githooks-change-notes.XXXXXX") || exit 1
TRIGGER_DESC_LOG=$(mktemp "${TMPDIR:-/tmp}/githooks-change-descriptions.XXXXXX") || exit 1

cleanup_logs() {
  rm -f "${CHANGED_FILE_LOG}" "${TRIGGER_NOTE_LOG}" "${TRIGGER_DESC_LOG}"
}
trap cleanup_logs EXIT HUP INT TERM

TRIGGERED=0

append_paths_from_diff() {
  "$@" 2>/dev/null | while IFS= read -r change_path; do
    [ -n "${change_path}" ] || continue
    printf '%s\n' "${change_path}" >>"${CHANGED_FILE_LOG}"
  done
}

collect_changed_files() {
  case "${HOOK_NAME}" in
    post-merge)
      if git rev-parse --verify ORIG_HEAD >/dev/null 2>&1; then
        append_paths_from_diff git diff-tree -r --name-only --no-commit-id ORIG_HEAD HEAD
      fi
      ;;
    post-rewrite)
      map_file=${GITHOOKS_STDIN_FILE:-}
      have_maps=0
      if [ -n "${map_file}" ] && [ -s "${map_file}" ]; then
        while IFS= read -r map_line; do
          set -- ${map_line}
          old_ref=$1
          new_ref=$2
          if [ -n "${old_ref}" ] && [ -n "${new_ref}" ]; then
            have_maps=1
            append_paths_from_diff git diff --name-only "${old_ref}" "${new_ref}"
          fi
        done <"${map_file}"
      fi
      if [ "${have_maps}" -eq 0 ]; then
        if git rev-parse --verify ORIG_HEAD >/dev/null 2>&1; then
          append_paths_from_diff git diff --name-only ORIG_HEAD HEAD
        fi
        if [ ! -s "${CHANGED_FILE_LOG}" ] && git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
          append_paths_from_diff git diff --name-only HEAD~1 HEAD
        fi
      fi
      ;;
    post-checkout)
      old_ref=${HOOK_ARG1}
      new_ref=${HOOK_ARG2}
      checkout_flag=${HOOK_ARG3}
      if [ "${checkout_flag}" = "1" ] && [ -n "${old_ref}" ] && [ -n "${new_ref}" ]; then
        append_paths_from_diff git diff-tree -r --name-only --no-commit-id "${old_ref}" "${new_ref}"
      fi
      ;;
    post-commit)
      if git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
        append_paths_from_diff git diff --name-only HEAD~1 HEAD
      else
        append_paths_from_diff git diff-tree -r --name-only --no-commit-id HEAD
      fi
      ;;
    *)
      githooks_log_info "dependency-sync example: hook ${HOOK_NAME} not handled; skipping"
      ;;
  esac
}

trim_pattern() {
  if [ "$#" -eq 0 ]; then
    return 0
  fi
  printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

any_changed_match() {
  patterns_csv=$1
  match_result=""
  saved_ifs=$IFS
  IFS=','
  set -f
  set -- ${patterns_csv}
  set +f
  IFS=$saved_ifs
  for lookup_pattern in "$@"; do
    trimmed_pattern=$(trim_pattern "${lookup_pattern}")
    [ -n "${trimmed_pattern}" ] || continue
    while IFS= read -r changed_path; do
      case "${changed_path}" in
        ${trimmed_pattern})
          match_result=${changed_path}
          printf '%s' "${match_result}"
          return 0
          ;;
      esac
    done <"${CHANGED_FILE_LOG}"
  done
  return 1
}

record_trigger_note() {
  printf '%s\n' "$1" >>"${TRIGGER_NOTE_LOG}"
}

description_already_triggered() {
  desc=$1
  if [ ! -f "${TRIGGER_DESC_LOG}" ]; then
    return 1
  fi
  if grep -Fxq -- "${desc}" "${TRIGGER_DESC_LOG}" 2>/dev/null; then
    return 0
  fi
  return 1
}

mark_description_triggered() {
  printf '%s\n' "$1" >>"${TRIGGER_DESC_LOG}"
}

run_if_changed() {
  patterns=$1
  shift
  description=$1
  shift
  if ! match=$(any_changed_match "${patterns}"); then
    return 0
  fi
  if description_already_triggered "${description}"; then
    record_trigger_note "${description}: ${match}"
    return 0
  fi
  if [ "$#" -eq 0 ]; then
    githooks_log_info "${description}: change detected (${match}), no command configured"
    TRIGGERED=1
    record_trigger_note "${description}: ${match}"
    mark_description_triggered "${description}"
    return 0
  fi
  command_name=$1
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    githooks_log_warn "${description}: optional tool '${command_name}' missing; skipping"
    record_trigger_note "${description}: ${match} (skipped; missing ${command_name})"
    mark_description_triggered "${description}"
    return 0
  fi
  GITHOOKS_DEPENDENCY_SYNC_MATCH=${match}
  export GITHOOKS_DEPENDENCY_SYNC_MATCH
  GITHOOKS_DEPENDENCY_SYNC_DESCRIPTION=${description}
  export GITHOOKS_DEPENDENCY_SYNC_DESCRIPTION
  githooks_log_info "${description}: change detected (${match}); running $*"
  mark_description_triggered "${description}"
  if ! "$@"; then
    status=$?
    githooks_log_error "${description}: command failed with exit ${status}"
    return "${status}"
  fi
  TRIGGERED=1
  record_trigger_note "${description}: ${match}"
  return 0
}

run_extra_dependency_recipes() {
  extra_recipes=${GITHOOKS_DEPENDENCY_SYNC_EXTRA_RECIPES:-}
  if [ -z "${extra_recipes}" ]; then
    return 0
  fi
  extra_recipes_log=$(mktemp "${TMPDIR:-/tmp}/githooks-extra-recipes.XXXXXX") || return 1
  printf '%s\n' "${extra_recipes}" >"${extra_recipes_log}"
  while IFS= read -r recipe_line; do
    trimmed_line=$(trim_pattern "${recipe_line}")
    [ -n "${trimmed_line}" ] || continue
    case "${trimmed_line}" in
      \#*) continue ;;
    esac
    patterns_part=${trimmed_line%%|*}
    rest_part=${trimmed_line#*|}
    if [ "${patterns_part}" = "${trimmed_line}" ] || [ -z "${rest_part}" ]; then
      continue
    fi
    description_part=${rest_part%%|*}
    command_part=${rest_part#*|}
    if [ "${description_part}" = "${rest_part}" ]; then
      command_part=""
    fi
    patterns_part=$(trim_pattern "${patterns_part}")
    description_part=$(trim_pattern "${description_part}")
    if [ -z "${patterns_part}" ] || [ -z "${description_part}" ]; then
      continue
    fi
    if [ -n "${command_part}" ]; then
      run_if_changed "${patterns_part}" "${description_part}" sh -c "${command_part}"
    else
      run_if_changed "${patterns_part}" "${description_part}"
    fi
  done <"${extra_recipes_log}"
  rm -f "${extra_recipes_log}"
}

record_mark_file() {
  mark_path=${GITHOOKS_DEPENDENCY_SYNC_MARK_FILE:-${GITHOOKS_CHANGE_MARK_FILE:-}}
  if [ -z "${mark_path}" ] || [ "${TRIGGERED}" -eq 0 ]; then
    return 0
  fi
  case "${mark_path}" in
    /*) ;;
    *) mark_path="${REPO_ROOT%/}/${mark_path}" ;;
  esac
  mark_dir=$(dirname "${mark_path}")
  mkdir -p "${mark_dir}"
  changed_count=$(grep -c '.' "${CHANGED_FILE_LOG}" || true)
  {
    printf 'hook=%s\n' "${HOOK_NAME}"
    while IFS= read -r note_line; do
      [ -n "${note_line}" ] || continue
      printf 'trigger=%s\n' "${note_line}"
    done <"${TRIGGER_NOTE_LOG}"
    printf 'changed-count=%s\n' "${changed_count}"
    while IFS= read -r changed_line; do
      [ -n "${changed_line}" ] || continue
      printf 'changed=%s\n' "${changed_line}"
    done <"${CHANGED_FILE_LOG}"
  } >"${mark_path}"
}

collect_changed_files

if ! grep -q '.' "${CHANGED_FILE_LOG}" 2>/dev/null; then
  githooks_log_info "dependency-sync example: no tracked changes detected for ${HOOK_NAME}"
  record_mark_file
  exit 0
fi

changed_total=$(grep -c '.' "${CHANGED_FILE_LOG}" || true)
githooks_log_info "dependency-sync example: evaluating ${changed_total} changed path(s)"

run_if_changed 'package-lock.json,npm-shrinkwrap.json,package.json' 'npm install' npm install --no-fund
run_if_changed 'yarn.lock' 'yarn install' yarn install --frozen-lockfile
run_if_changed 'pnpm-lock.yaml' 'pnpm install' pnpm install --frozen-lockfile
run_if_changed 'bun.lock,bun.lockb' 'bun install' bun install
run_if_changed 'composer.lock,composer.json' 'composer install' composer install --no-interaction --no-progress --quiet
run_if_changed 'requirements.txt,requirements-*.txt,requirements-dev.txt,dev-requirements.txt' 'pip install (requirements)' sh -c 'pip install -r "$GITHOOKS_DEPENDENCY_SYNC_MATCH"'
run_if_changed 'go.mod,go.sum' 'go mod download' go mod download
run_if_changed 'Cargo.lock,Cargo.toml' 'cargo fetch' cargo fetch
run_if_changed 'poetry.lock,pyproject.toml' 'poetry install' poetry install
run_if_changed 'Pipfile,Pipfile.lock' 'pipenv sync' pipenv sync
run_if_changed 'uv.lock,uv.toml' 'uv sync' uv sync
run_if_changed 'pdm.lock' 'pdm sync' pdm sync
run_if_changed 'environment.yml,environment.yaml' 'conda env update' sh -c 'conda env update --prune --file "$GITHOOKS_DEPENDENCY_SYNC_MATCH"'
run_if_changed 'Gemfile,Gemfile.lock,gems.rb,gems.locked' 'bundle install' bundle install --quiet
run_if_changed 'mix.lock,mix.exs' 'mix deps.get' mix deps.get
run_if_changed 'packages.lock.json,Directory.Packages.props,global.json,*.csproj,*.fsproj,*.vbproj' 'dotnet restore' dotnet restore
run_if_changed 'pom.xml,pom.lock' 'mvn dependency:resolve' mvn -B -q dependency:resolve
run_if_changed 'build.gradle,build.gradle.kts,settings.gradle,settings.gradle.kts,gradle.lockfile' 'gradle dependencies' sh -c 'if [ -x "./gradlew" ]; then ./gradlew --quiet dependencies; else gradle --quiet dependencies; fi'
run_if_changed 'Package.swift,Package.resolved' 'swift package resolve' swift package resolve
run_if_changed 'pubspec.yaml,pubspec.lock' 'dart pub get' dart pub get
run_if_changed 'Podfile,Podfile.lock' 'pod install' pod install

run_extra_dependency_recipes

record_mark_file

if [ "${TRIGGERED}" -eq 0 ]; then
  githooks_log_info "dependency-sync example: no automation matched configured patterns"
fi

exit 0
