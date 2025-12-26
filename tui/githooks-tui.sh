#!/bin/sh
# POSIX-compliant TUI wrapper for the git hooks runner toolkit.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
ROOT_DIR=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd -P)
INSTALL_SH="${ROOT_DIR}/install.sh"

if [ ! -f "${INSTALL_SH}" ]; then
  printf 'ERROR: install.sh not found at %s\n' "${INSTALL_SH}" >&2
  exit 1
fi
if [ ! -x "${INSTALL_SH}" ]; then
  printf 'ERROR: install.sh is not executable: %s\n' "${INSTALL_SH}" >&2
  exit 1
fi

TOOLKIT_VERSION=$(${INSTALL_SH} -V 2>/dev/null || printf 'githooks-runner unknown')
DEFAULT_MODE="standard"
DEFAULT_OVERLAY="ephemeral-first"
DRY_RUN=0

DEFAULT_HOOKS=$(sed -n 's/^DEFAULT_HOOKS="\([^"]*\)".*/\1/p' "${INSTALL_SH}" | head -n 1)
ALL_HOOKS=$(sed -n 's/^ALL_HOOKS="\([^"]*\)".*/\1/p' "${INSTALL_SH}" | head -n 1)

if [ -z "${DEFAULT_HOOKS}" ]; then
  DEFAULT_HOOKS="(unknown)"
fi
if [ -z "${ALL_HOOKS}" ]; then
  ALL_HOOKS="(unknown)"
fi

usage() {
  cat <<'HELP'
Git Hooks Runner Toolkit - TUI

Usage:
  tui/githooks-tui.sh

Options:
  -h, --help     Show this message.
  -V, --version  Show toolkit version.
HELP
}

clear_screen() {
  if command -v tput >/dev/null 2>&1; then
    tput clear >/dev/null 2>&1 || printf '\n\n\n\n\n\n\n\n\n\n'
  else
    printf '\n\n\n\n\n\n\n\n\n\n'
  fi
}

pause() {
  printf '\nPress Enter to continue...'
  if ! IFS= read -r _pause; then
    printf '\n' >&2
    exit 1
  fi
}

prompt() {
  _prompt=$1
  _default=${2-}
  if [ -n "${_default}" ]; then
    printf '%s [%s]: ' "${_prompt}" "${_default}"
  else
    printf '%s: ' "${_prompt}"
  fi
  _reply=''
  if ! IFS= read -r _reply; then
    printf '\n' >&2
    exit 1
  fi
  if [ -z "${_reply}" ] && [ -n "${_default}" ]; then
    printf '%s' "${_default}"
  else
    printf '%s' "${_reply}"
  fi
}

confirm() {
  _prompt=$1
  _default=${2-y}
  while :; do
    _reply=$(prompt "${_prompt} (y/n)" "${_default}")
    case "${_reply}" in
      y|Y)
        return 0
        ;;
      n|N)
        return 1
        ;;
      *)
        printf 'Please enter y or n.\n'
        ;;
    esac
  done
}

format_onoff() {
  if [ "$1" -eq 1 ]; then
    printf 'on'
  else
    printf 'off'
  fi
}

format_cmd() {
  _cmd=''
  for _arg in "$@"; do
    case "${_arg}" in
      *[!A-Za-z0-9_./-]*)
        _escaped=$(printf '%s' "${_arg}" | sed 's/"/\\"/g')
        _cmd="${_cmd} \"${_escaped}\""
        ;;
      *)
        _cmd="${_cmd} ${_arg}"
        ;;
    esac
  done
  printf '%s' "${_cmd# }"
}

show_header() {
  printf 'Git Hooks Runner Toolkit TUI\n'
  printf '%s\n' "${TOOLKIT_VERSION}"
  printf 'Repo: %s\n' "${ROOT_DIR}"
  printf 'Settings: mode=%s overlay=%s dry-run=%s\n' \
    "${DEFAULT_MODE}" "${DEFAULT_OVERLAY}" "$(format_onoff "${DRY_RUN}")"
}

print_known_hooks() {
  printf '\nDefault hooks: %s\n' "${DEFAULT_HOOKS}"
  printf 'All hooks: %s\n\n' "${ALL_HOOKS}"
}

prompt_hook_list() {
  _label=$1
  _default=${2-}
  while :; do
    _reply=$(prompt "${_label} (? to list hooks)" "${_default}")
    case "${_reply}" in
      \?)
        print_known_hooks
        ;;
      *)
        printf '%s' "${_reply}"
        return 0
        ;;
    esac
  done
}

