#!/bin/bash
# Run the spike write suite against a drive mounted by the Kitty Finder app, checking
# the real cloud side through that mount's rclone remote control.
# Usage: real-drive.sh "<mount path>"   e.g. "$HOME/Kitty Finder/Google Drive (me@gmail.com)"
set -u
M="$1"; HERE="$(cd "$(dirname "$0")" && pwd)"
PID=$(pgrep -f "rclone nfsmount kd-" | while read -r p; do ps -o command= -p "$p" | grep -qF "$M" && echo "$p"; done | head -1)
[ -n "$PID" ] || { echo "no Kitty Finder mount found for $M"; exit 1; }
CMD=$(ps -o command= -p "$PID")
ENV=$(ps -E -o command= -p "$PID")
export RC_PORT=$(sed -nE 's/.*--rc-addr 127\.0\.0\.1:([0-9]+).*/\1/p' <<<"$CMD")
export RC_USER=$(grep -oE 'RCLONE_RC_USER=[^ ]+' <<<"$ENV" | cut -d= -f2-)
export RC_PASS=$(grep -oE 'RCLONE_RC_PASS=[^ ]+' <<<"$ENV" | cut -d= -f2-)
export RC_FS=$(sed -nE 's/.*nfsmount (kd-[a-z0-9]+:).*/\1/p' <<<"$CMD")
echo "mount pid=$PID remote=$RC_FS rc port=$RC_PORT"
bash "$HERE/spike-tests.sh" "$M" rc
echo "== tidy up test folder"; rm -rf "$M/kd-spike" && echo "removed kd-spike (it goes to Drive's trash)"
