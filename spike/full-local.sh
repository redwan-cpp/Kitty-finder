#!/bin/bash
# Full spike run of the patched rclone against a local fake remote:
# write suite, cache-cap eviction, partial reads, crash recovery.
# Usage: full-local.sh <scratch-dir> <rclone-binary>
S="$1"; RCLONE="$2"; HERE="$(cd "$(dirname "$0")" && pwd)"
M="$S/mnt"; REMOTE="$S/fake-remote"; CACHE="$S/cache-full"; META="$S/meta-full"
mkdir -p "$M"; rm -rf "$CACHE" "$META" "$REMOTE/kd-spike"
pass(){ echo "PASS  $*"; }; fail(){ echo "FAIL  $*"; }
cache_mb(){ du -sm "$CACHE/vfs" 2>/dev/null | awk '{print $1}'; }

start(){
  "$RCLONE" nfsmount "$REMOTE" "$M" --config "$S/rclone.conf" -o locallocks --nfs-apple-meta-dir "$META" \
    --vfs-cache-mode full --vfs-cache-max-size 150M --vfs-cache-poll-interval 5s --vfs-write-back 1s \
    --cache-dir "$CACHE" --log-file "$S/full.log" -v &
  RPID=$!
  for _ in $(seq 1 20); do mount | grep -qF " $M " && return 0; sleep 0.5; done
  echo "mount did not come up"; exit 1
}
stop(){ umount "$M" 2>/dev/null || diskutil unmount force "$M" >/dev/null 2>&1; wait $RPID 2>/dev/null; }

start
echo "== write suite"; bash "$HERE/spike-tests.sh" "$M" "$REMOTE" 2>&1 | grep -E '^(PASS|FAIL)'

echo "== partial read of a big file (should not download all of it)"
before=$(cache_mb)
python3 -c "f=open('$M/big1.bin','rb'); f.seek(60*1024*1024); assert len(f.read(1024*1024))==1048576"
after=$(cache_mb)
[ "$((after-before))" -lt 60 ] && pass "1 MiB read at 60 MiB offset cached ~$((after-before)) MiB" || fail "partial read cached $((after-before)) MiB"

echo "== cache cap eviction (cap 150M, read 2 x 120M)"
cat "$M/big1.bin" > /dev/null; cat "$M/big2.bin" > /dev/null
peak=$(cache_mb); sleep 12; settled=$(cache_mb)
echo "   cache peak=${peak}M settled=${settled}M"
[ "$settled" -le 160 ] && pass "evicted down to cap" || fail "cache still ${settled}M"
cmp -s "$M/big1.bin" "$REMOTE/big1.bin" && pass "evicted file re-reads correctly" || fail "re-read mismatch"

echo "== crash recovery (kill -9 rclone with a pending upload)"
dd if=/dev/urandom of="$S/pending.bin" bs=1m count=5 2>/dev/null
cp -X "$S/pending.bin" "$M/kd-spike/pending.bin"; kill -9 $RPID; wait $RPID 2>/dev/null
t0=$(date +%s); perl -e 'alarm 15; exec @ARGV' stat "$M" >/dev/null 2>&1; rc=$?; t1=$(date +%s)
echo "   stat on dead mount: exit=$rc after $((t1-t0))s"
diskutil unmount force "$M" >/dev/null 2>&1 && pass "force unmount of dead mount" || fail "force unmount"
start; sleep 4
cmp -s "$S/pending.bin" "$REMOTE/kd-spike/pending.bin" && pass "pending upload resumed after restart" || fail "pending upload lost"
stop
mount | grep -qF " $M " && fail "still mounted" || pass "clean unmount"
