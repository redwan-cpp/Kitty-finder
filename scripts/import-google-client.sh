#!/bin/bash
# Import a Google OAuth client JSON (downloaded from Google Cloud Console) into
# Config/GoogleOAuth.plist, which scripts/bundle.sh builds into the app.
# The secret is never printed. The JSON is moved into Config/ (git-ignored).
# Usage: scripts/import-google-client.sh ~/Downloads/client_secret_XXXX.json
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JSON="${1:?usage: import-google-client.sh <client_secret_*.json>}"
mkdir -p "$ROOT/Config"
python3 -I - "$JSON" "$ROOT/Config/GoogleOAuth.plist" <<'PY'
import json, plistlib, sys
src, dst = sys.argv[1], sys.argv[2]
data = json.load(open(src))
client = data.get("installed") or data.get("web") or {}
cid, secret = client.get("client_id", ""), client.get("client_secret", "")
if not cid.endswith(".apps.googleusercontent.com") or not secret.startswith("GOCSPX-"):
    sys.exit("That file doesn't look like a Google OAuth client with a secret.")
with open(dst, "wb") as f:
    plistlib.dump({"ClientID": cid, "ClientSecret": secret}, f)
print(f"imported client {cid.split('-')[0]}-… with secret ending …{secret[-4:]} into {dst}")
PY
chmod 600 "$ROOT/Config/GoogleOAuth.plist"
mv "$JSON" "$ROOT/Config/google-client.json"
chmod 600 "$ROOT/Config/google-client.json"
echo "moved the downloaded file to Config/google-client.json (git-ignored)"
