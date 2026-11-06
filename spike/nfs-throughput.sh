#!/bin/bash
# Local-only NFS throughput test: patched rclone nfsmount of a local folder,
# comparing mount options. Measures write and (cold, warm) read of a 256 MB file.
# Usage: nfs-throughput.sh <scratch-dir> <rclone> "<label>" [extra -o options...]
S="$1"; R="$2"; LABEL="$3"; shift 3
M="$S/mnt-tp"; REMOTE="$S/tp-remote"; CACHE="$S/tp-cache-$RANDOM"
mkdir -p "$M" "$REMOTE"; rm -f "$REMOTE/big.bin"
"$R" nfsmount "$REMOTE" "$M" --config /dev/null -o locallocks "$@" --nfs-apple-meta-dir "$S/tp-meta" \
  --vfs-cache-mode full --cache-dir "$CACHE" --vfs-write-back 1s --log-file "$S/tp.log" &
P=$!; for i in $(seq 1 20); do mount | grep -qF " $M " && break; sleep 0.5; done
opts=$(nfsstat -m "$M" 2>/dev/null | grep -oE 'rsize=[0-9]+,wsize=[0-9]+|readahead=[0-9]+' | tr '\n' ' ')
[ -f "$S/tp-src.bin" ] || dd if=/dev/urandom of="$S/tp-src.bin" bs=1m count=256 2>/dev/null
t(){ python3 -c 'import time;print(time.perf_counter())'; }
a=$(t); cp "$S/tp-src.bin" "$M/big.bin"; b=$(t)
sleep 3; umount "$M"; wait $P 2>/dev/null; rm -rf "$CACHE"            # remount with an empty cache: cold read
"$R" nfsmount "$REMOTE" "$M" --config /dev/null -o locallocks "$@" --nfs-apple-meta-dir "$S/tp-meta" \
  --vfs-cache-mode full --cache-dir "$CACHE" --log-file "$S/tp.log" &
P=$!; for i in $(seq 1 20); do mount | grep -qF " $M " && break; sleep 0.5; done
c=$(t); cat "$M/big.bin" > /dev/null; d=$(t); cat "$M/big.bin" > /dev/null; e=$(t)
umount "$M"; wait $P 2>/dev/null; rm -rf "$CACHE"
python3 -c "
w,rc,rw=$b-$a,$d-$c,$e-$d
print(f'{\"$LABEL\":<28} write {256/w:6.0f} MB/s   read cold {256/rc:6.0f} MB/s   read warm {256/rw:6.0f} MB/s   [{\"$opts\".strip()}]')"
