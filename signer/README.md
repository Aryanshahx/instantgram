# Instantgram media signer (Vercel + Tigris)

Photos, avatars, moments and videos are stored in a **Tigris** bucket (S3 compatible, no download
fees). Nothing has to run on your own computer: the Raspberry Pi can be off.

```
App --(Firebase login)--> /api/sign    -> one-time upload link (valid 1 hour)
App ---------------------- PUT file ---> Tigris bucket   (straight from the phone, original quality)
App --(Firebase login)--> /api/confirm -> checks size + real file type, deletes bad files
App <---------------- public address --- Tigris bucket   (photos and videos play from here)
```

* The signer never sees the file, so there is no request size limit and no bandwidth cost.
* Only logged-in users get upload links. Files are stored under `image|video|thumb/<your uid>/...`
  and only the owner can delete them.
* The storage keys live only in Vercel's environment variables. They are never in the app or in git.

## Set it up (once)

```
cd ~/IdeaProjects/instantgram && bash signer/setup.sh
```

The script guides you through the two websites (Tigris console, Vercel), tests the bucket and the
signer, and writes both addresses into `lib/core/config.dart`.

## Limits (set in `lib/core.js`, `LIMITS`)

| What | Limit |
|------|-------|
| photo | 30 MB |
| clip | 300 MB (the app shrinks bigger clips on the phone) |
| thumbnail | 2 MB |

## Cost

Tigris free tier: 5 GB storage, 10,000 uploads and 100,000 reads per month, no download fees. Past
that: $0.02 per GB-month and $0.005 per 1,000 uploads. Vercel Hobby is free. Public buckets need a
payment method on the Tigris account (verification only).

## Good to know

* Files are served exactly as uploaded (no compression), so big photos use more mobile data.
* For a nicer address, connect your own domain to the bucket (Tigris docs: Custom Domains) and run
  `bash tools/set_media_url.sh <signer-url> <your-domain>`.
* Tests: `cd signer && npm test` (needs Node 18+).
* Settings (Vercel -> Settings -> Environment Variables): FIREBASE_PROJECT_ID, TIGRIS_BUCKET,
  TIGRIS_ACCESS_KEY_ID, TIGRIS_SECRET_ACCESS_KEY, OPENVERSE_CLIENT_ID and OPENVERSE_CLIENT_SECRET (music, optional). After changing one,
  Redeploy.

## Music from Openverse

`POST /api/music` searches Openverse (openverse.org), a free search for Creative Commons audio. Its
music is the Jamendo catalogue, streamed from Jamendo. **No sign-up and no key are needed**: it
works as soon as the signer is deployed. Only logged-in users can use it. Tracks with a "No
Derivatives" licence are never asked for (they may not be put under a video). Answers are kept for
ten minutes so the same search is not asked twice.

Without a key Openverse allows about 200 searches per day for the whole server. When that is
used up, the app says "Music search is busy" until the next day. To raise the limit (optional),
register once, in a terminal:

    curl -s -X POST https://api.openverse.org/v1/auth_tokens/register/ \
      -H "Content-Type: application/json" \
      -d '{"name":"InstantGram","description":"Music search for a social app","email":"YOUR_EMAIL"}'

It prints a `client_id` and a `client_secret`; open the verification email it sends you. Then add
both in Vercel (Settings -> Environment Variables) as `OPENVERSE_CLIENT_ID` and
`OPENVERSE_CLIENT_SECRET`, and Redeploy. `<signer>/api/health` then shows `"musicKey":true`.
