#!/bin/bash
# Mount the local fake remote with extra flags, run isolate.sh, show what reached the remote, unmount.
# Usage: variant.sh <scratch-dir> <label> [extra rclone flags...]
S="$1"; LABEL="$2"; shift 2
HERE="$(cd "$(dirname "$0")" && pwd)"
M="$S/mnt"; REMOTE="$S/fake-remote"; mkdir -p "$M"
rm -rf "$REMOTE/kd-iso"
echo "######## $LABEL :: $*"
"${RCLONE:-$S/bin/rclone}" nfsmount "$REMOTE" "$M" --config "$S/rclone.conf" \
  --vfs-cache-mode full --vfs-write-back 1s --cache-dir "$S/cache" \
  --daemon --daemon-wait 4s -vv --log-file "$S/variant-$LABEL.log" "$@" \
  || { echo "mount failed"; tail -5 "$S/variant-$LABEL.log"; exit 1; }
mount | grep -F " $M " | sed 's/^/mount: /'
bash "$HERE/isolate.sh" "$M" 2>&1 | grep -E '^(OK|FAIL)' | sed -E 's/ :: .*(could not copy extended attributes|Operation not permitted|Errno [0-9]+[^:]*).*/ :: \1/'
sleep 4
echo "remote kd-iso contents:"; (cd "$REMOTE/kd-iso" 2>/dev/null && find . -mindepth 1 | sort | sed 's/^/   /')
grep -m3 -i 'mount -\|mount_nfs\|exec' "$S/variant-$LABEL.log" | sed 's/^/log: /'
[ -n "${META:-}" ] && { echo "local meta dir:"; (cd "$META" && find . -mindepth 1 | sort | sed "s/^/   /"); }
umount "$M" 2>/dev/null || diskutil unmount force "$M" >/dev/null 2>&1
pkill -f "rclone nfsmount $REMOTE" 2>/dev/null; sleep 1
mount | grep -qF " $M " && echo "WARN still mounted" || echo "(unmounted)"
