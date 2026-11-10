#!/bin/sh
# Real runner/Git cancellation checks. No process group or child-kill guarantees:
# a foreground part can finish before the runner processes its pending signal.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
BASE=$(mktemp -d "${TMPDIR:-/tmp}/githooks-signals.XXXXXX")
trap 'rm -rf "$BASE"' EXIT
mkdir -p "$BASE/home" "$BASE/repo/.githooks/lib" "$BASE/repo/.githooks/pre-commit.d" "$BASE/tmp"
export HOME="$BASE/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export TMPDIR="$BASE/tmp"
cp "$ROOT/_runner.sh" "$BASE/repo/.githooks/_runner.sh"
cp "$ROOT/lib/common.sh" "$BASE/repo/.githooks/lib/common.sh"
cd "$BASE/repo"
git init -q
git config user.name 'Signal test'
git config user.email 'signal-test@example.invalid'
cat > .git/hooks/pre-commit <<'HOOK'
#!/bin/sh
exec sh .githooks/_runner.sh "$0" pre-commit "$@"
HOOK
chmod +x .git/hooks/pre-commit
cat > .githooks/pre-commit.d/10-first.sh <<'PART'
#!/bin/sh
if [ -n "${TEST_SIGNAL:-}" ]; then
  kill -s "$TEST_SIGNAL" "$PPID"
fi
# The active part can finish; only subsequent dispatch is stopped.
printf 'finished\n' > "$GITHOOKS_REPO_ROOT/first-finished"
exit "${TEST_PART_STATUS:-0}"
PART
cat > .githooks/pre-commit.d/20-later.sh <<'PART'
#!/bin/sh
printf 'later\n' > "$GITHOOKS_REPO_ROOT/later-ran"
PART
chmod +x .githooks/pre-commit.d/*.sh
printf 'fixture\n' > tracked.txt
git add tracked.txt
count=0
fail() { printf 'not ok %s - %s\n' "$count" "$*"; cat "$BASE/output"; exit 1; }
assert_clean() {
  [ -z "$(find "$TMPDIR" -type f -print)" ] || fail 'temporary files remain'
}
for signal in HUP INT TERM; do
  case "$signal" in HUP) expected=129;; INT) expected=130;; TERM) expected=143;; esac
  count=$((count + 1))
  # Cancellation of the final part must not fall through to exit 0 either.
  chmod -x .githooks/pre-commit.d/20-later.sh
  status=0
  TEST_SIGNAL=$signal sh .githooks/_runner.sh dummy pre-commit </dev/null >"$BASE/output" 2>&1 || status=$?
  [ "$status" -eq "$expected" ] || fail "final-part $signal returned $status, expected $expected"
  ! grep -q 'completed pre-commit' "$BASE/output" || fail 'false success after final part'
  assert_clean
  chmod +x .githooks/pre-commit.d/20-later.sh
  printf 'ok %s - final-part %s does not report success\n' "$count" "$signal"
  count=$((count + 1))
  rm -f first-finished later-ran
  status=0
  TEST_SIGNAL=$signal sh .githooks/_runner.sh dummy pre-commit </dev/null >"$BASE/output" 2>&1 || status=$?
  [ "$status" -eq "$expected" ] || fail "$signal returned $status, expected $expected"
  [ -f first-finished ] || fail 'foreground part did not finish'
  [ ! -f later-ran ] || fail 'later part ran after signal'
  ! grep -q 'completed pre-commit' "$BASE/output" || fail 'false success log'
  assert_clean
  printf 'ok %s - direct %s exits %s without later dispatch\n' "$count" "$signal" "$expected"
  count=$((count + 1))
  rm -f first-finished later-ran
  status=0
  TEST_SIGNAL=$signal git -c commit.gpgsign=false commit -qm 'must not commit' >"$BASE/output" 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'Git accepted canceled hook'
  ! git rev-parse --verify HEAD >/dev/null 2>&1 || fail 'canceled commit exists'
  [ ! -f later-ran ] || fail 'Git ran later hook part'
  assert_clean
  printf 'ok %s - Git rejects commit after %s\n' "$count" "$signal"
done
count=$((count + 1))
status=0
TEST_PART_STATUS=42 sh .githooks/_runner.sh dummy pre-commit </dev/null >"$BASE/output" 2>&1 || status=$?
[ "$status" -eq 42 ] || fail 'ordinary failure status changed'
[ ! -f later-ran ] || fail 'later part ran after failure'
assert_clean
printf 'ok %s - ordinary part failure remains 42\n' "$count"
count=$((count + 1))
sh .githooks/_runner.sh dummy pre-commit </dev/null >"$BASE/output" 2>&1 || fail 'ordinary success failed'
[ -f later-ran ] || fail 'normal dispatch skipped later part'
grep -q 'completed pre-commit' "$BASE/output" || fail 'normal success log missing'
assert_clean
printf 'ok %s - ordinary success dispatch preserved\n' "$count"
printf '1..%s\n' "$count"
