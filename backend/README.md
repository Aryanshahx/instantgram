# InstantGram backend (Vercel + Tigris)

Tiny API that gives the app **signed upload links** for Tigris storage.

| Endpoint | What it does |
|---|---|
| `GET /api/health` | Shows if all settings are filled in |
| `POST /api/upload-url` | `{kind, contentType, size}` → `{uploadUrl, publicUrl, key, headers}` |
| `POST /api/delete-media` | `{key}` → deletes your own file |
| `POST /api/multipart` | big videos: `create` → part links, `complete`, `abort`, `sign` (new links for missing parts = resume after a break) |
| `POST /api/gifs` | `{q, offset}` → GIF search for comments (GIPHY). Empty `q` = trending |
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
**Create an App** → **API** → copy the key. Without it, only GIFs from the phone gallery work.

Optional: `TIGRIS_ENDPOINT` (default `https://t3.storage.dev`),
`PUBLIC_MEDIA_BASE_URL` (default `https://BUCKET.t3.tigrisfiles.io`).

4. **Deploy**. Test: `curl https://YOUR-APP.vercel.app/api/health` → `"ok": true`.
