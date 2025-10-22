#!/bin/sh
# Lightweight CLI argument helpers shared across toolkit entrypoints. Focuses
# on normalising mode/overlay flag payloads while deferring error messaging to
# existing logging utilities.

githooks_cli_normalise_mode() {
  if [ "$#" -ne 1 ]; then
    githooks_die "--mode requires a value"
  fi
  _githooks_cli_mode=$1
  case "${_githooks_cli_mode}" in
    ephemeral)
      printf '%s\n' 'ephemeral'
      ;;
    '')
      githooks_die "--mode requires a value"
      ;;
    *)
      githooks_die "unknown mode: ${_githooks_cli_mode}"
      ;;
  esac
}

githooks_cli_normalise_overlay() {
  if [ "$#" -ne 1 ]; then
    githooks_die "--overlay requires a value"
  fi
  _githooks_cli_overlay=$1
  case "${_githooks_cli_overlay}" in
    ephemeral-first|versioned-first|merge)
      printf '%s\n' "${_githooks_cli_overlay}"
      ;;
    '')
      githooks_die "--overlay requires a value"
      ;;
    *)
      githooks_die "unknown overlay precedence: ${_githooks_cli_overlay}"
      ;;
  esac
}

githooks_cli_resolve_mode() {
  if [ "$#" -lt 1 ]; then
    githooks_die "githooks_cli_resolve_mode requires default mode"
  fi
  _githooks_cli_mode_default=$1
  shift
  _githooks_cli_mode="${_githooks_cli_mode_default}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mode)
        if [ "$#" -lt 2 ]; then
          githooks_die "--mode requires a value"
        fi
        _githooks_cli_mode=$(githooks_cli_normalise_mode "$2")
        shift 2
        continue
        ;;
      --mode=*)
        _githooks_cli_mode=$(githooks_cli_normalise_mode "${1#*=}")
        shift
        continue
        ;;
      --)
        break
        ;;
      *)
        shift
        ;;
    esac
  done
  printf '%s\n' "${_githooks_cli_mode}"
}
