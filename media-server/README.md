# Instantgram media server (Telegram storage)

Videos and photos live in your **private Telegram channel**. This small server sits between
the app and Telegram: it checks the Firebase login, uploads files to the channel through
MTProto (no 20 MB limit) and streams them back with Range support, so the app can play them
in its own native video player.

```
App ──(Firebase token)──▶ media server ──(MTProto, bot)──▶ private channel
App ◀──── /m/<handle> (stream, seek) ───┘
```

The bot token never leaves the server. The app only knows a signed handle per file.

## What you need (one time)
1. **Bot**: in Telegram open @BotFather, send `/newbot`, copy the **token**.
2. **API keys**: log in at my.telegram.org, open *API development tools*, create an app,
   copy **api_id** and **api_hash**.
3. **Channel**: open your private channel, Manage channel, Administrators, Add administrator,
   pick your bot, allow *Post messages* and *Delete messages*.
4. **Channel ID**: open the channel in Telegram Web (web.telegram.org/k). The address ends with
   `#-1001234567890`. That number (with the minus) is the CHANNEL_ID.

## Install (on the Raspberry Pi, from the project folder)
    bash media-server/install.sh

It asks for the four values, runs a self-test against Telegram, then installs a background
service (`instantgram-media`). Then expose it with Tailscale Funnel (printed at the end).

## Point the app at the server
After `install.sh` and the Tailscale Funnel step you have an address that starts with `https://`.
From the project folder run `bash tools/set_media_url.sh`, paste the address, then commit and push.

## Everyday commands
    sudo systemctl status instantgram-media
    journalctl -u instantgram-media -f
    sudo systemctl restart instantgram-media
    media-server/.venv/bin/python media-server/app.py check

## Limits and good to know
* Upload limit: 120 MB video / 15 MB photo (edit `.env`), 40 uploads per user per hour.
* Everything streams through this machine: the Pi's home upload speed is the limit.
  Move the same folder to any always-on Linux server later; only the public address changes.
* If the channel or bot is ever banned or deleted, the media is lost. Keep it a hobby / MVP storage.
* Tests (no Telegram needed): `.venv/bin/pip install pytest && .venv/bin/python -m pytest media-server/tests`
