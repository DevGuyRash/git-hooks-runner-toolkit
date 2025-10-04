#!/bin/sh
# githooks-stage: pre-commit
# Example hook part: enforce git-crypt encryption on pre-commit.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
LIB_PATH="${SCRIPT_DIR}/../lib/common.sh"
if [ ! -f "${LIB_PATH}" ]; then
  printf '[hook-runner] ERROR: git-crypt example missing common library at %s\n' "${LIB_PATH}" >&2
  exit 1
fi
# shellcheck source=scripts/.githooks/lib/common.sh
. "${LIB_PATH}"

export GITHOOKS_LOG_NAMESPACE=${GITHOOKS_LOG_NAMESPACE:-git-crypt}

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  githooks_log_info "git-crypt enforcement: not inside work tree; skipping"
  exit 0
fi

if githooks_is_bare_repo; then
  githooks_log_info "git-crypt enforcement: bare repository detected; skipping"
  exit 0
fi

REPO_ROOT=$(githooks_repo_top)
cd "${REPO_ROOT}" || exit 1

is_true() {
  case "$1" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

AUTO_FIX=${GITCRYPT_AUTO_FIX:-$(git config --bool --get gitcrypt.hook.autofix 2>/dev/null || echo false)}
ALLOW_MIXED=${GITCRYPT_ALLOW_MIXED_GITATTRIBUTES:-$(git config --bool --get gitcrypt.hook.allowMixedGitAttributes 2>/dev/null || echo false)}
STRICT_HEAD=${GITCRYPT_STRICT_HEAD:-$(git config --bool --get gitcrypt.hook.strictHead 2>/dev/null || echo false)}

expected_hex='00474954435259505400'

STAGED_FILE=$(mktemp "${TMPDIR:-/tmp}/gitcrypt-staged.XXXXXX") || exit 1
ATTRS_FILE=$(mktemp "${TMPDIR:-/tmp}/gitcrypt-attrs.XXXXXX") || exit 1
NEED_ENCRYPT_FILE=$(mktemp "${TMPDIR:-/tmp}/gitcrypt-need.XXXXXX") || exit 1
UNENCRYPTED_FILE=$(mktemp "${TMPDIR:-/tmp}/gitcrypt-plain.XXXXXX") || exit 1
HEAD_UNENC_FILE=$(mktemp "${TMPDIR:-/tmp}/gitcrypt-head-plain.XXXXXX") || exit 1

cleanup_lists() {
  rm -f "${STAGED_FILE}" "${ATTRS_FILE}" "${NEED_ENCRYPT_FILE}" "${UNENCRYPTED_FILE}" "${HEAD_UNENC_FILE}"
}
trap cleanup_lists EXIT HUP INT TERM

git -c core.quotepath=off diff --cached --name-only -z --diff-filter=ACMR 2>/dev/null | tr '\0' '\n' | sed '/^$/d' >"${STAGED_FILE}"

if ! [ -s "${STAGED_FILE}" ]; then
  githooks_log_info "git-crypt enforcement: nothing staged"
  exit 0
fi

OTHER_CHANGED=0
>"${ATTRS_FILE}"
while IFS= read -r staged_path; do
  case "${staged_path}" in
    '') continue ;;
    .gitattributes|*/.gitattributes)
      printf '%s\n' "${staged_path}" >>"${ATTRS_FILE}"
      ;;
    *)
      OTHER_CHANGED=1
      ;;
  esac
done <"${STAGED_FILE}"

if [ -s "${ATTRS_FILE}" ] && [ "${OTHER_CHANGED}" -eq 1 ] && ! is_true "${ALLOW_MIXED}"; then
  githooks_log_error "git-crypt enforcement: .gitattributes changed with other files"
  printf '   Staged attribute file(s):\n' >&2
  while IFS= read -r attr_path; do
    [ -n "${attr_path}" ] || continue
    printf '     - %s\n' "${attr_path}" >&2
  done <"${ATTRS_FILE}"
  cat >&2 <<'EOF'
   Commit .gitattributes separately so encryption rules take effect before secrets.
   Override once with:
     GITCRYPT_ALLOW_MIXED_GITATTRIBUTES=1 git commit …
   Or persist with:
     git config gitcrypt.hook.allowMixedGitAttributes true
EOF
  exit 1
fi

>"${NEED_ENCRYPT_FILE}"
while IFS= read -r staged_path; do
  [ -n "${staged_path}" ] || continue
  mode=$(git ls-files --stage -- "${staged_path}" | awk 'NR==1 {print $1}')
  if [ "${mode}" = "160000" ] || [ "${mode}" = "120000" ]; then
    continue
  fi
  attr_line=$(git -c core.quotepath=off check-attr filter -- "${staged_path}" 2>/dev/null || true)
  value=$(printf '%s\n' "${attr_line}" | awk -F': filter: ' 'NF>1 {print $2; exit}')
  case "${value}" in
    git-crypt|git-crypt-*)
      printf '%s\n' "${staged_path}" >>"${NEED_ENCRYPT_FILE}"
      ;;
  esac
