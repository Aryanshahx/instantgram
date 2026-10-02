# Instantgram - Firebase setup checklist

Console: https://console.firebase.google.com  (project: instantgram)

## Fix: "Permission denied. Check your Firestore rules."
This means Firestore refused a request. Almost always the **new rules were never published**,
so the old starter rules (which only know `users` and `usernames`) are still live and deny
`posts`, `stories`, likes, comments and followers.

1. Console -> Build -> Firestore Database -> **Rules** tab.
2. Delete everything in the editor, paste the full contents of `firebase/firestore.rules`.
3. Click **Publish** and check that "Published" shows a time from a few seconds ago.
4. Fully close the app and reopen it.
5. Make sure you are logged in (rules require sign-in for nearly everything).

Photo uploads fail with the same message when `firebase/storage.rules` is not published
(Storage -> Rules tab) or Storage is not set up yet.

Still denied? Which screen shows it tells you which rule is the problem:
* Feed / Explore / Clips empty with the error -> `posts` rules or the Rules tab was not published.
* Sign up fails -> `users` / `usernames` rules.
* Photo upload fails -> `storage.rules`.

Test only (INSECURE, put the real rules back afterwards): replace the rules with
`rules_version = '2'; service cloud.firestore { match /databases/{db}/documents { match /{document=**} { allow read, write: if request.auth != null; } } }`.
If the error disappears, the real rules were not the ones published.

## Optional: publish rules and indexes from the terminal
`firebase.json` and `firebase/firestore.indexes.json` are included, so one command can push the
rules AND both indexes (instead of clicking in the console).

```
sudo apt install -y nodejs npm
sudo npm install -g firebase-tools
firebase login --no-localhost
firebase use --add
firebase deploy --only firestore
```

Run `firebase deploy --only storage` as well once Storage is set up.

## 1. Authentication
Build -> Authentication -> Sign-in method -> **Email/Password** -> Enable.

## 2. Firestore rules
Build -> Firestore Database -> **Rules** tab -> paste the contents of
`firebase/firestore.rules` -> **Publish**.

## 3. Firestore composite indexes (REQUIRED, one-time)
Build -> Firestore Database -> **Indexes** -> Composite -> **Add index**.
Create both, query scope = **Collection**, then wait until each shows *Enabled* (1-5 min):

| Collection ID | Field 1            | Field 2              |
|---------------|--------------------|----------------------|
| `posts`       | `authorId` Ascending | `createdAt` Descending |
| `posts`       | `type` Ascending     | `createdAt` Descending |

* Index 1 powers the profile grid and the "Following" feed.
* Index 2 powers the Clips tab.

If a screen says "A Firestore index is missing", one of these is not created/enabled yet.

## 4. Storage (photos, avatars, stories)
Build -> Storage -> Get started. New projects need the **Blaze** plan
(a card is required, but the free allowance is ~5 GB stored / 1 GB per day download).
* Pick a free-tier region: `us-central1`, `us-east1` or `us-west1`.
* Open the **Rules** tab -> paste `firebase/storage.rules` -> **Publish**.
* Google Cloud console -> Billing -> **Budgets & alerts** -> add a small budget (e.g. Rs 100) so you get an email before any charge.

## 5. Optional: auto-delete expired stories from Storage
Stories vanish from the app after 24 h, but the image files stay in Storage.
In Google Cloud console -> Cloud Storage -> your bucket -> **Lifecycle** -> add rule:
Delete object, Age = 2 days, prefix `stories/`.

## What lives where
| Data                                   | Where                         |
|----------------------------------------|-------------------------------|
| usernames, bios, captions, comments, likes, followers | Firestore (text only)  |
| profile pictures, photo posts, stories | Firebase Storage (compressed on the phone first) |
| videos / reels                         | NOT stored. Only the YouTube/TikTok/Instagram link (text) is saved in Firestore |
