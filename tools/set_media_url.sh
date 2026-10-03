#!/usr/bin/env bash
# Puts your media addresses into lib/core/config.dart.
# Usage:  bash tools/set_media_url.sh                      (asks for both)
#         bash tools/set_media_url.sh <signer-url> <public-url>
# signer/setup.sh runs this for you.
set -euo pipefail
cd "$(dirname "$0")/.."
FILE="lib/core/config.dart"
[ -f "$FILE" ] || { echo "ERROR: $FILE not found. Run this from the project (v1.4.0 installed?)."; exit 1; }

API="${1:-}"
PUB="${2:-}"
if [ -z "$API" ]; then
  read -r -p "Signer address (https://<name>.vercel.app/api): " API || API=""
fi
if [ -z "$PUB" ]; then
  read -r -p "Public bucket address (https://<bucket>.t3.tigrisfiles.io): " PUB || PUB=""
fi
clean() { local v="${1//[[:space:]]/}"; printf '%s' "${v%/}"; }
API="$(clean "$API")"
PUB="$(clean "$PUB")"
for v in "$API" "$PUB"; do
  case "$v" in
    https://*) ;;
    *) echo "ERROR: both addresses must start with https:// (Android blocks plain http)."; exit 1 ;;
  esac
done

python3 - "$FILE" "$API" "$PUB" <<'PY'
import re, sys
path, api, pub = sys.argv[1], sys.argv[2].replace("'", ""), sys.argv[3].replace("'", "")
s = open(path).read()
for name, val in (("kMediaApiUrl", api), ("kMediaPublicUrl", pub)):
    s, n = re.subn(r"const String " + name + r" = '[^']*';",
                   lambda m, name=name, val=val: "const String " + name + " = '" + val + "';", s)
    if n != 1:
        sys.exit("ERROR: could not find " + name + " in " + path)
open(path, "w").write(s)
PY
echo "Saved:"
echo "  uploads : $API"
echo "  files   : $PUB"

if command -v curl >/dev/null; then
  if OUT="$(curl -fsS --max-time 10 "$API/health" 2>/dev/null)"; then
    echo "Signer answered: $OUT"
  else
    echo "Note: the signer did not answer at $API/health yet."
  fi
fi
echo "Now commit and push so the next APK build uses it."