done <"${STAGED_FILE}"

if [ -s "${NEED_ENCRYPT_FILE}" ] && ! command -v git-crypt >/dev/null 2>&1; then
  githooks_log_error "git-crypt enforcement: git-crypt is required but not installed"
  printf '   Run `git-crypt unlock` after installing git-crypt.\n' >&2
  exit 1
fi

check_plaintext() {
  target_path=$1
  git show ":${target_path}" 2>/dev/null | LC_ALL=C dd bs=10 count=1 2>/dev/null | od -An -t x1 | tr -d ' \n'
}

>"${UNENCRYPTED_FILE}"
while IFS= read -r need_path; do
  [ -n "${need_path}" ] || continue
  header_hex=$(check_plaintext "${need_path}")
  if [ "${header_hex}" != "${expected_hex}" ]; then
    printf '%s\n' "${need_path}" >>"${UNENCRYPTED_FILE}"
  fi
done <"${NEED_ENCRYPT_FILE}"

if [ -s "${UNENCRYPTED_FILE}" ] && is_true "${AUTO_FIX}"; then
  githooks_log_warn "git-crypt enforcement: attempting auto-fix via git-crypt status -f"
  git-crypt status -f >/dev/null 2>&1 || true
  NEW_UNENCRYPTED=$(mktemp "${TMPDIR:-/tmp}/gitcrypt-plain.XXXXXX") || exit 1
  while IFS= read -r pending_path; do
    [ -n "${pending_path}" ] || continue
    header_hex=$(check_plaintext "${pending_path}")
    if [ "${header_hex}" != "${expected_hex}" ]; then
      printf '%s\n' "${pending_path}" >>"${NEW_UNENCRYPTED}"
    fi
  done <"${UNENCRYPTED_FILE}"
  mv "${NEW_UNENCRYPTED}" "${UNENCRYPTED_FILE}"
fi

if [ -s "${UNENCRYPTED_FILE}" ]; then
  githooks_log_error "git-crypt enforcement: refusing plaintext for protected paths"
  while IFS= read -r plain_path; do
    [ -n "${plain_path}" ] || continue
    printf '   - %s\n' "${plain_path}" >&2
  done <"${UNENCRYPTED_FILE}"
  cat >&2 <<'EOF'

How to fix:
  1) Ensure .gitattributes marks the path with filter=git-crypt diff=git-crypt
  2) Ensure the repo is unlocked:             git-crypt unlock
  3) Restage to apply filters:                git add --renormalize <paths>
  4) Or run auto-fix once:                    git-crypt status -f

Tip: enable automatic fixing on this machine:
  git config gitcrypt.hook.autofix true
EOF
  exit 1
fi

if is_true "${STRICT_HEAD}"; then
  if git rev-parse -q --verify HEAD >/dev/null 2>&1; then
    >"${HEAD_UNENC_FILE}"
    git ls-files -z | tr '\0' '\n' | while IFS= read -r tracked_path; do
      [ -n "${tracked_path}" ] || continue
      attr_line=$(git -c core.quotepath=off check-attr filter -- "${tracked_path}" 2>/dev/null || true)
      value=$(printf '%s\n' "${attr_line}" | awk -F': filter: ' 'NF>1 {print $2; exit}')
      case "${value}" in
        git-crypt|git-crypt-*)
          head_mode=$(git ls-tree HEAD -- "${tracked_path}" | awk 'NR==1 {print $1}')
          if [ "${head_mode}" = "120000" ]; then
            continue
          fi
          head_hex=$(git show "HEAD:${tracked_path}" 2>/dev/null | LC_ALL=C dd bs=10 count=1 2>/dev/null | od -An -t x1 | tr -d ' \n' || true)
          if [ -n "${head_hex}" ] && [ "${head_hex}" != "${expected_hex}" ]; then
            printf '%s\n' "${tracked_path}" >>"${HEAD_UNENC_FILE}"
          fi
          ;;
      esac
    done

    if [ -s "${HEAD_UNENC_FILE}" ]; then
      githooks_log_error "git-crypt enforcement: HEAD already contains plaintext"
      while IFS= read -r head_plain; do
        [ -n "${head_plain}" ] || continue
        printf '   - %s\n' "${head_plain}" >&2
      done <"${HEAD_UNENC_FILE}"
      cat >&2 <<'EOF'

Fix by restaging encrypted versions:
  git-crypt unlock
  git add --renormalize <paths>
  git commit -m "Encrypt secrets via git-crypt"

(Disable strict head temporarily after cleanup:
  git config gitcrypt.hook.strictHead false)
EOF
      exit 1
    fi
  fi
fi

githooks_log_info "git-crypt enforcement: all protected paths encrypted"
exit 0
