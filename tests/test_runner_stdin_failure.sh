#!/bin/sh
# Failure injection does not fill a real disk; real Git pushes verify rejection.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
BASE=$(mktemp -d "${TMPDIR:-/tmp}/githooks-stdin-test.XXXXXX")
trap 'rm -rf "$BASE"' EXIT
mkdir -p "$BASE/home" "$BASE/repo" "$BASE/tmp" "$BASE/bin"
export HOME="$BASE/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null TMPDIR="$BASE/tmp"
REAL_CAT=$(command -v cat)
export REAL_CAT
cat > "$BASE/bin/cat" <<'CAT'
#!/bin/sh
if [ "${TEST_CAPTURE_FAILURE:-}" = partial ] && [ "$#" -eq 0 ] && [ -z "${GITHOOKS_STDIN_FILE:-}" ]; then
  IFS= read -r first || :
  printf '%s\n' "$first"
  printf 'injected capture failure\n' >&2
  exit 74
fi
exec "$REAL_CAT" "$@"
CAT
chmod +x "$BASE/bin/cat"
git init -q "$BASE/repo"
git init --bare -q "$BASE/remote.git"
cd "$BASE/repo"
git config user.name 'Stdin test'
git config user.email 'stdin-test@example.invalid'
printf 'fixture\n' > tracked.txt
git add tracked.txt
git -c commit.gpgsign=false commit -qm fixture
git branch other
sh "$ROOT/install.sh" --repo "$BASE/repo" install --mode ephemeral --hooks pre-push >"$BASE/install-log" 2>&1
PARTS="$BASE/repo/.git/.githooks/parts/pre-push.d"
mkdir -p "$PARTS"
for n in 10 20; do
  cat > "$PARTS/$n-check.sh" <<'PART'
#!/bin/sh
cat > "$GITHOOKS_REPO_ROOT/$(basename "$0").input"
PART
  chmod +x "$PARTS/$n-check.sh"
done
HOOK=$(git rev-parse --git-path hooks/pre-push)
count=0
fail() { printf 'not ok - %s\n' "$*"; cat "$BASE/output"; exit 1; }
clean() { [ -z "$(find "$TMPDIR" -type f -print)" ] || fail 'temporary files remain'; }
ok() { count=$((count + 1)); printf 'ok %s - %s\n' "$count" "$*"; }
status=0
PATH="$BASE/bin:$PATH" TEST_CAPTURE_FAILURE=partial git push "$BASE/remote.git" HEAD:refs/heads/first other:refs/heads/other >"$BASE/output" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail 'Git accepted incomplete hook input'
[ -z "$(git --git-dir="$BASE/remote.git" for-each-ref)" ] || fail 'remote refs changed'
[ ! -e 10-check.sh.input ] && [ ! -e 20-check.sh.input ] || fail 'part ran after failed capture'
grep -q 'unable to capture hook stdin' "$BASE/output" || fail 'capture diagnostic missing'
clean
ok 'real Git rejects partial capture without dispatch or ref changes'
for shell in sh dash bash; do
  command -v "$shell" >/dev/null 2>&1 || continue
  # Runner selection follows installed stub path, with the requested shell.
  RUNNER="$BASE/repo/.git/.githooks/_runner.sh"
  status=0
  "$shell" "$RUNNER" "$HOOK" pre-push <&- >"$BASE/output" 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "$shell accepted unreadable stdin"
  [ ! -e 10-check.sh.input ] || fail "$shell dispatched on unreadable stdin"
  clean
  ok "$shell rejects unreadable stdin and cleans temporary files"
done
sh "$HOOK" remote "$BASE/remote.git" </dev/null >"$BASE/output" 2>&1 || fail 'empty input rejected'
[ -f 10-check.sh.input ] && [ ! -s 10-check.sh.input ] && [ -f 20-check.sh.input ] && [ ! -s 20-check.sh.input ] || fail 'empty replay changed'
clean
ok 'empty EOF input is replayed successfully to both parts'
rm 10-check.sh.input 20-check.sh.input
sha=$(git rev-parse HEAD)
zero=0000000000000000000000000000000000000000
printf 'HEAD %s refs/heads/first %s\nrefs/heads/other %s refs/heads/other %s\n' "$sha" "$zero" "$sha" "$zero" >"$BASE/expected"
git push "$BASE/remote.git" HEAD:refs/heads/first other:refs/heads/other >"$BASE/output" 2>&1 || fail 'ordinary push rejected'
cmp "$BASE/expected" 10-check.sh.input || fail 'first replay differs'
cmp "$BASE/expected" 20-check.sh.input || fail 'second replay differs'
[ "$(git --git-dir="$BASE/remote.git" rev-parse first)" = "$sha" ] || fail 'normal ref missing'
[ "$(git --git-dir="$BASE/remote.git" rev-parse other)" = "$sha" ] || fail 'second ref missing'
clean
ok 'real multi-ref push replays exact bytes to both parts'
printf 'last record without newline' >"$BASE/unterminated"
sh "$HOOK" remote "$BASE/remote.git" <"$BASE/unterminated" >"$BASE/output" 2>&1 || fail 'unterminated input rejected'
cmp "$BASE/unterminated" 10-check.sh.input || fail 'first unterminated replay differs'
cmp "$BASE/unterminated" 20-check.sh.input || fail 'second unterminated replay differs'
clean
ok 'unterminated input preserves exact bytes for all parts'
sh "$ROOT/install.sh" --repo "$BASE/repo" install --mode ephemeral --hooks pre-commit >"$BASE/install-log" 2>&1
mkdir -p "$BASE/repo/.git/.githooks/parts/pre-commit.d"
cp "$PARTS/10-check.sh" "$BASE/repo/.git/.githooks/parts/pre-commit.d/10-check.sh"
git -c commit.gpgsign=false commit --allow-empty -qm 'closed caller stdin' <&- >"$BASE/output" 2>&1 || fail 'real commit rejected closed caller stdin'
[ ! -s 10-check.sh.input ] || fail 'Git did not supply empty pre-commit stdin'
clean
ok 'real Git commit accepts closed caller stdin with empty hook input'
printf '1..%s\n' "$count"
