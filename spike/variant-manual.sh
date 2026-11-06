#!/bin/bash
# Serve the fake remote with `rclone serve nfs` and mount it ourselves with custom mount_nfs options.
# Usage: variant-manual.sh <scratch-dir> <label> <mount_nfs extra opts, comma-separated> [extra rclone flags...]
S="$1"; LABEL="$2"; OPTS="$3"; shift 3
HERE="$(cd "$(dirname "$0")" && pwd)"
M="$S/mnt"; REMOTE="$S/fake-remote"; mkdir -p "$M"; rm -rf "$REMOTE/kd-iso"
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
echo "######## $LABEL :: mount opts=$OPTS rclone=$*"
"$S/bin/rclone" serve nfs "$REMOTE" --addr "127.0.0.1:$PORT" --config "$S/rclone.conf" \
  --vfs-cache-mode full --vfs-write-back 1s --cache-dir "$S/cache" -v --log-file "$S/vm-$LABEL.log" "$@" &
SRV=$!; sleep 2
/sbin/mount_nfs -o "port=$PORT,mountport=$PORT,tcp${OPTS:+,$OPTS}" "localhost:/" "$M" || { echo "mount_nfs failed"; kill $SRV; exit 1; }
mount | grep -F " $M " | sed 's/^/mount: /'
bash "$HERE/isolate.sh" "$M" 2>&1 | grep -E '^(OK|FAIL)' | sed -E 's/ :: .*(could not copy extended attributes|Operation not permitted|Errno [0-9]+[^:]*).*/ :: \1/'
echo "xattr read-back: $(xattr -p com.kd.t "$M/kd-iso/cp-x.txt" 2>&1 | head -1)"
sleep 3
echo "remote kd-iso contents:"; (cd "$REMOTE/kd-iso" 2>/dev/null && find . -mindepth 1 | sort | sed 's/^/   /')
umount "$M" 2>/dev/null || diskutil unmount force "$M" >/dev/null 2>&1
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null
mount | grep -qF " $M " && echo "WARN still mounted" || echo "(unmounted)"
