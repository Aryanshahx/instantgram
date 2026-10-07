#!/usr/bin/env bash
# Saves your Agora App ID (voice and video calls) in lib/core/agora_key.dart.
# Usage (from the project root):   bash tools/set_agora_id.sh YOUR_APP_ID
set -euo pipefail
ID="${1:-}"
if [ -z "$ID" ]; then
  echo "Usage: bash tools/set_agora_id.sh YOUR_AGORA_APP_ID"
  echo "Get one free: console.agora.io -> Projects -> Create -> choose 'Testing mode: APP ID'"
  exit 1
fi
if ! printf '%s' "$ID" | grep -Eq '^[A-Fa-f0-9]{32}$'; then
  echo "ERROR: an Agora App ID is 32 letters and digits (0-9, a-f)."
  exit 1
fi
mkdir -p lib/core
cat > lib/core/agora_key.dart <<DART
/// Your Agora App ID for voice and video calls (console.agora.io).
/// Change it with:  bash tools/set_agora_id.sh NEW_ID   Leave it empty to turn calls off.
const String kAgoraAppId = '$ID';
DART
echo "Agora App ID saved in lib/core/agora_key.dart"
