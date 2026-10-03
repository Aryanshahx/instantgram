#!/usr/bin/env bash
# Puts your media server address into lib/core/config.dart.
# Usage:  bash tools/set_media_url.sh            (asks for it)
#         bash tools/set_media_url.sh https://name.tailnet.ts.net
set -euo pipefail
cd "$(dirname "$0")/.."
FILE="lib/core/config.dart"
[ -f "$FILE" ] || { echo "ERROR: $FILE not found. Run this from the project (v1.2.0 installed?)."; exit 1; }

URL="${1:-}"
if [ -z "$URL" ]; then
  read -r -p "Paste your media server address (starts with https://): " URL || URL=""
fi
URL="${URL//[[:space:]]/}"
URL="${URL%/}"
case "$URL" in
  https://*) ;;
  *) echo "ERROR: the address must start with https:// (Android blocks plain http)."; exit 1 ;;
esac

python3 - "$FILE" "$URL" <<'PY'
import re, sys
path, url = sys.argv[1], sys.argv[2]
s = open(path).read()
s, n = re.subn(r"const String kMediaServerUrl = '[^']*';",
               "const String kMediaServerUrl = '" + url.replace("'", "") + "';", s)
if n != 1:
    sys.exit("ERROR: could not find kMediaServerUrl in " + path)
open(path, "w").write(s)
PY
echo "Saved: $URL"

if command -v curl >/dev/null; then
  if OUT="$(curl -fsS --max-time 10 "$URL/health" 2>/dev/null)"; then
    echo "Server answered: $OUT"
  else
    echo "Note: the server did not answer at $URL/health yet. Check the service and the tailscale funnel."
  fi
fi
echo "Now commit and push so the next APK build uses it."
