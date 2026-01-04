#!/bin/sh
# POSIX-compliant TUI wrapper for the git hooks runner toolkit.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
ROOT_DIR=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd -P)
INSTALL_SH="${ROOT_DIR}/install.sh"
TARGET_DIR=$(pwd -P 2>/dev/null || pwd)

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
CARRIAGE_RETURN=$(printf '\r')

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

Notes:
  - The current working directory is treated as the target repository.
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
    printf '%s [%s]: ' "${_prompt}" "${_default}" >&2
  else
    printf '%s: ' "${_prompt}" >&2
  fi
  _reply=''
  if ! IFS= read -r _reply; then
    printf '\n' >&2
    exit 1
  fi
  _reply=$(printf '%s' "${_reply}" | tr -d "${CARRIAGE_RETURN}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
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
  printf 'Toolkit: %s\n' "${ROOT_DIR}"
  printf 'Target: %s\n' "${TARGET_DIR}"
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
      standard|STD|std|s|S)
        printf 'standard'
        return 0
        ;;
      ephemeral|E|e|epi|EPI)
        printf 'ephemeral'
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
      ephemeral-first|ephemeral|ef|EF)
        printf 'ephemeral-first'
        return 0
        ;;
      versioned-first|versioned|vf|VF)
        printf 'versioned-first'
        return 0
        ;;
      merge|m|M)
        printf 'merge'
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
    (cd "${TARGET_DIR}" && "$@")
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

help_page() {
  _title=$1
  clear_screen
  show_header
  printf '\n%s\n\n' "${_title}"
  # Read page body from FD 3 so callers can supply a heredoc without
  # consuming stdin (FD 0). This lets `pause` still read from the terminal.
  cat <&3
  pause
}

menu_help_manuals() {
  while :; do
    clear_screen
    show_header
    printf '\nCLI Manuals (MAN-style)\n'
    printf 'These are the exact help pages from `install.sh`.\n\n'
    printf '1) Overview\n'
    printf '2) Bootstrap\n'
    printf '3) Install\n'
    printf '4) Update\n'
    printf '5) Stage\n'
    printf '6) Stage add\n'
    printf '7) Stage unstage\n'
    printf '8) Stage remove\n'
    printf '9) Stage list\n'
    printf '10) Hooks\n'
    printf '11) Hooks list\n'
    printf '12) Config\n'
    printf '13) Config show\n'
    printf '14) Config set\n'
    printf '15) Uninstall\n'
    printf '16) Back\n'
    _choice=$(prompt 'Select option' '16')
    case "${_choice}" in
      1|overview)
        run_help 'githooks help' "${INSTALL_SH}" help
        ;;
      2|bootstrap)
        run_help 'githooks help bootstrap' "${INSTALL_SH}" help bootstrap
        ;;
      3|install)
        run_help 'githooks help install' "${INSTALL_SH}" help install
        ;;
      4|update)
        run_help 'githooks help update' "${INSTALL_SH}" help update
        ;;
      5|stage)
        run_help 'githooks help stage' "${INSTALL_SH}" help stage
        ;;
      6|stage-add|add)
        run_help 'githooks stage help add' "${INSTALL_SH}" stage help add
        ;;
      7|stage-unstage|unstage)
        run_help 'githooks stage help unstage' "${INSTALL_SH}" stage help unstage
        ;;
      8|stage-remove|remove)
        run_help 'githooks stage help remove' "${INSTALL_SH}" stage help remove
        ;;
      9|stage-list|list)
        run_help 'githooks stage help list' "${INSTALL_SH}" stage help list
        ;;
      10|hooks)
        run_help 'githooks help hooks' "${INSTALL_SH}" help hooks
        ;;
      11|hooks-list)
        run_help 'githooks hooks help list' "${INSTALL_SH}" hooks help list
        ;;
      12|config)
        run_help 'githooks help config' "${INSTALL_SH}" help config
        ;;
      13|config-show)
        run_help 'githooks config help show' "${INSTALL_SH}" config help show
        ;;
      14|config-set)
        run_help 'githooks config help set' "${INSTALL_SH}" config help set
        ;;
      15|uninstall)
        run_help 'githooks help uninstall' "${INSTALL_SH}" help uninstall
        ;;
      16|back|b)
        return 0
        ;;
      *)
        printf 'Invalid selection.\n'
        pause
        ;;
    esac
  done
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

