#!/bin/bash
# Kitty Finder spike: exercise an rclone nfsmount. Usage: spike-tests.sh <mountpoint> <remote-dir-or-"rclone:remote:">
# For the local fake remote, REMOTE is a plain directory and is inspected directly.
set -u
M="$1"; REMOTE="$2"; S="$(dirname "$0")"
pass(){ echo "PASS  $*"; }; fail(){ echo "FAIL  $*"; }
# REMOTE is either a local directory (fake remote) or "rc" to ask the running
# rclone mount itself via its remote control (needs RC_PORT, RC_USER, RC_PASS, RC_FS).
rc(){ curl -s -u "$RC_USER:$RC_PASS" -H 'Content-Type: application/json' -X POST -d "$2" "http://127.0.0.1:$RC_PORT/$1"; }
remote_ls(){
  if [[ "$REMOTE" == rc ]]; then
    rc operations/list "{\"fs\":\"$RC_FS\",\"remote\":\"kd-spike\",\"opt\":{\"recurse\":true}}" \
      | python3 -c 'import json,sys; [print(i["Path"]) for i in json.load(sys.stdin).get("list",[])]'
    echo kd-spike
  else (cd "$REMOTE" && find . -mindepth 1 | sed 's|^\./||'); fi; }
remote_cat(){
  if [[ "$REMOTE" == rc ]]; then
    local tmp; tmp=$(mktemp -d)
    rc operations/copyfile "{\"srcFs\":\"$RC_FS\",\"srcRemote\":\"$1\",\"dstFs\":\"$tmp\",\"dstRemote\":\"f\"}" >/dev/null
    cat "$tmp/f" 2>/dev/null; rm -rf "$tmp"
  else cat "$REMOTE/$1" 2>/dev/null; fi; }
settle(){ sleep "${1:-8}"; }

echo "== mount"; mount | grep -F " $M " >/dev/null && pass "mounted at $M ($(mount | grep -F " $M " | awk '{print $1}'))" || fail "not mounted"

echo "== browse"; ls "$M" >/dev/null 2>&1 && pass "ls root: $(ls "$M" | wc -l | tr -d ' ') items (names not shown)" || fail "ls root"

T="$M/kd-spike"; rm -rf "$T" 2>/dev/null; mkdir -p "$T" && pass "mkdir" || fail "mkdir"

echo "== create + read back"; echo "v1" > "$T/a.txt" && [[ "$(cat "$T/a.txt")" == v1 ]] && pass "create/read" || fail "create/read"

echo "== edit in place (append + truncate-rewrite, like editors)"
echo "v2" >> "$T/a.txt"; printf 'v3\n' > "$T/b.txt"; printf 'rewritten\n' > "$T/b.txt"
# atomic-save pattern (TextEdit/most apps): write temp then rename over
printf 'atomic\n' > "$T/.c.tmp" && mv -f "$T/.c.tmp" "$T/c.txt" && pass "atomic save (temp+rename)" || fail "atomic save"

echo "== rename / move / delete"
mv "$T/a.txt" "$T/a-renamed.txt" && pass "rename" || fail "rename"
mkdir -p "$T/sub" && mv "$T/b.txt" "$T/sub/b.txt" && pass "move into subdir" || fail "move"
echo x > "$T/del.txt"; rm "$T/del.txt" && pass "delete" || fail "delete"

echo "== random-access write (seek)"
python3 - "$T/seek.bin" <<'PY' && pass "seek write" || fail "seek write"
import sys
p=sys.argv[1]
open(p,'wb').write(b'0'*1000)
with open(p,'r+b') as f: f.seek(500); f.write(b'XYZ')
assert open(p,'rb').read()[500:503]==b'XYZ'
PY

echo "== Finder-style copy (ditto) of a folder with xattrs"
SRC="$S/finder-src"; rm -rf "$SRC"; mkdir -p "$SRC/inner"; echo f1 > "$SRC/f1.txt"; echo f2 > "$SRC/inner/f2.txt"
xattr -w com.kittyfinder.test hello "$SRC/f1.txt"
ditto "$SRC" "$T/finder-src" && pass "ditto copy w/ xattrs (Finder-style)" || fail "ditto copy"
xattr -p com.kittyfinder.test "$T/finder-src/f1.txt" >/dev/null 2>&1 && echo "   note: xattr visible on mount" || echo "   note: xattr not kept on mount"

echo "== wait for write-back"; settle 10
echo "== remote state:"; remote_ls | grep '^kd-spike' | sed 's/^/   /'
[[ "$(remote_cat kd-spike/a-renamed.txt)" == $'v1\nv2' ]] && pass "remote: edit+rename synced" || fail "remote a-renamed.txt = '$(remote_cat kd-spike/a-renamed.txt)'"
[[ "$(remote_cat kd-spike/sub/b.txt)" == rewritten ]] && pass "remote: move synced" || fail "remote sub/b.txt"
[[ "$(remote_cat kd-spike/c.txt)" == atomic ]] && pass "remote: atomic save synced" || fail "remote c.txt"
remote_ls | grep -q '^kd-spike/del.txt$' && fail "remote: delete not synced" || pass "remote: delete synced"
remote_ls | grep -q '^kd-spike/finder-src/inner/f2.txt$' && pass "remote: Finder copy synced" || fail "remote: Finder copy missing"
LEAK=$(remote_ls | grep -E '(^|/)(\._|\.DS_Store$)' || true)
[[ -z "$LEAK" ]] && pass "no ._ / .DS_Store leaked" || fail "leaked: $(echo $LEAK)"