prompt_hook_single() {
  _label=$1
  while :; do
    _reply=$(prompt "${_label} (? to list hooks)" "")
    case "${_reply}" in
      \?)
        print_known_hooks
        ;;
      *)
        printf '%s' "${_reply}"
        return 0
        ;;
    esac
  done
}

select_mode() {
  _default=$1
  while :; do
    _reply=$(prompt 'Mode (standard/ephemeral)' "${_default}")
    case "${_reply}" in
      standard|ephemeral)
        printf '%s' "${_reply}"
        return 0
        ;;
      *)
        printf 'Invalid mode. Use standard or ephemeral.\n'
        ;;
    esac
  done
}

select_overlay() {
  _default=$1
  while :; do
    _reply=$(prompt 'Overlay (ephemeral-first/versioned-first/merge)' "${_default}")
    case "${_reply}" in
      ephemeral-first|versioned-first|merge)
        printf '%s' "${_reply}"
        return 0
        ;;
      *)
        printf 'Invalid overlay. Use ephemeral-first, versioned-first, or merge.\n'
        ;;
    esac
  done
}

run_cmd() {
  _display=$1
  shift
  printf '\nCommand: %s\n' "${_display}"
  if confirm 'Run command now?' 'y'; then
    (cd "${ROOT_DIR}" && "$@")
  else
    printf 'Cancelled.\n'
  fi
  pause
}

run_help() {
  _display=$1
  shift
  printf '\nHelp: %s\n\n' "${_display}"
  (cd "${ROOT_DIR}" && "$@")
  pause
}

menu_settings() {
  while :; do
    clear_screen
    show_header
    printf '\nSettings\n'
    printf '1) Toggle dry-run (currently: %s)\n' "$(format_onoff "${DRY_RUN}")"
    printf '2) Set default mode (currently: %s)\n' "${DEFAULT_MODE}"
    printf '3) Set default overlay (currently: %s)\n' "${DEFAULT_OVERLAY}"
    printf '4) Back\n'
    _choice=$(prompt 'Select option' '4')
    case "${_choice}" in
      1|dry-run|dryrun)
        if [ "${DRY_RUN}" -eq 1 ]; then
          DRY_RUN=0
        else
          DRY_RUN=1
        fi
        ;;
      2|mode)
        DEFAULT_MODE=$(select_mode "${DEFAULT_MODE}")
        ;;
      3|overlay)
        DEFAULT_OVERLAY=$(select_overlay "${DEFAULT_OVERLAY}")
        ;;
      4|back|b)
        return 0
        ;;
      *)
        printf 'Invalid selection.\n'
        pause
        ;;
    esac
  done
}

menu_install() {
  clear_screen
  show_header
  printf '\nInstall\n'
  _mode=$(select_mode "${DEFAULT_MODE}")

  printf '\nHook selection:\n'
  printf '1) Default curated hooks (%s)\n' "${DEFAULT_HOOKS}"
  printf '2) All Git hooks\n'
  printf '3) Custom list\n'
  _choice=$(prompt 'Select hook set' '1')

  _use_all=0
  _custom_hooks=''
  case "${_choice}" in
    1|default|d)
      ;;
    2|all|a)
      _use_all=1
      ;;
    3|custom|c)
      _custom_hooks=$(prompt_hook_list 'Custom hooks (comma-separated)' '')
      if [ -z "${_custom_hooks}" ]; then
        printf 'No hooks provided; cancelling install.\n'
        pause
        return 0
      fi
      ;;
    *)
      printf 'Invalid selection; cancelling install.\n'
      pause
      return 0
      ;;
  esac

  _overlay=''
  if [ "${_mode}" = 'ephemeral' ]; then
    _overlay=$(select_overlay "${DEFAULT_OVERLAY}")
  fi

  if confirm 'Overwrite existing stubs? (--force)' 'n'; then
    _force=1
  else
    _force=0
  fi

  set -- install
  if [ "${_use_all}" -eq 1 ]; then
    set -- "$@" --all-hooks
  fi
  if [ -n "${_custom_hooks}" ]; then
    set -- "$@" --hooks "${_custom_hooks}"
  fi
  if [ -n "${_overlay}" ]; then
    set -- "$@" --overlay "${_overlay}"
  fi
  if [ "${_force}" -eq 1 ]; then
    set -- "$@" --force
  fi

  if [ "${DRY_RUN}" -eq 1 ]; then
    set -- --dry-run "$@"
  fi
  if [ "${_mode}" != 'standard' ]; then
    set -- --mode "${_mode}" "$@"
  fi

  _display=$(format_cmd githooks "$@")
  run_cmd "${_display}" "${INSTALL_SH}" "$@"
}

