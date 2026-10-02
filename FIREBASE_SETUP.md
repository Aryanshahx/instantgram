# Instantgram - Firebase setup checklist

Console: https://console.firebase.google.com  (project: instantgram)

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
* Index 2 powers the Reels tab.

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
