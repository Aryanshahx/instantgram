#!/usr/bin/env bash
# Push notifications, one time (developer only):
#   bash tools/push_setup.sh
# 1. publishes firebase/firestore.rules (the phones may now store their push address)
# 2. writes the value for the Vercel setting FIREBASE_SERVICE_ACCOUNT and opens it
set -euo pipefail
cd "$(dirname "$0")/.."
VENV="$HOME/.instantgram-admin/venv"
if [ ! -x "$VENV/bin/python" ] || ! "$VENV/bin/python" -c "import firebase_admin" 2>/dev/null; then
  echo "Run this first (one time):  bash tools/delete_user.sh setup"; exit 1
fi
"$VENV/bin/python" tools/admin/push_setup.py rules
"$VENV/bin/python" tools/admin/push_setup.py key
F="$HOME/.instantgram-admin/vercel_push_key.txt"
echo ""
echo "Now in the Vercel dashboard (your signer project) > Settings > Environment Variables:"
echo "  Key:   FIREBASE_SERVICE_ACCOUNT"
echo "  Value: everything in the file that just opened (one long line)"
echo "Save, then Deployments > ... > Redeploy."
echo "Do not paste this value anywhere else - it is a password."
if command -v xdg-open >/dev/null 2>&1; then xdg-open "$F" >/dev/null 2>&1 || true; fi
if command -v xclip >/dev/null 2>&1; then xclip -selection clipboard < "$F" && echo "(It is also copied: just press Ctrl+V in Vercel.)"; fi
