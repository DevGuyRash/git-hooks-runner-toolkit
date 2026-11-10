#!/bin/sh
# Real YAML/JSON parsers and shell execution; no parser stubs.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo 'jq required' >&2; exit 1; }
command -v yq >/dev/null || { echo 'Mike Farah yq v4 required' >&2; exit 1; }
. "$ROOT/tests/lib/git_test_helpers.sh"
TG_BASE=$(mktemp -d "${TMPDIR:-/tmp}/watch-transport.XXXXXX")
trap 'rm -rf "$TG_BASE"' EXIT
repo="$TG_BASE/repo"
home="$TG_BASE/home"
mkdir -p "$repo" "$home/.config"
ghr_init_repo "$repo" "$home"
cat > "$TG_BASE/command" <<'CMD'
printf '%s\n' 'literal\n\t $() `backticks` "quotes"' > result
printf '%s\n' 'second line' >> result
printf 'tab\there\n' >> result
# trailing newlines remain part of the command

CMD
printf '%s\n' 'literal\n\t $() `backticks` "quotes"' 'second line' > "$TG_BASE/expected"
printf 'tab\there\nlast-command\n' >> "$TG_BASE/expected"
jq -n --rawfile cmd "$TG_BASE/command" '[
 {name:"$(touch injected-name)", patterns:["not-it", "target"],
  commands:[$cmd, "printf '\''last-command\\n'\'' >> result"]},
 {name:"inactive",patterns:["absent"],commands:["touch injected-command"]}
]' > "$TG_BASE/config.json"
yq eval -P -o=yaml '.' "$TG_BASE/config.json" > "$TG_BASE/config.yml"
for format in json yml; do
  (
    cd "$repo"
    . "$ROOT/lib/common.sh"
    . "$ROOT/lib/watch-configured-actions.sh"
    watch_actions_init pre-commit
    watch_actions_load_config_rules "$TG_BASE/config.$format"
    [ "$WATCH_ACTIONS_RULE_COUNT" = 2 ]
    [ ! -e injected-name ] && [ ! -e injected-command ] && [ ! -e result ]
    # Verify byte preservation, including trailing newlines, before execution.
    sed -n '1p' "$WATCH_ACTIONS_RULE_COMMANDS_FILE" | cut -d "$(printf '\037')" -f1 | jq -Rrj '@base64d' > "$TG_BASE/decoded"
    cmp "$TG_BASE/command" "$TG_BASE/decoded"
    printf 'target\n' > "$WATCH_ACTIONS_CHANGED_FILE_LOG"
    # Execution loads the selected config itself; discard inspection records.
    WATCH_ACTIONS_RULE_COUNT=0
    for records in "$WATCH_ACTIONS_RULE_NAMES_FILE" "$WATCH_ACTIONS_RULE_PATTERNS_FILE" "$WATCH_ACTIONS_RULE_COMMANDS_FILE" "$WATCH_ACTIONS_RULE_CONTINUES_FILE" "$WATCH_ACTIONS_RULE_ENCODINGS_FILE"; do : > "$records"; done
    GITHOOKS_WATCH_CONFIG="$TG_BASE/config.$format"
    watch_actions_execute_rules
    cmp "$TG_BASE/expected" result
    [ ! -e injected-name ] && [ ! -e injected-command ]
    rm result
  )
  printf 'ok - %s exact command bytes, arrays, multiline execution and inert metadata\n' "$format"
done
# Reject malformed schema or record separators before appending any valid prefix.
for invalid in '{"commands":[42]}' '{"patterns":["bad\npath"]}' '{"commands":["bad\u0000command"]}' '{"continue_on_error":"yes"}'; do
  jq -n --argjson invalid "$invalid" '[{patterns:["target"],commands:["touch should-not-run"]}, $invalid]' > "$TG_BASE/invalid.json"
  (
    cd "$repo"
    . "$ROOT/lib/common.sh"
    . "$ROOT/lib/watch-configured-actions.sh"
    watch_actions_init pre-commit
    if watch_actions_load_config_rules "$TG_BASE/invalid.json"; then exit 1; fi
    [ "$WATCH_ACTIONS_RULE_COUNT" = 0 ]
    [ ! -s "$WATCH_ACTIONS_RULE_COMMANDS_FILE" ]
    [ ! -e should-not-run ]
  )
done
printf 'ok - invalid config rejects atomically without execution\n'
printf '%s\n' '- name: [' > "$TG_BASE/invalid.yml"
(
  cd "$repo"
  . "$ROOT/lib/common.sh"
  . "$ROOT/lib/watch-configured-actions.sh"
  watch_actions_init pre-commit
  if watch_actions_load_config_rules "$TG_BASE/invalid.yml"; then exit 1; fi
  [ "$WATCH_ACTIONS_RULE_COUNT" = 0 ]
)
printf 'ok - malformed YAML rejects without rules\n'
# Dependency diagnostics stay explicit, with no partial rule registration.
mkdir "$TG_BASE/only-yq" "$TG_BASE/only-jq"
ln -s "$(command -v yq)" "$TG_BASE/only-yq/yq"
ln -s "$(command -v grep)" "$TG_BASE/only-yq/grep"
ln -s "$(command -v jq)" "$TG_BASE/only-jq/jq"
for missing in jq yq; do
  (
    cd "$repo"
    . "$ROOT/lib/common.sh"
    . "$ROOT/lib/watch-configured-actions.sh"
    watch_actions_init pre-commit
    original_path=$PATH
    case "$missing" in jq) PATH="$TG_BASE/only-yq" ;; yq) PATH="$TG_BASE/only-jq" ;; esac
    status=0
    watch_actions_load_config_rules "$TG_BASE/config.yml" || status=$?
    PATH=$original_path
    case "$missing" in jq) [ "$status" = 1 ] ;; yq) [ "$status" = 2 ] ;; esac
    [ "$WATCH_ACTIONS_CONFIG_LOAD_DIAG" = "missing-$missing" ]
    [ "$WATCH_ACTIONS_RULE_COUNT" = 0 ]
    if [ "$missing" = jq ]; then
      printf 'target\n' > "$WATCH_ACTIONS_CHANGED_FILE_LOG"
      GITHOOKS_WATCH_CONFIG="$TG_BASE/config.yml"
      PATH="$TG_BASE/only-yq"
      status=0
      watch_actions_execute_rules || status=$?
      PATH=$original_path
      [ "$status" = 1 ]
      [ ! -e result ]
    fi
  )
done
printf 'ok - missing jq and yq reported without partial rules\n'
