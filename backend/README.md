# InstantGram backend (Vercel + Tigris)

Tiny API that gives the app **signed upload links** for Tigris storage.

| Endpoint | What it does |
|---|---|
| `GET /api/health` | Shows if all settings are filled in |
| `POST /api/upload-url` | `{kind, contentType, size}` → `{uploadUrl, publicUrl, key, headers}` |
| `POST /api/delete-media` | `{key}` → deletes your own file |
| `POST /api/multipart` | big videos: `create` → part links, `complete`, `abort`, `sign` (new links for missing parts = resume after a break) |
| `POST /api/gifs` | `{q, offset}` → GIF search for comments (GIPHY). Empty `q` = trending |
| `POST /api/turn` | `{}` → STUN/TURN servers for calls (ExpressTURN / Metered / Cloudflare when set) |
| `POST /api/call-push` | `{callId, action: ring\|cancel}` → makes the called phone ring (FCM), also when the app is closed (muted calls = quiet notification); `{action: test}` rings your own phone after 6 s |
| `POST /api/message-push` | `{chatId, messageId}` → "username: message" notification for the other person (not when they muted the chat) |
| `GET /u/<username>` | profile link page with **Open in InstantGram** (used by QR codes) |

All POST calls need `Authorization: Bearer <Firebase ID token>`.

Limits: photos 15 MB, videos 500 MB. Kinds: `post`, `clip`, `story`, `avatar`, `cover`, `thumb`, `audio`, `comment`.

## 1. Tigris
1. Open https://console.storage.dev and sign in.
2. **Create bucket** → name e.g. `instantgram-media` (no dots) → access: **Public**.
3. **Access keys** → **Create access key** → copy the *Access Key ID* and *Secret Access Key*.

## 2. Vercel
1. https://vercel.com/new → import the GitHub repo.
2. **Root Directory** → `backend`.
3. **Environment Variables**:

| Name | Value |
|---|---|
| `TIGRIS_ACCESS_KEY_ID` | from Tigris |
| `TIGRIS_SECRET_ACCESS_KEY` | from Tigris |
| `TIGRIS_BUCKET` | your bucket name |
| `FIREBASE_PROJECT_ID` | your Firebase project id |

Optional: `GIPHY_API_KEY` — GIF search in comments. Free key: https://developers.giphy.com →
**Create an App** → **API** → copy the key.

Calls (v0.10):
- TURN — calls also work on mobile data. Set one (or more) of these, no card needed for the first two:
  - **ExpressTURN** (free 1000 GB / month): sign up at https://www.expressturn.com → dashboard →
    `TURN_SERVER` (e.g. `relay1.expressturn.com:3478`), `TURN_USERNAME`, `TURN_PASSWORD`.
    Works with any TURN server (comma list or full `turn:` urls also OK).
  - **Metered Open Relay** (free 20 GB / month): https://www.metered.ca/tools/openrelay/ →
    `METERED_DOMAIN` (e.g. `instantgram.metered.live`) + `METERED_API_KEY`.
  - **Cloudflare** (needs a card): `CLOUDFLARE_TURN_KEY_ID` + `CLOUDFLARE_TURN_API_TOKEN`.
  - Check: open `/api/health` → `features.turnServices` lists what is set.
- `FIREBASE_SERVICE_ACCOUNT` — the phone rings when the app is closed. Firebase console →
  ⚙ **Project settings** → **Service accounts** → **Generate new private key** → paste the whole file text.

Optional: `TIGRIS_ENDPOINT` (default `https://t3.storage.dev`),
`PUBLIC_MEDIA_BASE_URL` (default `https://BUCKET.t3.tigrisfiles.io`).

4. **Deploy**. Test: `curl https://YOUR-APP.vercel.app/api/health` → `"ok": true`.
