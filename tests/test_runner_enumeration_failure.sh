#!/bin/sh
# Real Git commits plus controlled partial-output failures; no user repo touched.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
BASE=$(mktemp -d "${TMPDIR:-/tmp}/githooks-enumeration-test.XXXXXX")
trap 'chmod -R u+rwx "$BASE"; rm -rf "$BASE"' EXIT
mkdir -p "$BASE/home" "$BASE/tmp" "$BASE/bin"
export HOME="$BASE/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null TMPDIR="$BASE/tmp"
REAL_FIND=$(command -v find); REAL_SORT=$(command -v sort)
export REAL_FIND REAL_SORT
for tool in find sort; do
  cat > "$BASE/bin/$tool" <<'WRAPPER'
#!/bin/sh
tool=${0##*/}
case "$tool" in find) real=$REAL_FIND;; sort) real=$REAL_SORT;; esac
if [ "${FAIL_TOOL:-}" = "$tool" ]; then
  "$real" "$@"
  printf 'injected %s failure after output\n' "$tool" >&2
  exit 74
fi
exec "$real" "$@"
WRAPPER
  chmod +x "$BASE/bin/$tool"
done
count=0
ok() { count=$((count + 1)); printf 'ok %s - %s\n' "$count" "$*"; }
fail() { printf 'not ok - %s\n' "$*"; cat "$BASE/output"; exit 1; }
clean() { [ -z "$("$REAL_FIND" "$TMPDIR" -type f -print)" ] || fail 'temporary files leaked'; }
commit() { git -c commit.gpgsign=false commit --allow-empty -qm test >"$BASE/output" 2>&1; }
for mode in standard ephemeral; do
  mkdir "$BASE/$mode"
  git init -q "$BASE/$mode"
  cd "$BASE/$mode"
  git config user.name Test; git config user.email test@example.invalid
  if [ "$mode" = ephemeral ]; then mode_args="--mode ephemeral"; else mode_args=""; fi
  sh "$ROOT/install.sh" --repo "$PWD" install $mode_args --hooks pre-commit >"$BASE/install" 2>&1
  if [ "$mode" = ephemeral ]; then parts="$PWD/.git/.githooks/parts/pre-commit.d"; else parts="$PWD/.githooks/pre-commit.d"; fi
  mkdir -p "$parts"
  commit || fail "$mode empty directory rejected"
  clean; ok "$mode empty hook directory accepted"
  rmdir "$parts"
  commit || fail "$mode absent directory rejected"
  clean; ok "$mode absent optional directory accepted"
  mkdir -p "$parts"
  for n in 20 10; do
    printf '#!/bin/sh\nprintf "%%s\\n" %s >> "$GITHOOKS_REPO_ROOT/ran"\n' "$n" > "$parts/$n-part.sh"
    chmod +x "$parts/$n-part.sh"
  done
  commit || fail "$mode valid hook rejected"
  [ "$(cat ran)" = "$(printf '10\n20')" ] || fail "$mode ordering changed"
  rm ran; clean; ok "$mode parts run in lexical order"
  for tool in find sort; do
    status=0
    PATH="$BASE/bin:$PATH" FAIL_TOOL="$tool" commit || status=$?
    [ "$status" -ne 0 ] || fail "$mode $tool failure accepted"
    [ ! -e ran ] || fail "$mode dispatched partial $tool output"
    clean; ok "$mode $tool partial-output failure blocks all dispatch"
  done
  # Root can bypass directory read permissions, so label that environment honestly.
  if [ "$(id -u)" -ne 0 ]; then
    printf '#!/bin/sh\nexit 1\n' > "$parts/00-reject.sh"; chmod +x "$parts/00-reject.sh"
    status=0; commit || status=$?
    [ "$status" -ne 0 ] || fail "$mode readable rejection gate not invoked"
    chmod 100 "$parts"
    status=0; commit || status=$?
    chmod 700 "$parts"
    [ "$status" -ne 0 ] || fail "$mode unreadable directory bypassed gate"
    [ ! -e ran ] || fail "$mode unreadable directory dispatched"
    clean; ok "$mode real unreadable directory cannot bypass rejecting gate"
  else
    ok "$mode unreadable directory # SKIP root bypasses directory permissions"
  fi
done
printf '1..%s\n' "$count"
