#!/bin/sh
# githooks-stage: post-merge post-checkout post-rewrite
set -eu

printf '[hook-template] INFO: shared hook placeholder executed for %s\n' "${GITHOOKS_HOOK_NAME:-unknown}"
exit 0
