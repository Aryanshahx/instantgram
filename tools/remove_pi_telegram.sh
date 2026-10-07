#!/usr/bin/env bash
# =============================================================================
# Removes the old Telegram media server from THIS machine (the Raspberry Pi).
#   * stops and deletes the instantgram-media service
#   * turns off the Tailscale Funnel (and, if you agree, uninstalls Tailscale)
#   * deletes the media-server/ folder, including its .env keys and Telegram login session
# Safe to run again. Nothing here touches your Firebase data.
#   bash tools/remove_pi_telegram.sh        (asks first)
#   bash tools/remove_pi_telegram.sh -y     (no questions; keeps Tailscale installed)
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
YES=0
[ "${1:-}" = "-y" ] && YES=1

UNIT="/etc/systemd/system/instantgram-media.service"
HAS_UNIT=0; [ -f "$UNIT" ] && HAS_UNIT=1
HAS_DIR=0;  [ -d media-server ] && HAS_DIR=1
HAS_TS=0;   command -v tailscale >/dev/null 2>&1 && HAS_TS=1

echo "This will remove the Telegram media server from this machine:"
[ "$HAS_UNIT" = 1 ] && echo "  - service      instantgram-media (stop, disable, delete)"
[ "$HAS_TS"   = 1 ] && echo "  - tailscale    turn off the Funnel (you will be asked about uninstalling)"
[ "$HAS_DIR"  = 1 ] && echo "  - folder       $ROOT/media-server (keys, Telegram session, cache)"
if [ "$HAS_UNIT$HAS_TS$HAS_DIR" = "000" ]; then
  echo "  (nothing found - it is already removed)"
  exit 0
fi
echo
if [ "$YES" = 0 ]; then
  read -r -p "Remove it now? [Y/n] " A || A=""
  case "${A:-Y}" in n|N) echo "Skipped. Run later:  bash tools/remove_pi_telegram.sh"; exit 0 ;; esac
fi

# 1. service ------------------------------------------------------------------
if [ "$HAS_UNIT" = 1 ]; then
  echo "==> Stopping the service"
  sudo systemctl disable --now instantgram-media 2>/dev/null || true
  sudo rm -f "$UNIT"
  sudo systemctl daemon-reload || true
  sudo systemctl reset-failed instantgram-media 2>/dev/null || true
fi
# a copy started by hand (not as a service)
pkill -f "$ROOT/media-server/.venv/bin" 2>/dev/null || true

# 2. tailscale funnel ------------------------------------------------------------
if [ "$HAS_TS" = 1 ]; then
  echo "==> Turning off the Tailscale Funnel"
  sudo tailscale funnel reset 2>/dev/null || sudo tailscale funnel off 2>/dev/null || true
  UNINSTALL="Y"
  if [ "$YES" = 0 ]; then
    echo "Tailscale was only needed to publish the media server."
    read -r -p "Uninstall Tailscale too? Say n if you use it for anything else. [Y/n] " UNINSTALL || UNINSTALL=""
  else
    UNINSTALL="n"
  fi
  case "${UNINSTALL:-Y}" in
    n|N) echo "    Tailscale stays installed (Funnel is off)." ;;
    *)
      echo "==> Uninstalling Tailscale"
      sudo tailscale logout 2>/dev/null || true
      sudo systemctl disable --now tailscaled 2>/dev/null || true
      if command -v apt-get >/dev/null; then
        sudo apt-get purge -y tailscale 2>/dev/null || true
        sudo rm -f /etc/apt/sources.list.d/tailscale.list /usr/share/keyrings/tailscale-archive-keyring.gpg
      fi
      ;;
  esac
fi

# 3. files -----------------------------------------------------------------------
if [ "$HAS_DIR" = 1 ]; then
  echo "==> Deleting media-server/ (secrets are wiped first)"
  find media-server \( -name '.env' -o -name '*.session*' \) -type f -exec shred -u {} \; 2>/dev/null || true
  rm -rf media-server
fi
if [ -f .gitignore ]; then
  sed -i '/^media-server\//d' .gitignore
fi

cat <<'DONE'

 -----------------------------------------------------------------------------
 The Raspberry Pi no longer runs any Telegram server.

 Two things only you can do (in the Telegram app):
   1. Delete the bot:   chat with @BotFather -> /deletebot -> choose your bot
   2. Delete the private channel you used for storage
      (Settings -> Devices: also end any session called after your app)

 Optional: sudo apt remove -y ffmpeg   (the server used it; nothing else here needs it)
 -----------------------------------------------------------------------------
DONE
