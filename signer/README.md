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
  TIGRIS_ACCESS_KEY_ID, TIGRIS_SECRET_ACCESS_KEY, EPIDEMIC_API_KEY (music). After changing one,
  Redeploy.

## Music from Epidemic Sound

`POST /api/music` searches Epidemic Sound and returns a playable address for a track. The API key
stays here, in the Vercel environment variable `EPIDEMIC_API_KEY`, and is never in the app or in
git. Only logged-in users can use it. Without the key the app still has its built-in music.

1. Vercel -> your project -> Settings -> Environment Variables -> add `EPIDEMIC_API_KEY`.
2. Deployments -> the latest one -> Redeploy.
3. Check in the app: Create > Music > Epidemic Sound, and search for a word like "calm".
