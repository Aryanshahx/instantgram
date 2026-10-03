# Instantgram - Firebase setup checklist

Console: https://console.firebase.google.com  (project: instantgram)

Firebase now only does two jobs: **Authentication** and **Firestore (text)**.
Photos, avatars, moments and videos live in a private Telegram channel and go through your own
media server (see `media-server/README.md`). Firebase Storage and the Blaze plan are NOT needed.

## 1. Authentication
Build -> Authentication -> Sign-in method -> **Email/Password** -> Enable.

## 2. Firestore rules
Build -> Firestore Database -> **Rules** tab -> delete everything, paste the full contents of
`firebase/firestore.rules` -> **Publish**. Check that "Published" shows a time from a few seconds ago,
then fully close the app and reopen it.

Fix for "Permission denied. Check your Firestore rules.": the new rules were never published, so
the old starter rules are still live. Which screen shows it tells you what is missing:
* Feed / Discover / Clips empty with the error -> `posts` rules, or the Rules tab was not published.
* Sign up fails -> `users` / `usernames` rules.
* Save button fails -> publish the rules again (the private `saved` list was added in v1.1.1).

## 3. Firestore composite indexes (REQUIRED, one-time)
Build -> Firestore Database -> **Indexes** -> Composite -> **Add index**.
Create both, query scope = **Collection**, then wait until each shows *Enabled* (1-5 min):

| Collection ID | Field 1              | Field 2                |
|---------------|----------------------|------------------------|
| `posts`       | `authorId` Ascending | `createdAt` Descending |
| `posts`       | `type` Ascending     | `createdAt` Descending |

* Index 1 powers the profile grid.
* Index 2 powers the Clips tab.

If a screen says "A Firestore index is missing", one of these is not created/enabled yet.

## 4. Optional: publish rules and indexes from the terminal
```
sudo apt install -y nodejs npm
sudo npm install -g firebase-tools
firebase login --no-localhost
firebase use --add
firebase deploy --only firestore
```

## What lives where
| Data                                                  | Where                                  |
|-------------------------------------------------------|----------------------------------------|
| accounts (email + password)                           | Firebase Authentication                |
| usernames, bios, captions, comments, likes, followers | Firestore (text only)                  |
| photos, avatars, moments, videos, video thumbnails    | Private Telegram channel, via your media server. Firestore keeps only a short reference such as `tg:123-abc...` |

## Old data
Posts made with the old video-link system are hidden automatically (they have no uploaded video).
Photos that were stored in Firebase Storage keep working only if they were ever uploaded there.
