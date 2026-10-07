#!/usr/bin/env bash
# Saves your Giphy API key in lib/core/giphy_key.dart.
# Usage (from the project root):   bash tools/set_giphy_key.sh YOUR_KEY
set -euo pipefail
KEY="${1:-}"
if [ -z "$KEY" ]; then
  echo "Usage: bash tools/set_giphy_key.sh YOUR_GIPHY_KEY"
  echo "Get a free key: https://developers.giphy.com -> Create an App -> API -> Create"
  exit 1
fi
if ! printf '%s' "$KEY" | grep -Eq '^[A-Za-z0-9]{16,64}$'; then
  echo "ERROR: that does not look like a Giphy key (letters and digits only)."
  exit 1
fi
mkdir -p lib/core
cat > lib/core/giphy_key.dart <<DART
/// Your free Giphy API key (https://developers.giphy.com -> Create an App -> API).
/// Change it with:  bash tools/set_giphy_key.sh NEW_KEY   Leave it empty to hide GIFs.
const String kGiphyKey = '$KEY';
DART
echo "Giphy key saved in lib/core/giphy_key.dart"
