#!/bin/sh
# Path-state controls and actual Git commits under the invoking user's permissions.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
BASE=$(mktemp -d "${TMPDIR:-/tmp}/githooks-access-test.XXXXXX")
trap 'chmod -R u+rwx "$BASE"; rm -rf "$BASE"' EXIT
mkdir -p "$BASE/home" "$BASE/tmp"
export HOME="$BASE/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 TMPDIR="$BASE/tmp"
. "$ROOT/lib/common.sh"
count=0
ok() { count=$((count + 1)); printf 'ok %s - %s\n' "$count" "$*"; }
fail() { printf 'not ok - %s\n' "$*"; cat "$BASE/output"; exit 1; }
probe() {
 expected=$1; shift
 status=0; githooks_probe_parts_dir "$1" >"$BASE/output" 2>&1 || status=$?
 [ "$status" -eq "$expected" ] || fail "probe $1 returned $status, expected $expected"
 ok "path state $expected: $1"
}
mkdir -p "$BASE/space path/real/nested" "$BASE/space path/deep"
ln -s real/nested "$BASE/space path/link"
probe 0 "$BASE/space path/link/.."
probe 1 "$BASE/space path/link/../deep" # lexical link/.. would incorrectly find deep
probe 1 "$BASE/space path/absent/deeper"
ln -s missing "$BASE/space path/dangling"
probe 2 "$BASE/space path/dangling"
probe 2 "$BASE/space path/dangling/child"
printf file > "$BASE/space path/file"
probe 2 "$BASE/space path/file"
probe 2 "$BASE/space path/file/child"
ln -s cycle "$BASE/space path/cycle"
probe 2 "$BASE/space path/cycle"
if [ "$(id -u)" -ne 0 ]; then
 chmod 111 "$BASE/space path/real"
 probe 0 "$BASE/space path/link"
 probe 1 "$BASE/space path/real/missing/deep"
 chmod 600 "$BASE/space path/real"
 probe 2 "$BASE/space path/real/nested"
 probe 2 "$BASE/space path/real/missing/deep"
 probe 2 "$BASE/space path/link"
 chmod 700 "$BASE/space path/real"
fi
commit() { git -c commit.gpgsign=false commit --allow-empty -qm test >"$BASE/output" 2>&1; }
reject() {
 before=$(git rev-parse --verify HEAD 2>/dev/null || :)
 status=0; commit || status=$?
 [ "$status" -ne 0 ] || fail "$1 unexpectedly committed"
 [ "$(git rev-parse --verify HEAD 2>/dev/null || :)" = "$before" ] || fail 'failed commit changed HEAD'
 [ ! -e ran ] || fail 'partial dispatch occurred'
 [ -z "$(find "$TMPDIR" -type f -print)" ] || fail 'temporary files leaked'
 ok "$1"
}
for mode in standard ephemeral; do
 mkdir "$BASE/$mode";git init -q "$BASE/$mode";cd "$BASE/$mode"
 git config user.name Test;git config user.email test@example.invalid
 if [ "$mode" = ephemeral ]; then args='--mode ephemeral';parts="$PWD/.git/.githooks/parts/pre-commit.d";else args='';parts="$PWD/.githooks/pre-commit.d";fi
 sh "$ROOT/install.sh" --repo "$PWD" install $args --hooks pre-commit >"$BASE/install" 2>&1
 mkdir -p "$parts"
 printf '#!/bin/sh\nexit 1\n' > "$parts/00-reject.sh";chmod +x "$parts/00-reject.sh"
 reject "$mode normal rejecting gate"
 grep -q "part failed" "$BASE/output" || fail "$mode ordinary gate did not execute"
 # Move only parts outside toolkit assets, so runner and its libraries stay accessible.
 parent="$BASE/$mode external"
 mkdir "$parent";mv "$parts" "$parent/parts";ln -s "$parent/parts" "$parts"
 reject "$mode symlink rejecting gate"
 grep -q "part failed" "$BASE/output" || fail "$mode symlink gate did not execute"
 # -H follows only the root operand, not symlinked child hook files.
 mv "$parent/parts/00-reject.sh" "$parent/reject.sh"
 ln -s "$parent/reject.sh" "$parent/parts/00-reject.sh"
 commit || fail "$mode child symlink was followed"
 ok "$mode child symlink remains excluded"
 rm "$parent/parts/00-reject.sh";mv "$parent/reject.sh" "$parent/parts/00-reject.sh"
 if [ "$(id -u)" -ne 0 ];then
   chmod 111 "$parent";reject "$mode search-only parent retains gate"
   grep -q "part failed" "$BASE/output" || fail "$mode search-only gate did not execute"
   chmod 600 "$parent";reject "$mode inaccessible symlink ancestor rejects"
   chmod 700 "$parent"
 fi
 rm "$parts";ln -s "$parent/missing" "$parts"
 reject "$mode dangling hook directory rejects"
 rm "$parts"
 commit || fail "$mode missing optional dir blocked"
 ok "$mode removed optional directory accepted"
 if [ "$mode" = ephemeral ];then
   # Earlier root has a successful part; later extra root must fail before any dispatch.
   mkdir -p "$parts" "$parent/extra/pre-commit.d"
   printf '#!/bin/sh\ntouch "$GITHOOKS_REPO_ROOT/ran"\n' > "$parts/10-mark.sh";chmod +x "$parts/10-mark.sh"
   git config --add githooks.ephemeral.extraRoot "$parent/extra"
   if [ "$(id -u)" -ne 0 ];then
     chmod 600 "$parent/extra";reject 'later inaccessible overlay prevents all dispatch';chmod 700 "$parent/extra"
     chmod 600 "$(dirname "$parts")";reject 'ephemeral parts parent inaccessible rejects';chmod 700 "$(dirname "$parts")"
   fi
 fi
done
printf '1..%s\n' "$count"