menu_update() {
  clear_screen
  show_header
  printf '\nUpdate\n'
  _mode=$(select_mode "${DEFAULT_MODE}")

  if confirm 'Overwrite staged parts even if identical? (--force)' 'n'; then
    _force=1
  else
    _force=0
  fi

  while :; do
    _refresh=$(prompt 'Refresh configs? (auto/yes/no)' 'auto')
    case "${_refresh}" in
      auto|a|AUTO)
        _refresh_flag=''
        break
        ;;
      yes|y|YES)
        _refresh_flag='--refresh-configs'
        break
        ;;
      no|n|NO)
        _refresh_flag='--no-refresh-configs'
        break
        ;;
      *)
        printf 'Invalid choice. Use auto, yes, or no.\n'
        ;;
    esac
  done

  set -- update
  if [ "${_force}" -eq 1 ]; then
    set -- "$@" --force
  fi
  if [ -n "${_refresh_flag}" ]; then
    set -- "$@" "${_refresh_flag}"
  fi

  if [ "${DRY_RUN}" -eq 1 ]; then
    set -- --dry-run "$@"
  fi
  if [ "${_mode}" != 'standard' ]; then
    set -- --mode "${_mode}" "$@"
  fi

  _display=$(format_cmd githooks "$@")
  run_cmd "${_display}" "${INSTALL_SH}" "$@"
}

menu_stage_add() {
  clear_screen
  show_header
  printf '\nStage Add\n'
  _source=$(prompt 'Source directory' 'examples')
  if [ -z "${_source}" ]; then
    printf 'No source provided; cancelling.\n'
    pause
    return 0
  fi
  _hook_filter=$(prompt_hook_list 'Hook filter (comma-separated, blank for all)' '')
  _name_filter=$(prompt 'Name patterns (comma-separated, blank for all)' '')
  if confirm 'Overwrite staged scripts? (--force)' 'n'; then
    _force=1
  else
    _force=0
  fi

  set -- stage add "${_source}"
  if [ -n "${_hook_filter}" ]; then
    set -- "$@" --hook "${_hook_filter}"
  fi
  if [ -n "${_name_filter}" ]; then
    set -- "$@" --name "${_name_filter}"
  fi
  if [ "${_force}" -eq 1 ]; then
    set -- "$@" --force
  fi

  if [ "${DRY_RUN}" -eq 1 ]; then
    set -- --dry-run "$@"
  fi
  if [ "${DEFAULT_MODE}" != 'standard' ]; then
    set -- --mode "${DEFAULT_MODE}" "$@"
  fi

  _display=$(format_cmd githooks "$@")
  run_cmd "${_display}" "${INSTALL_SH}" "$@"
}

menu_stage_unstage() {
  clear_screen
  show_header
  printf '\nStage Unstage\n'
  _source=$(prompt 'Source directory' 'examples')
  if [ -z "${_source}" ]; then
    printf 'No source provided; cancelling.\n'
    pause
    return 0
  fi
  _hook_filter=$(prompt_hook_list 'Hook filter (comma-separated, blank for all)' '')
  _name_filter=$(prompt 'Name patterns (comma-separated, blank for all)' '')

  set -- stage unstage "${_source}"
  if [ -n "${_hook_filter}" ]; then
    set -- "$@" --hook "${_hook_filter}"
  fi
  if [ -n "${_name_filter}" ]; then
    set -- "$@" --name "${_name_filter}"
  fi

  if [ "${DRY_RUN}" -eq 1 ]; then
    set -- --dry-run "$@"
  fi
  if [ "${DEFAULT_MODE}" != 'standard' ]; then
    set -- --mode "${DEFAULT_MODE}" "$@"
  fi

  _display=$(format_cmd githooks "$@")
  run_cmd "${_display}" "${INSTALL_SH}" "$@"
}