menu_bootstrap() {
  clear_screen
  show_header
  printf '\nBootstrap\n'
  printf 'This copies the toolkit into .githooks/ (self-contained repo).\n'

  if confirm 'Overwrite existing .githooks toolkit? (--force)' 'n'; then
    _force=1
  else
    _force=0
  fi

  set -- bootstrap
  if [ "${_force}" -eq 1 ]; then
    set -- "$@" --force
  fi
  if [ "${DRY_RUN}" -eq 1 ]; then
    set -- --dry-run "$@"
  fi

  _display=$(format_cmd githooks "$@")
  run_cmd "${_display}" "${INSTALL_SH}" "$@"
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
    printf '1) Quick start (beginner)\n'
    printf '2) What gets installed (files)\n'
    printf '3) Concepts & glossary\n'
    printf '4) Standard vs Ephemeral mode\n'
    printf '5) Overlay precedence (Ephemeral)\n'
    printf '6) What each menu does\n'
    printf '7) CLI manuals (exact help text)\n'
    printf '8) Back\n'
    _choice=$(prompt 'Select option' '8')
    case "${_choice}" in
      1|quick|start)
        help_page 'Quick start (beginner)' 3<<'EOF'
This toolkit manages Git hooks in a predictable, composable way.

At a high level:
  1) Git runs a hook (e.g. pre-commit, post-merge)
  2) A tiny "stub" script in `.git/hooks/<hook>` dispatches to a shared runner
  3) The runner executes every executable `*.sh` in `<hooks-root>/<hook>.d/`
     in lexical (sorted) order.

