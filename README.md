# InstantGram 📸

An Instagram-like app built with **Flutter**.

## Stack
| Part | Service |
|---|---|
| Mobile app | Flutter (Android) |
| APK builds | GitHub Actions |
| Auth + Database | Firebase Auth + Cloud Firestore |
| Backend API | Vercel (`backend/`) |
| Media storage | Tigris (S3-compatible, public bucket) |

## How uploads work
1. App asks the Vercel API for an upload link (`POST /api/upload-url`, with the Firebase login token).
2. API checks the token, file type and size, then returns a signed Tigris link (valid 10 min).
3. App uploads the file straight to Tigris and saves the public URL in Firestore.

## Features (v0.3)
- Sign up / log in (email or username)
- Feed of people you follow (everyone's latest posts when you follow nobody yet)
- Photo posts, Clips (short videos), Stories (24h)
- Likes (double-tap too), comments, reposts, saves, share
- Pin / delete your posts, clip insights, dashboard with real stats
- Follow / unfollow, followers & following lists, user search
- Direct messages
- Notifications (likes, comments, follows, reposts)
- Edit profile, profile photo and cover

## Download the APK
- **Every push to `main`** → Actions tab → latest run → *Artifacts* → `InstantGram-apk-N`
- **Releases** → push a tag like `v0.3.0` → APK appears under *Releases*

## Setup
### Firebase
- `lib/firebase_options.dart` and `android/app/google-services.json` come from `flutterfire configure`
  (safe to commit — they are app identifiers, not secrets).
- Database rules + indexes: `firebase deploy --only firestore --project YOUR_PROJECT_ID`

### Tigris + Vercel
See [`backend/README.md`](backend/README.md).
Then set the GitHub repo variable **`API_BASE_URL`** = your Vercel URL
(Settings → Secrets and variables → Actions → Variables), or put it in `lib/core/config/api_url.dart`.

## Project structure
```
lib/
├── core/        # config, services (API, uploads), theme, utils
├── features/    # auth, feed, post, stories, reels, search, chats, notifications, profile, dashboard
└── shared/      # models, widgets, navigation
backend/         # Vercel API (signed Tigris uploads)
firestore.rules  # database security rules
```
