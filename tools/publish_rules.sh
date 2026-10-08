#!/usr/bin/env bash
# Publishes firebase/firestore.rules to Firestore (developer only; no copy-paste in the console):
#   bash tools/publish_rules.sh
set -euo pipefail
cd "$(dirname "$0")/.."
VENV="$HOME/.instantgram-admin/venv"
if [ ! -x "$VENV/bin/python" ] || ! "$VENV/bin/python" -c "import firebase_admin" 2>/dev/null; then
  echo "Run this first (one time):  bash tools/delete_user.sh setup"; exit 1
fi
"$VENV/bin/python" tools/admin/push_setup.py rules
