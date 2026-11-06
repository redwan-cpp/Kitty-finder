#!/bin/bash
# Put the Google client secret currently on the clipboard into Config/GoogleOAuth.plist
# without printing it, then clear the clipboard. Use right after clicking the copy
# icon next to a new secret in Google Cloud Console (Google shows a secret only once).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/Config/GoogleOAuth.plist"
pbpaste | python3 -I -c '
import plistlib, sys
secret = sys.stdin.read().strip()
if not secret.startswith("GOCSPX-") or any(c.isspace() for c in secret):
    sys.exit("The clipboard does not hold a Google client secret (expected GOCSPX-...). Nothing changed.")
path = sys.argv[1]
data = plistlib.load(open(path, "rb"))
data["ClientSecret"] = secret
with open(path, "wb") as f:
    plistlib.dump(data, f)
print("saved secret ending ..." + secret[-4:] + " into " + path)
' "$PLIST"
chmod 600 "$PLIST"
printf '' | pbcopy
echo "clipboard cleared"
