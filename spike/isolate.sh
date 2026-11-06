#!/bin/bash
# Isolate which file operation fails on the nfsmount.
M="$1"; S="$(dirname "$0")"; T="$M/kd-iso"; rm -rf "$T"; mkdir -p "$T"
SRC="$S/iso-src"; rm -rf "$SRC"; mkdir -p "$SRC"; echo data > "$SRC/plain.txt"; echo data > "$SRC/x.txt"; xattr -w com.kd.t v "$SRC/x.txt"
try(){ local name="$1"; shift; if out=$("$@" 2>&1); then echo "OK    $name"; else echo "FAIL  $name :: $out" | head -2; fi; }
try "O_EXCL create"        python3 -c "import os;os.close(os.open('$T/excl.txt',os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o644))"
try "chmod"                chmod 600 "$T/excl.txt"
try "touch -t (utimes)"    touch -t 202001010101 "$T/excl.txt"
try "chown self"           chown "$(id -un)" "$T/excl.txt"
try "xattr -w on mount"    xattr -w com.kd.t v "$T/excl.txt"
try "cp plain (no xattr)"  cp "$SRC/plain.txt" "$T/cp-plain.txt"
try "cp -X xattr file"     cp -X "$SRC/x.txt" "$T/cp-X.txt"
try "cp xattr file"        cp "$SRC/x.txt" "$T/cp-x.txt"
try "cp -p plain"          cp -p "$SRC/plain.txt" "$T/cp-p.txt"
try "ditto plain"          ditto "$SRC/plain.txt" "$T/ditto-plain.txt"
try "ditto --noextattr --noacl --noqtn" ditto --noextattr --noacl --noqtn "$SRC/x.txt" "$T/ditto-noext.txt"
try "ditto xattr file"     ditto "$SRC/x.txt" "$T/ditto-x.txt"
try "mkdir -p nested"      mkdir -p "$T/a/b/c"
try "ditto dir (no xattr files)" bash -c "mkdir -p '$SRC/d/e' && echo q > '$SRC/d/e/q.txt' && ditto '$SRC/d' '$T/ditto-dir'"
echo "--- mount listing:"; (cd "$T" && find . | sort | sed 's/^/   /')
