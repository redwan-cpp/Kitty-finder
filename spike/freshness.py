#!/usr/bin/env python3 -I
"""How long until a folder created on Drive (not through the mount) shows up in Finder?

Usage: spike/freshness.py "<mount path>" [seconds]
Creates and removes kd-probe-<n> at the drive root via the mount's rclone remote control.
"""
import base64, json, os, re, subprocess, sys, time, urllib.request

MOUNT = sys.argv[1]
LIMIT = int(sys.argv[2]) if len(sys.argv) > 2 else 150


def engine():
    for pid in subprocess.run(["pgrep", "-f", "rclone nfsmount kd-"], capture_output=True, text=True).stdout.split():
        cmd = subprocess.run(["ps", "-o", "command=", "-p", pid], capture_output=True, text=True).stdout
        if MOUNT in cmd:
            env = subprocess.run(["ps", "-E", "-o", "command=", "-p", pid], capture_output=True, text=True).stdout
            return (re.search(r"--rc-addr 127\.0\.0\.1:(\d+)", cmd).group(1), re.search(r"RCLONE_RC_USER=(\S+)", env).group(1),
                    re.search(r"RCLONE_RC_PASS=(\S+)", env).group(1), re.search(r"nfsmount (kd-[a-z0-9]+:)", cmd).group(1))
    sys.exit("no engine for " + MOUNT)


PORT, USER, PASS, FS = engine()


def rc(method, **params):
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}/{method}", data=json.dumps(params).encode(),
                                 headers={"Content-Type": "application/json",
                                          "Authorization": "Basic " + base64.b64encode(f"{USER}:{PASS}".encode()).decode()})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)


name = f"kd-probe-{int(time.time())}"
os.listdir(MOUNT)  # Finder has the root open
before = os.stat(MOUNT).st_mtime
rc("operations/mkdir", fs=FS, remote=name)
start = time.time()
seen = None
try:
    while time.time() - start < LIMIT:
        listed = name in os.listdir(MOUNT)
        mtime = os.stat(MOUNT).st_mtime
        t = time.time() - start
        if listed:
            seen = t
            break
        if int(t) % 15 == 0:
            print(f"  {t:5.0f}s  not visible yet (root mtime changed: {mtime != before})")
        time.sleep(1)
finally:
    rc("operations/rmdir", fs=FS, remote=name)
print(f"visible after {seen:.0f}s" if seen is not None else f"NOT visible after {LIMIT}s")
