#!/usr/bin/env bash
# Delete an InstantGram account completely (developer only).
#   bash tools/delete_user.sh setup                  # one time
#   bash tools/delete_user.sh <username|email>       # delete one account
#   bash tools/delete_user.sh --leftovers            # clean accounts deleted earlier
#   add --dry-run to only see what would be removed
set -euo pipefail
cd "$(dirname "$0")/.."
VENV="$HOME/.instantgram-admin/venv"
# reinstall when a first run was cut off (e.g. the download timed out)
if [ ! -x "$VENV/bin/python" ] || ! "$VENV/bin/python" -c "import firebase_admin" 2>/dev/null; then
  rm -rf "$VENV"
  echo "First run: installing the Firebase admin library (one time)…"
  mkdir -p "$HOME/.instantgram-admin" && chmod 700 "$HOME/.instantgram-admin"
  if ! python3 -m venv "$VENV" 2>/dev/null; then
    echo "Needs python3-venv:  sudo apt install -y python3-venv   then run this again."
    rm -rf "$VENV"; exit 1
  fi
  if ! "$VENV/bin/pip" install -q --timeout 120 --retries 10 firebase-admin; then
    echo "Download failed (slow or no internet). Run the same command again in a few minutes."
    rm -rf "$VENV"; exit 1
  fi
fi
exec "$VENV/bin/python" tools/admin/delete_user.py "$@"
