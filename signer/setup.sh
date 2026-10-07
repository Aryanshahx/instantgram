#!/usr/bin/env bash
# =============================================================================
# One-time setup of the media storage (Tigris bucket + Vercel signer).
#   cd ~/IdeaProjects/instantgram && bash signer/setup.sh
# Safe to run again. You do the clicking in two websites; this script checks every step
# and writes the final addresses into lib/core/config.dart.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"

die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
ask() { local a=""; read -r -p "$1" a || a=""; printf '%s' "$a"; }
hr()  { printf '\n%s\n' "-----------------------------------------------------------------------------"; }

command -v node >/dev/null || die "Node.js is missing. Install it:  sudo apt install -y nodejs"
[ "$(node -p 'process.versions.node.split(".")[0]')" -ge 18 ] || die "Node.js 18 or newer is needed (you have $(node -v))."
command -v curl >/dev/null || die "curl is missing:  sudo apt install -y curl"
GS="$ROOT/android/app/google-services.json"
[ -f "$GS" ] || die "android/app/google-services.json not found. Run this from your project."
FIREBASE_PROJECT_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["project_info"]["project_id"])' "$GS")"

# ------------------------------------------------------------------ A. Tigris
hr
cat <<TXT
 STEP A - the storage (Tigris)

   1. Open  https://console.storage.dev  and sign in (GitHub or Google works).
   2. Buckets -> Create bucket
        name   : something unique, lower case, letters / numbers / dashes only
                 (example: instantgram-aryan-media)
        access : PUBLIC   (so the app can show photos and videos)
      Tigris asks for a payment method before it allows public buckets. It is only
      verification: the free tier is 5 GB of storage and nothing is charged inside it.
   3. Access Keys -> Create access key (any name).
      Give it the role  Editor  on your new bucket.
   4. Copy the Access Key ID (starts with tid_) and the Secret (starts with tsec_).
      The secret is shown only once.
TXT
hr
BUCKET="$(ask 'Bucket name: ')"
BUCKET="${BUCKET//[[:space:]]/}"
AK="$(ask 'Access Key ID (tid_...): ')"
printf 'Secret Access Key (tsec_..., typing is hidden): '
read -r -s SK || SK=""
echo
AK="${AK//[[:space:]]/}"; SK="${SK//[[:space:]]/}"
[ -n "$BUCKET" ] && [ -n "$AK" ] && [ -n "$SK" ] || die "The bucket name and both keys are needed."

echo
echo "Testing the bucket (uploads a tiny file, reads it back publicly, deletes it)..."
RESULT="$(TIGRIS_BUCKET="$BUCKET" TIGRIS_ACCESS_KEY_ID="$AK" TIGRIS_SECRET_ACCESS_KEY="$SK" node check-tigris.mjs)"
case "$RESULT" in
  OK\ *) echo "  $RESULT" ;;
  *)     echo "  $RESULT"; die "Fix that and run the script again." ;;
esac
PUBLIC_URL="$(printf '%s' "$RESULT" | awk '{print $2}')"

# ------------------------------------------------------------------ B. Vercel
hr
cat <<TXT
 STEP B - the small signer service (Vercel, free, no card)

 Before you start, the folder "signer" must be on GitHub:
     git add -A && git commit -m "signer" && git push

   1. Open  https://vercel.com/signup  and continue with GitHub.
   2. Add New... -> Project -> import  instantgram  (allow Vercel to see the repo if asked).
   3. Configure Project:
        Root Directory    : press Edit and choose  signer
        Framework Preset  : Other
        Environment Variables: click the first "Key" box and PASTE these four lines at once
          (Vercel splits them into four variables):

TXT
printf '        FIREBASE_PROJECT_ID=%s\n        TIGRIS_BUCKET=%s\n        TIGRIS_ACCESS_KEY_ID=%s\n        TIGRIS_SECRET_ACCESS_KEY=%s\n' \
  "$FIREBASE_PROJECT_ID" "$BUCKET" "$AK" "$SK"
cat <<TXT

   4. Press Deploy and wait for "Congratulations".
   5. Open the project -> Settings -> Domains and copy the address ending in .vercel.app
      (example: instantgram-abc12.vercel.app).
TXT
hr
API_HOST="$(ask 'Paste the Vercel address here: ')"
unset AK SK
API_HOST="${API_HOST//[[:space:]]/}"
API_HOST="${API_HOST#https://}"; API_HOST="${API_HOST#http://}"
API_HOST="${API_HOST%%/*}"
[ -n "$API_HOST" ] || die "No address given."
API_URL="https://$API_HOST/api"

echo
echo "Testing the signer at $API_URL ..."
CODE=""; BODY=""
for _ in 1 2 3 4 5 6; do
  BODY="$(curl -sS --max-time 15 -w '\n%{http_code}' "$API_URL/health" 2>/dev/null || true)"
  CODE="$(printf '%s' "$BODY" | tail -1)"; BODY="$(printf '%s' "$BODY" | sed '$d')"
  [ "$CODE" = "200" ] && break
  sleep 5
done
case "$CODE" in
  200)
    echo "  answered: $BODY"
    if ! printf '%s' "$BODY" | grep -q '"ready":true'; then
      die "The signer runs but is missing settings. In Vercel: Settings -> Environment Variables must list the four values above. Add what is missing, then Deployments -> Redeploy, and run this script again."
    fi ;;
  401|403) die "Vercel is asking for a login (Deployment Protection). In Vercel: Settings -> Deployment Protection -> turn off 'Vercel Authentication', then run this script again." ;;
  404)     die "The signer was not found. In Vercel: Settings -> General -> Root Directory must be 'signer'. Fix it, Redeploy, run this script again." ;;
  *)       die "The signer did not answer (code '${CODE:-none}'). Check the deployment in Vercel and run this script again." ;;
esac

hr
bash "$ROOT/tools/set_media_url.sh" "$API_URL" "$PUBLIC_URL"
cat <<TXT

 -----------------------------------------------------------------------------
 Media storage is ready.
   uploads : $API_URL
   files   : $PUBLIC_URL

 Next, from the project folder:
   flutter pub get && dart analyze && flutter test
   git add -A && git commit -m "Tigris media addresses" && git push
 Then install the new APK from GitHub Actions.
 -----------------------------------------------------------------------------
TXT
