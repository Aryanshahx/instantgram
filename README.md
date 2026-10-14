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
1. Tap Share: the post goes into an **upload queue** and you can keep using the app
   (a "Sharing… %" bar in Discover + an Android notification).
2. Videos are made HD on the phone (1080p, max 30 fps, fast start) + a small copy for slow networks.
3. The app asks the Vercel API for signed Tigris links (with the Firebase login token).
   Big files go in 5 MB parts, 6 at the same time; if the network breaks, it goes on
   from the last finished part (also after closing the app).
4. When all files are up, the post is saved in Firestore.

## How videos load
- Videos play through a small cache on the phone: watching again (clips, moments,
  Discover) does not download again. The next 3 videos are partly downloaded before you get there.

## New in v0.9
- Chats: photos, GIFs, voice messages, location (opens Google Maps), reactions,
  reply (long-press or swipe right), forward, pin, delete for everyone / for you
- Voice + video calls (own WebRTC, rings when the app is closed), message ticks ✓ ✓✓, "Active now"
- Clips: comments open as a panel, the clip plays small on top; drag the panel to
  full screen and the clip pauses. Paused clips stay paused (music too)
- Reply to a comment with one of your clips / posts, or make a new one
  (it gets a "Reply to @name's comment" sticker)
- Comments: no divider lines; GIF picker is GIPHY only

## New in v0.8
- Background uploads with progress bar + notification, resume after a break
- Faster videos: phone cache, preloading, fast start, HD 1080p / 30 fps uploads
- Comments: photos, GIFs (GIPHY search + gallery), likes, replies, emoji row
- Clips: time bubble on the progress bar, springy buttons, pause stays paused
- Discover videos pause while moments are open

## Features (v0.6)
- Sign up: choose language first, then name, date of birth and country
- Log in with email or username
- Discover: posts and moments from you, people you follow and famous accounts
  (10,000+ followers)
- Posts and Clips (any mix of photos and videos, no limit) stay forever;
  Moments disappear after 24h
- Likes (double-tap too), comments, reposts, saves
- Share: send to people you follow or chat with, copy link, other apps
- Hold your own post / clip: Analytics (overview, engagement, audience) and Pin
- Views count once per account (not your own); Dashboard with overview,
  engagement and audience for your whole account
- Explore: clips only, they play muted when visible, with view counts
- Instant loading: next clips / moments / photos are prepared before you get there,
  media is cached on the phone and on the Tigris CDN
- Follow / unfollow, followers & following lists
- Search: people, clips and #hashtags
- Direct messages
- Notifications (likes, comments, follows, reposts)
- Edit profile, profile photo and cover
- Create: posts and clips with many photos and videos, moments (photo or video)
- Editor: filters, adjust, crop, text, video trim, mute, cover from video or gallery,
  music from your phone (mp3 / m4a)
- Discover: media at its real shape (no crop), videos and music play when in view,
  pull to refresh (also on your profile)
- Post options: audience (Everyone / Followers / Only me), hide like/comment/repost/share counts
- Private accounts with follow requests, block, remove followers
- Moments ring on avatars everywhere (tap to watch)
- Settings: account, history, manage time, privacy, blocked, accessibility (text size,
  reduce motion), 40 languages, country, about + error log, privacy policy and terms
  (privacypolicy.md / termsofuse.md), app update, log out,
  delete account request by email
- Reports go by email to techlabs.hyper@gmail.com

## Download the APK
- **Every push to `main`** → Actions tab → latest run → *Artifacts* → `InstantGram-apk-N`
- **Releases** → push a tag like `v0.6.0` → APK appears under *Releases*

## Setup
### Firebase
- `lib/firebase_options.dart` and `android/app/google-services.json` come from `flutterfire configure`
  (safe to commit — they are app identifiers, not secrets).
- Database rules + indexes: `firebase deploy --only firestore --project YOUR_PROJECT_ID`

### Tigris + Vercel
See [`backend/README.md`](backend/README.md).
Then set the GitHub repo variable **`API_BASE_URL`** = your Vercel URL
(Settings → Secrets and variables → Actions → Variables), or put it in `lib/core/config/api_url.dart`.

### Calls
Own WebRTC calls (v0.10): Firestore carries the call setup, a free TURN server
(ExpressTURN, Metered Open Relay or Cloudflare) relays when needed, FCM makes the
phone ring when the app is closed.
Vercel settings: `TURN_SERVER`, `TURN_USERNAME`, `TURN_PASSWORD` (ExpressTURN),
`FIREBASE_SERVICE_ACCOUNT` (see [`backend/README.md`](backend/README.md)).

## Project structure
```
lib/
├── core/        # config, services (API, uploads), theme, utils
├── features/    # auth, feed, post, stories, reels, search, chats, notifications, profile, dashboard
└── shared/      # models, widgets, navigation
backend/         # Vercel API (signed Tigris uploads)
firestore.rules  # database security rules
```
