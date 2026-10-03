#!/usr/bin/env bash
# Installs the Instantgram media server (Telegram storage) on this machine.
# Usage:  bash media-server/install.sh            (interactive)
#         bash media-server/install.sh --no-service
set -euo pipefail
cd "$(dirname "$0")"
SERVER_DIR="$(pwd)"
PROJECT_ROOT="$(cd .. && pwd)"
NO_SERVICE=0
[ "${1:-}" = "--no-service" ] && NO_SERVICE=1

say() { printf '\n==> %s\n' "$*"; }
ask() { # ask VAR "Prompt text"   (uses an already exported VAR if present)
  local var="$1" prompt="$2" val="${!1:-}"
  if [ -z "$val" ]; then
    read -r -p "$prompt: " val || val=""
  fi
  [ -n "$val" ] || { echo "ERROR: $var is required."; exit 1; }
  printf -v "$var" '%s' "$val"
}

say "Checking Python..."
command -v python3 >/dev/null || { echo "ERROR: python3 not found. Run: sudo apt install -y python3 python3-venv"; exit 1; }
if ! python3 -m venv .venv 2>/dev/null; then
  echo "Installing python3-venv (needs sudo)..."
  sudo apt-get update -y && sudo apt-get install -y python3-venv python3-pip
  rm -rf .venv && python3 -m venv .venv
fi

if ! command -v ffmpeg >/dev/null; then
  say "ffmpeg is optional (fast video start + automatic thumbnails)."
  read -r -p "Install ffmpeg now? [Y/n] " yn || yn=""
  case "${yn:-Y}" in n|N) ;; *) sudo apt-get install -y ffmpeg || echo "(ffmpeg install failed, continuing without it)";; esac
fi

say "Installing Python packages (a few minutes on a Raspberry Pi)..."
.venv/bin/pip install --upgrade pip >/dev/null
.venv/bin/pip install -r requirements.txt

if [ -f .env ]; then
  read -r -p "An .env already exists. Keep it? [Y/n] " keep || keep=""
  case "${keep:-Y}" in n|N) mv .env ".env.old.$(date +%s)";; esac
fi

if [ ! -f .env ]; then
  say "Telegram settings (see media-server/README.md for where to find each one)"
  ask API_ID   "API_ID   (number from my.telegram.org)"
  ask API_HASH "API_HASH (from my.telegram.org)"
  ask BOT_TOKEN "BOT_TOKEN (from @BotFather)"
  ask CHANNEL_ID "CHANNEL_ID (private channel, looks like -1001234567890)"
  case "$CHANNEL_ID" in
    -100*) ;;
    -*)    CHANNEL_ID="-100${CHANNEL_ID#-}" ;;
    *)     CHANNEL_ID="-100${CHANNEL_ID}" ;;
  esac
  GS="$PROJECT_ROOT/android/app/google-services.json"
  FIREBASE_PROJECT_ID="${FIREBASE_PROJECT_ID:-}"
  if [ -z "$FIREBASE_PROJECT_ID" ] && [ -f "$GS" ]; then
    FIREBASE_PROJECT_ID="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['project_info']['project_id'])" "$GS")"
    echo "Firebase project: $FIREBASE_PROJECT_ID (read from google-services.json)"
  fi
  ask FIREBASE_PROJECT_ID "FIREBASE_PROJECT_ID"
  SIGNING_SECRET="$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')"
  umask 077
  cat > .env <<ENVEOF
API_ID=$API_ID
API_HASH=$API_HASH
BOT_TOKEN=$BOT_TOKEN
CHANNEL_ID=$CHANNEL_ID
FIREBASE_PROJECT_ID=$FIREBASE_PROJECT_ID
SIGNING_SECRET=$SIGNING_SECRET
MAX_VIDEO_MB=120
MAX_IMAGE_MB=15
UPLOADS_PER_HOUR=40
ENVEOF
  chmod 600 .env
  echo ".env written (kept private, never committed)."
fi

say "Self-test: log in as the bot, upload a test file, stream part of it back, delete it..."
if ! .venv/bin/python app.py check; then
  echo
  echo "The self-test failed. Fix the problem above, then run this installer again."
  echo "Common causes: wrong BOT_TOKEN / API_ID, or the bot is not an ADMIN of the channel."
  exit 1
fi
chmod 600 media.session* 2>/dev/null || true

if [ "$NO_SERVICE" = "1" ] || ! command -v systemctl >/dev/null || [ ! -d /run/systemd/system ]; then
  say "Skipping the background service. Start the server manually with:"
  echo "  cd $SERVER_DIR && .venv/bin/uvicorn app:app --host 127.0.0.1 --port 8000"
else
  say "Installing the background service (needs sudo)..."
  sudo tee /etc/systemd/system/instantgram-media.service >/dev/null <<UNIT
[Unit]
Description=Instantgram media server (Telegram storage)
After=network-online.target
Wants=network-online.target

[Service]
User=$(id -un)
WorkingDirectory=$SERVER_DIR
EnvironmentFile=$SERVER_DIR/.env
ExecStart=$SERVER_DIR/.venv/bin/uvicorn app:app --host 127.0.0.1 --port 8000 --workers 1
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl daemon-reload
  sudo systemctl enable --now instantgram-media
  for _ in $(seq 1 30); do
    if curl -fsS http://127.0.0.1:8000/health >/dev/null 2>&1; then OK=1; break; fi
    sleep 1
  done
  if [ "${OK:-0}" = "1" ]; then echo "Server is running: $(curl -fsS http://127.0.0.1:8000/health)"
  else echo "Server did not answer yet. Look at:  journalctl -u instantgram-media -n 50 --no-pager"; fi
fi

cat <<'NEXT'

 -----------------------------------------------------------------------------
 Server installed. Last step: give it a public HTTPS address (free, no card).

   curl -fsSL https://tailscale.com/install.sh | sh
   sudo tailscale up
   sudo tailscale funnel --bg 8000
   tailscale funnel status

 The last command prints your address (https://<name>.<tailnet>.ts.net).
 If it asks you to enable Funnel / HTTPS, open the link it prints and click enable.

 Then put that address into the app:   bash tools/set_media_url.sh
 -----------------------------------------------------------------------------
NEXT