menu_stage_remove() {
  clear_screen
  show_header
  printf '\nStage Remove\n'
  _hook=$(prompt_hook_single 'Hook to remove from')
  if [ -z "${_hook}" ]; then
    printf 'No hook provided; cancelling.\n'
    pause
    return 0
  fi

  if confirm "Remove ALL staged scripts for ${_hook}?" 'n'; then
    set -- stage remove "${_hook}" --all
  else
    _part=$(prompt 'Part name to remove (without .sh)' '')
    if [ -z "${_part}" ]; then
      printf 'No part provided; cancelling.\n'
      pause
      return 0
    fi
    set -- stage remove "${_hook}" --name "${_part}"
  fi

  if [ "${DRY_RUN}" -eq 1 ]; then
    set -- --dry-run "$@"
  fi
  if [ "${DEFAULT_MODE}" != 'standard' ]; then
    set -- --mode "${DEFAULT_MODE}" "$@"
  fi

  _display=$(format_cmd githooks "$@")
  run_cmd "${_display}" "${INSTALL_SH}" "$@"
}

menu_stage_list() {
  clear_screen
  show_header
  printf '\nStage List\n'
  _hook=$(prompt_hook_single 'Hook (blank for all)')

  set -- stage list
  if [ -n "${_hook}" ]; then
    set -- "$@" "${_hook}"
  fi

  if [ "${DRY_RUN}" -eq 1 ]; then
    set -- --dry-run "$@"
  fi
  if [ "${DEFAULT_MODE}" != 'standard' ]; then
    set -- --mode "${DEFAULT_MODE}" "$@"
  fi

  _display=$(format_cmd githooks "$@")
  run_cmd "${_display}" "${INSTALL_SH}" "$@"
}

menu_stage() {
  while :; do
    clear_screen
    show_header
    printf '\nStage\n'
    printf '1) Add\n'
    printf '2) Unstage\n'
    printf '3) Remove\n'
    printf '4) List\n'
    printf '5) Back\n'
    _choice=$(prompt 'Select option' '5')
    case "${_choice}" in
      1|add)
        menu_stage_add
        ;;
      2|unstage)
        menu_stage_unstage
        ;;
      3|remove)
        menu_stage_remove
        ;;
      4|list)
        menu_stage_list
        ;;
      5|back|b)
        return 0
        ;;
      *)
        printf 'Invalid selection.\n'
        pause
        ;;
    esac
  done
}

menu_hooks_list() {
  clear_screen
  show_header
  printf '\nHooks List\n'
  _hook=$(prompt_hook_single 'Hook (blank for all)')

  set -- hooks list
  if [ -n "${_hook}" ]; then
    set -- "$@" "${_hook}"
  fi

  if [ "${DRY_RUN}" -eq 1 ]; then
    set -- --dry-run "$@"
  fi
  if [ "${DEFAULT_MODE}" != 'standard' ]; then
    set -- --mode "${DEFAULT_MODE}" "$@"
  fi

  _display=$(format_cmd githooks "$@")
  run_cmd "${_display}" "${INSTALL_SH}" "$@"
}

menu_hooks() {
  while :; do
    clear_screen
    show_header
    printf '\nHooks\n'
    printf '1) List\n'
    printf '2) Back\n'
    _choice=$(prompt 'Select option' '2')
    case "${_choice}" in
      1|list)
        menu_hooks_list
        ;;
      2|back|b)
        return 0
        ;;
      *)
        printf 'Invalid selection.\n'
        pause
        ;;
    esac
  done
}

menu_config_show() {
  clear_screen
  show_header
  printf '\nConfig Show\n'
  set -- config show

  if [ "${DRY_RUN}" -eq 1 ]; then
    set -- --dry-run "$@"
  fi
  if [ "${DEFAULT_MODE}" != 'standard' ]; then
    set -- --mode "${DEFAULT_MODE}" "$@"
  fi

  _display=$(format_cmd githooks "$@")
  run_cmd "${_display}" "${INSTALL_SH}" "$@"
}

menu_config_set() {
  clear_screen
  show_header
  printf '\nConfig Set\n'
  _path=$(prompt 'hooks-path value' '')
  if [ -z "${_path}" ]; then
    printf 'No path provided; cancelling.\n'
    pause
    return 0
  fi

  set -- config set hooks-path "${_path}"

  if [ "${DRY_RUN}" -eq 1 ]; then
    set -- --dry-run "$@"
  fi
  if [ "${DEFAULT_MODE}" != 'standard' ]; then
    set -- --mode "${DEFAULT_MODE}" "$@"
  fi

  _display=$(format_cmd githooks "$@")
  run_cmd "${_display}" "${INSTALL_SH}" "$@"
}

menu_config() {
  while :; do
    clear_screen
    show_header
    printf '\nConfig\n'
    printf '1) Show\n'
    printf '2) Set hooks-path\n'
    printf '3) Back\n'
    _choice=$(prompt 'Select option' '3')
    case "${_choice}" in
      1|show)
        menu_config_show
        ;;
      2|set)
        menu_config_set
        ;;
      3|back|b)
        return 0
        ;;
      *)
        printf 'Invalid selection.\n'
        pause
        ;;
    esac
  done
}

