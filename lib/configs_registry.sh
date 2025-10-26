#!/bin/sh

# shellcheck disable=SC2034
: "${GITHOOKS_CONFIG_WATCH_WARNED:=0}"

githooks_config_watch_actions_warn_legacy() {
  _cfg_hint=$1
  if [ -z "${_cfg_hint}" ]; then
    return 0
  fi
  if [ "${GITHOOKS_CONFIG_WATCH_WARNED}" -eq 1 ]; then
    return 0
  fi
  _cfg_repo_top=$(githooks_repo_top)
  _cfg_legacy_root="${_cfg_repo_top%/}/.githooks"
  for _cfg_legacy in \
    "${_cfg_legacy_root}/watch-configured-actions.yml" \
    "${_cfg_legacy_root}/watch-configured-actions.yaml" \
    "${_cfg_legacy_root}/watch-configured-actions.json" \
    "${_cfg_legacy_root}/watch-config.yml" \
    "${_cfg_legacy_root}/watch-config.yaml" \
    "${_cfg_legacy_root}/watch-config.json"; do
    if [ -f "${_cfg_legacy}" ]; then
      githooks_log_warn "watch-configured-actions example: legacy config detected at ${_cfg_legacy}; migrate to ${_cfg_hint}"
      GITHOOKS_CONFIG_WATCH_WARNED=1
      break
    fi
  done
}

githooks_config_register_copy \
  "watch-configured-actions" \
  "examples/config/watch-configured-actions.yml" \
  "config/watch-configured-actions.yml" \
  644 \
  "watch-configured-actions.sh watch-configured-actions-pre-commit.sh" \
  githooks_config_watch_actions_warn_legacy

githooks_config_sample_generate() {
  _cfg_tmp=$1
  _cfg_dest_root=$2
  _cfg_name=$3
  cat <<EOF >"${_cfg_tmp}"
# sample generated configuration managed by the git-hooks toolkit
name: ${_cfg_name}
hooksRoot: ${_cfg_dest_root}
generated: true
EOF
}

githooks_config_register_generator \
  "sample-generated-config" \
  "" \
  "config/generated/sample-generated-config.yml" \
  644 \
  githooks_config_sample_generate \
  "sample-generated-config.sh"
