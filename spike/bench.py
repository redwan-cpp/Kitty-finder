#!/usr/bin/env python3 -I
"""Benchmark a Kitty Finder drive: browsing, opening, copying in, renaming, deleting.

Usage: spike/bench.py "<mount path>" <label>   e.g. "$HOME/Kitty Finder/Google Drive (me@gmail.com)" baseline

Works only inside a new kd-bench-<label>-<time> folder in the drive, which it removes at the end (to the
Drive trash). Test files are seeded through the mount's rclone remote control, so
the first reads are genuinely cold. Only timings are printed, never your file names.
"""
import base64, json, os, re, shutil, subprocess, sys, tempfile, time, urllib.request

MOUNT, LABEL = sys.argv[1], sys.argv[2]
SMALL_COUNT, SMALL_SIZE, LARGE_SIZE = 100, 8 * 1024, 64 * 1024 * 1024


def find_engine():
    for pid in subprocess.run(["pgrep", "-f", "rclone nfsmount kd-"], capture_output=True, text=True).stdout.split():
        cmd = subprocess.run(["ps", "-o", "command=", "-p", pid], capture_output=True, text=True).stdout
        if MOUNT not in cmd:
            continue
        env = subprocess.run(["ps", "-E", "-o", "command=", "-p", pid], capture_output=True, text=True).stdout
        return {
            "port": re.search(r"--rc-addr 127\.0\.0\.1:(\d+)", cmd).group(1),
            "user": re.search(r"RCLONE_RC_USER=(\S+)", env).group(1),
            "pass": re.search(r"RCLONE_RC_PASS=(\S+)", env).group(1),
            "fs": re.search(r"nfsmount (kd-[a-z0-9]+:)", cmd).group(1),
        }
    sys.exit(f"no Kitty Finder engine is serving {MOUNT}")


E = find_engine()


def rc(method, **params):
    req = urllib.request.Request(f"http://127.0.0.1:{E['port']}/{method}", data=json.dumps(params).encode(),
                                 headers={"Content-Type": "application/json"})
    req.add_header("Authorization", "Basic " + base64.b64encode(f"{E['user']}:{E['pass']}".encode()).decode())
    with urllib.request.urlopen(req, timeout=600) as r:
        return json.load(r)


def timed(fn):
    t = time.perf_counter()
    fn()
    return time.perf_counter() - t


def wait_uploaded(timeout=900):
    t = time.perf_counter()
    while time.perf_counter() - t < timeout:
        d = rc("vfs/stats")["diskCache"]
        if d["uploadsInProgress"] + d["uploadsQueued"] == 0:
            return time.perf_counter() - t
        time.sleep(0.25)
    return float("nan")


def read_all(path, first_chunk_timer=None):
    with open(path, "rb", buffering=0) as f:
        chunk = f.read(65536)
        if first_chunk_timer is not None:
            first_chunk_timer.append(time.perf_counter())
        while chunk:
            chunk = f.read(1 << 20)


def browse(path):
    with os.scandir(path) as it:
        for e in it:
            try:
                e.stat()  # Finder stats every item
            except FileNotFoundError:
                pass  # changed on Drive while listing


results = {}
local = tempfile.mkdtemp(prefix="kf-bench-")
try:
    small = os.path.join(local, "small"); os.mkdir(small)
    for i in range(SMALL_COUNT):
        with open(os.path.join(small, f"f{i:03}.txt"), "wb") as f:
            f.write(os.urandom(SMALL_SIZE))
    with open(os.path.join(local, "large.bin"), "wb") as f:
        for _ in range(LARGE_SIZE >> 20):
            f.write(os.urandom(1 << 20))

    # A fresh folder name per run, so no earlier run's cached state can interfere
    base = f"kd-bench-{LABEL}-{int(time.time())}"
    # Root timings before anything is seeded
    rc("vfs/forget")
    time.sleep(1)
    results["browse drive root, cold"] = timed(lambda: browse(MOUNT))
    results["browse drive root, warm"] = timed(lambda: browse(MOUNT))

    # The parent is made through the mount, so macOS knows it at once. The test files are
    # seeded straight to Drive inside it, so the mount has never seen (or cached) them.
    os.mkdir(os.path.join(MOUNT, base))
    wait_uploaded()
    rc("operations/copyfile", srcFs=local, srcRemote="large.bin", dstFs=E["fs"], dstRemote=f"{base}/seed/large.bin")
    rc("sync/copy", srcFs=small, dstFs=f"{E['fs']}{base}/seed/small")
    # Drive's listing lags a little behind uploads: wait until it shows everything
    deadline = time.time() + 120
    while True:
        names = {i["Name"] for i in rc("operations/list", fs=E["fs"], remote=f"{base}/seed")["list"]}
        count = len(rc("operations/list", fs=E["fs"], remote=f"{base}/seed/small")["list"]) if "small" in names else 0
        if {"small", "large.bin"} <= names and count == SMALL_COUNT:
            break
        if time.time() > deadline:
            sys.exit("Drive never listed the seeded files")
        time.sleep(2)
    rc("vfs/refresh", dir=base, dir2=f"{base}/seed")  # rclone learns the names; nothing is listed through the mount yet
    seed = os.path.join(MOUNT, base, "seed")
    if not os.path.isdir(seed):  # a lookup by name goes straight to rclone
        sys.exit("seeded folder not visible on the mount")

    results["browse 100-file folder, cold"] = timed(lambda: browse(os.path.join(seed, "small")))
    results["browse 100-file folder, warm"] = timed(lambda: browse(os.path.join(seed, "small")))

    names = sorted(os.listdir(os.path.join(seed, "small")))[:20]
    results["open 20 small files, cold"] = timed(lambda: [read_all(os.path.join(seed, "small", n)) for n in names])
    results["open 20 small files, warm"] = timed(lambda: [read_all(os.path.join(seed, "small", n)) for n in names])

    first = []
    start = time.perf_counter()
    read_all(os.path.join(seed, "large.bin"), first)
    results["64 MB file: first bytes, cold"] = first[0] - start
    results["64 MB file: full read, cold"] = time.perf_counter() - start
    results["64 MB file: full read, warm"] = timed(lambda: read_all(os.path.join(seed, "large.bin")))

    dest = os.path.join(MOUNT, base, "in")
    os.makedirs(dest)
    results["copy in 100 small files (Finder done)"] = timed(lambda: shutil.copytree(small, os.path.join(dest, "small")))
    results["copy in 100 small files (uploaded)"] = results["copy in 100 small files (Finder done)"] + wait_uploaded()
    results["copy in 64 MB file (Finder done)"] = timed(lambda: shutil.copyfile(os.path.join(local, "large.bin"), os.path.join(dest, "large.bin")))
    results["copy in 64 MB file (uploaded)"] = results["copy in 64 MB file (Finder done)"] + wait_uploaded()

    results["rename folder of 100 files"] = timed(lambda: os.rename(os.path.join(dest, "small"), os.path.join(dest, "renamed")))
    results["delete 100 files"] = timed(lambda: shutil.rmtree(os.path.join(dest, "renamed")))
    wait_uploaded()
finally:
    shutil.rmtree(local, ignore_errors=True)
    try:
        if "base" in globals():
            rc("operations/purge", fs=E["fs"], remote=base)
            rc("vfs/refresh", dir="")  # tell the mount the folder is gone
    except Exception as e:  # noqa: BLE001
        print("cleanup failed:", e)

width = max(map(len, results))
for k, v in results.items():
    print(f"{k:<{width}}  {v:7.2f} s")
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), f"bench-{LABEL}.json")
json.dump(results, open(out, "w"), indent=1)
print("saved", out)