menu_uninstall() {
  clear_screen
  show_header
  printf '\nUninstall\n'
  _mode=$(select_mode "${DEFAULT_MODE}")

  set -- uninstall

  if [ "${DRY_RUN}" -eq 1 ]; then
    set -- --dry-run "$@"
  fi
  if [ "${_mode}" != 'standard' ]; then
    set -- --mode "${_mode}" "$@"
  fi

  _display=$(format_cmd githooks "$@")
  run_cmd "${_display}" "${INSTALL_SH}" "$@"
}

menu_help() {
  while :; do
    clear_screen
    show_header
    printf '\nHelp\n'
    printf '1) Overview\n'
    printf '2) Install\n'
    printf '3) Update\n'
    printf '4) Stage\n'
    printf '5) Stage add\n'
    printf '6) Stage unstage\n'
    printf '7) Stage remove\n'
    printf '8) Stage list\n'
    printf '9) Hooks\n'
    printf '10) Hooks list\n'
    printf '11) Config\n'
    printf '12) Config show\n'
    printf '13) Config set\n'
    printf '14) Uninstall\n'
    printf '15) Back\n'
    _choice=$(prompt 'Select option' '15')
    case "${_choice}" in
      1|overview)
        run_help 'githooks help' "${INSTALL_SH}" help
        ;;
      2|install)
        run_help 'githooks help install' "${INSTALL_SH}" help install
        ;;
      3|update)
        run_help 'githooks help update' "${INSTALL_SH}" help update
        ;;
      4|stage)
        run_help 'githooks help stage' "${INSTALL_SH}" help stage
        ;;
      5|stage-add|add)
        run_help 'githooks stage help add' "${INSTALL_SH}" stage help add
        ;;
      6|stage-unstage|unstage)
        run_help 'githooks stage help unstage' "${INSTALL_SH}" stage help unstage
        ;;
      7|stage-remove|remove)
        run_help 'githooks stage help remove' "${INSTALL_SH}" stage help remove
        ;;
      8|stage-list|list)
        run_help 'githooks stage help list' "${INSTALL_SH}" stage help list
        ;;
      9|hooks)
        run_help 'githooks help hooks' "${INSTALL_SH}" help hooks
        ;;
      10|hooks-list)
        run_help 'githooks hooks help list' "${INSTALL_SH}" hooks help list
        ;;
      11|config)
        run_help 'githooks help config' "${INSTALL_SH}" help config
        ;;
      12|config-show)
        run_help 'githooks config help show' "${INSTALL_SH}" config help show
        ;;
      13|config-set)
        run_help 'githooks config help set' "${INSTALL_SH}" config help set
        ;;
      14|uninstall)
        run_help 'githooks help uninstall' "${INSTALL_SH}" help uninstall
        ;;
      15|back|b)
        return 0
        ;;
      *)
        printf 'Invalid selection.\n'
        pause
        ;;
    esac
  done
}

main_menu() {
  while :; do
    clear_screen
    show_header
    printf '\nMain Menu\n'
    printf '1) Install\n'
    printf '2) Update\n'
    printf '3) Stage\n'
    printf '4) Hooks\n'
    printf '5) Config\n'
    printf '6) Uninstall\n'
    printf '7) Help\n'
    printf '8) Settings\n'
    printf '9) Exit\n'
    _choice=$(prompt 'Select option')
    case "${_choice}" in
      1|install)
        menu_install
        ;;
      2|update)
        menu_update
        ;;
      3|stage)
        menu_stage
        ;;
      4|hooks)
        menu_hooks
        ;;
      5|config)
        menu_config
        ;;
      6|uninstall)
        menu_uninstall
        ;;
      7|help)
        menu_help
        ;;
      8|settings)
        menu_settings
        ;;
      9|exit|quit|q)
        printf 'Goodbye.\n'
        exit 0
        ;;
      *)
        printf 'Invalid selection.\n'
        pause
        ;;
    esac
  done
}

case "${1-}" in
  -h|--help)
    usage
    exit 0
    ;;
  -V|--version)
    printf '%s\n' "${TOOLKIT_VERSION}"
    exit 0
    ;;
  '')
    ;;
  *)
    printf 'Unknown option: %s\n' "${1}" >&2
    usage >&2
    exit 1
    ;;
 esac

main_menu