Common beginner workflow:
  - Bootstrap (optional, vendors the toolkit into .githooks/)
  - Install (creates runner + stubs + hook directories)
  - Stage examples (copies ready-made hook parts into the right hook slots)
  - Configure any hook configs (edit <hooks-root>/config/*.yml if staged examples installed them)
  - Hooks list / Stage list to inspect what is active
  - Update (later, to refresh managed assets)
  - Uninstall (when retiring hooks)
  - Commit .githooks/ (standard installs only)

Safe exploration:
  - Enable "dry-run" in Settings to preview filesystem changes without applying.
EOF
        ;;
      2|files|installed)
        help_page 'What gets installed (files)' 3<<'EOF'
The toolkit installs/uses a few key things:

0) Bootstrap (optional)
   - Copies the toolkit into `.githooks/` so the repo is self-contained.

1) Runner
   - A shared runner script that orchestrates hook execution.

2) Stubs (dispatchers)
   - Small scripts placed in `.git/hooks/<hook>` that call the runner.
   - They replace "one big hook script" with a stable dispatcher.

3) Hook part directories
   - Directories like `<hooks-root>/pre-commit.d/` containing executable `*.sh`.
   - The runner executes these parts in sorted order.

4) Optional config files (some examples)
   - Staging certain examples can also install config under `<hooks-root>/config/`.

Where is `<hooks-root>`?
  - Usually `.githooks/` (standard mode)
  - Or `.git/.githooks/parts/` (ephemeral mode), with optional overlays.
EOF
        ;;
      3|concepts|glossary)
        help_page 'Concepts & glossary' 3<<'EOF'
Terminology:

- Hook:
  A Git event name like `pre-commit` or `post-merge`.

- Hook stub:
  A small script in `.git/hooks/<hook>` that dispatches to the runner.
  You generally don't edit stubs by hand.

- Runner:
  The shared script that finds and runs "hook parts" for the current hook.

- Hook part:
  An executable `*.sh` file that performs one action (lint, tests, sync deps, ...).
  Parts live in `<hooks-root>/<hook>.d/` and run in lexical order.

- Stage:
  Copy scripts from a source directory (like `examples/`) into the right hook slot.
  Staging is how you "enable" example parts quickly.

- Dry-run:
  A safety switch that prints planned actions without modifying files.
EOF
        ;;
      4|mode|modes)
        help_page 'Standard vs Ephemeral mode' 3<<'EOF'
Standard mode:
  - Uses `.githooks/` in the repository as the hooks root.
  - Great when you want hook parts tracked in git and shared with the team.

Ephemeral mode:
  - Installs active runner assets under `.git/.githooks/` (not tracked in git).
  - Useful when repo policy forbids committing tooling, or for local-only setups.
  - Can still run versioned hook parts via overlay precedence (see next page).

Either way, the goal is the same:
  Git hook -> stub -> runner -> run parts in `<hooks-root>/<hook>.d/`.
EOF
        ;;
      5|overlay)
        help_page 'Overlay precedence (Ephemeral mode)' 3<<'EOF'
Overlay controls how Ephemeral Mode combines two possible \"roots\" of hook parts:
  - Ephemeral root (inside `.git/.githooks/parts/`)
  - Versioned root (in `.githooks/`, if it exists)

Overlay choices:
  - ephemeral-first:
      run ephemeral parts before versioned parts.
  - versioned-first:
      run versioned parts before ephemeral parts.
  - merge:
      keep both roots active without changing their default ordering.

If you're unsure:
  - Use `ephemeral-first` for local-only overrides.
  - Use `versioned-first` if repo-managed hooks should take priority.
EOF
        ;;
      6|menus|what)
        help_page 'What each menu does' 3<<'EOF'
Typical flow:
  Bootstrap (optional) -> Install -> Stage -> Configure (edit config files) -> Hooks (inspect) -> Update (later) -> Uninstall (when done)
  Commit .githooks/ only for standard installs.

Install:
  Creates/refreshes the runner and stubs for selected hooks, and ensures hook
  part directories exist.

Bootstrap:
  Copies the toolkit into `.githooks/` so the repo can run the CLI/TUI locally.

Update:
  Refreshes already-installed assets (runner/stubs) and re-syncs staged parts that have a known source (examples/ or hooks/). Use it after you pull new toolkit changes or edit example scripts; it does not overwrite custom parts.

Stage:
  Add / remove hook parts in `<hooks-root>/<hook>.d/`.
  - Add: copy scripts from a source directory into the right hook slot(s).
  - Unstage: reverse "Add" for scripts that match the source.
  - Remove: delete a specific staged part or all parts for one hook.
  - List: show what parts are currently staged.
  Note: some examples also install configs under `<hooks-root>/config/` for you
  to edit after staging.

Hooks:
  Summary view: which hooks have stubs installed, and how many parts exist.

Config:
  View or set hook-related git config (notably `core.hooksPath`).

Uninstall:
  Remove toolkit-managed stubs/runner artefacts (with safe checks).
EOF
        ;;
      7|manuals|cli)
        menu_help_manuals
        ;;
      8|back|b)
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
    printf '1) Bootstrap\n'
    printf '2) Install\n'
    printf '3) Update\n'
    printf '4) Stage\n'
    printf '5) Hooks\n'
    printf '6) Config\n'
    printf '7) Uninstall\n'
    printf '8) Help\n'
    printf '9) Settings\n'
    printf '10) Exit\n'
    _choice=$(prompt 'Select option')
    case "${_choice}" in
      1|bootstrap)
        menu_bootstrap
        ;;
      2|install)
        menu_install
        ;;
      3|update)
        menu_update
        ;;
      4|stage)
        menu_stage
        ;;
      5|hooks)
        menu_hooks
        ;;
      6|config)
        menu_config
        ;;
      7|uninstall)
        menu_uninstall
        ;;
      8|help)
        menu_help
        ;;
      9|settings)
        menu_settings
        ;;
      10|exit|quit|q)
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
