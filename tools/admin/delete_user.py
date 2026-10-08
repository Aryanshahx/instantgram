"""InstantGram account deletion (developer tool).  Start it with tools/delete_user.sh.

  setup                     one time: service-account key + admin key for the media signer
  <username|email|uid>      delete that account: posts, clips, chats, files, sign-in
  --leftovers               clean up accounts deleted earlier (e.g. in the Firebase console)
  --dry-run                 (with either) only show what would be removed
"""

import glob
import json
import os
import re
import secrets
import shutil
import sys
import time
import urllib.error
import urllib.request
import warnings

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wipe import Wiper, find_orphans  # noqa: E402

warnings.filterwarnings("ignore")  # positional where() is fine for us

HOME = os.path.expanduser("~/.instantgram-admin")
KEY_FILE = os.path.join(HOME, "service-account.json")
ADMIN_FILE = os.path.join(HOME, "admin_key")
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def die(msg):
    print("\n✗ " + msg)
    sys.exit(1)


def again(job, what="Talking to Firebase"):
    """Runs job(); a network blip (Wi-Fi drop, timeout) is retried instead of crashing.
    Safe: checking changes nothing, and deleting twice is harmless."""
    tries = 6
    for n in range(1, tries + 1):
        try:
            return job()
        except (KeyboardInterrupt, SystemExit):
            raise
        except Exception as e:
            msg = (str(e).splitlines() or [type(e).__name__])[0][:120]
            if n == tries:
                die(f"{what} failed {tries} times ({msg}).\n  Check the internet and run the same command again - it carries on where it stopped.")
            wait = 5 * n
            print(f"   network problem ({msg}) - trying again in {wait}s…")
            time.sleep(wait)


def api_url():
    try:
        src = open(os.path.join(REPO, "lib", "core", "config.dart")).read()
    except OSError:
        die("lib/core/config.dart not found — run this from the project folder.")
    m = re.search(r"kMediaApiUrl\s*=\s*'([^']+)'", src)
    if not m or "CHANGE-ME" in m.group(1):
        die("kMediaApiUrl is not set in lib/core/config.dart.")
    return m.group(1).rstrip("/")


def admin_key():
    try:
        return open(ADMIN_FILE).read().strip()
    except OSError:
        die("Not set up yet. Run:  bash tools/delete_user.sh setup")


def signer(body):
    req = urllib.request.Request(
        api_url() + "/admin", data=json.dumps(body).encode(), method="POST",
        headers={"content-type": "application/json", "x-admin-key": admin_key(),
                 "user-agent": "instantgram-admin"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            die("The media signer has no ADMIN_KEY yet (or not redeployed). See: bash tools/delete_user.sh setup")
        if e.code == 403:
            die("The media signer refused the admin key. ADMIN_KEY in Vercel must equal ~/.instantgram-admin/admin_key")
        die(f"Media signer error {e.code}: {e.read()[:200]!r}")
    except urllib.error.URLError as e:
        die(f"Cannot reach the media signer: {e.reason}")


def firebase():
    if not os.path.exists(KEY_FILE):
        die("Not set up yet. Run:  bash tools/delete_user.sh setup")
    import firebase_admin
    from firebase_admin import auth, credentials, firestore
    if not firebase_admin._apps:
        firebase_admin.initialize_app(credentials.Certificate(KEY_FILE))
    return firestore.client(), auth, firestore.Increment


# ------------------------------------------------------------------ setup
def setup():
    os.makedirs(HOME, exist_ok=True)
    os.chmod(HOME, 0o700)
    if os.path.exists(KEY_FILE):
        print("✓ Service-account key already saved.")
    else:
        found = sorted(glob.glob(os.path.expanduser("~/Downloads/*firebase-adminsdk*.json")),
                       key=os.path.getmtime)
        if not found:
            print("""
1) Firebase console → ⚙ Project settings → Service accounts
   → "Generate new private key" → Generate key   (it goes to ~/Downloads)
2) Run this again:  bash tools/delete_user.sh setup""")
            sys.exit(1)
        shutil.move(found[-1], KEY_FILE)
        os.chmod(KEY_FILE, 0o600)
        print(f"✓ Service-account key moved to {KEY_FILE} (not in the project, never committed).")
    try:
        db, _, _ = firebase()
        list(db.collection("usernames").limit(1).stream())
        print("✓ Firestore works with it.")
    except Exception as e:
        die(f"Firestore did not accept the key: {e}")

    if not os.path.exists(ADMIN_FILE):
        with open(ADMIN_FILE, "w") as f:
            f.write(secrets.token_hex(32))
        os.chmod(ADMIN_FILE, 0o600)
    key = open(ADMIN_FILE).read().strip()
    req = urllib.request.Request(api_url() + "/admin", data=b'{"op":"check"}', method="POST",
                                 headers={"content-type": "application/json", "x-admin-key": key,
                                          "user-agent": "instantgram-admin"})
    try:
        urllib.request.urlopen(req, timeout=30)
        print("✓ The media signer accepts the admin key.\n\nAll set.")
        return
    except urllib.error.HTTPError as e:
        code = e.code
    except urllib.error.URLError as e:
        die(f"Cannot reach the media signer: {e.reason}")
    print(f"""
The media signer does not know the admin key yet ({'not set' if code == 404 else 'different key'}).
In Vercel → your signer project → Settings → Environment Variables:
   Name:  ADMIN_KEY
   Value: {key}
Save → Deployments → ⋯ on the newest → Redeploy.  Then run setup again.""")
    sys.exit(1)


# ----------------------------------------------------------------- delete
def resolve(db, auth, who):
    who = who.strip().lstrip("@")
    if "@" in who:
        for u in db.collection("users").where("email", "==", who.lower()).stream():
            return u.id
        for u in db.collection("users").where("email", "==", who).stream():
            return u.id
        try:
            return auth.get_user_by_email(who).uid
        except Exception:
            return None
    n = db.collection("usernames").document(who.lower()).get()
    if n.exists and (n.to_dict() or {}).get("uid"):
        return n.to_dict()["uid"]
    if db.collection("users").document(who).get().exists:
        return who
    try:
        return auth.get_user(who).uid
    except Exception:
        return None


def wipe_files(uid):
    total = 0
    while True:
        r = signer({"op": "wipe", "uid": uid})
        total += int(r.get("deleted", 0))
        print(f"   files removed: {total}", end="\r")
        if not r.get("more"):
            break
    print(f"   files removed: {total}   ")
    return total


def delete_one(db, auth, inc, uid, label, dry, ask=True):
    print(f"\n── {label}  (uid {uid})")
    report = again(lambda: Wiper(db, inc, dry_run=True, log=print).wipe(uid), "Checking")
    for line in report.lines():
        print("   " + line)
    if dry:
        print("   (dry run — nothing removed)")
        return False
    if ask:
        answer = input("\nType DELETE to remove all of this for good: ").strip()
        if answer != "DELETE":
            print("Cancelled.")
            return False
    signer({"op": "check"})  # stop before touching anything if the signer is not ready
    wipe_files(uid)
    again(lambda: Wiper(db, inc, log=print).wipe(uid), "Deleting")
    try:
        auth.delete_user(uid)
        print("   sign-in removed")
    except Exception:
        print("   sign-in was already gone")
    print("✓ Deleted.")
    return True


def main(argv):
    dry = "--dry-run" in argv
    args = [a for a in argv if a != "--dry-run"]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        return
    if args[0] == "setup":
        setup()
        return
    db, auth, inc = firebase()
    if args[0] == "--leftovers":
        print("Looking for data of accounts that no longer exist…")
        uids = again(lambda: {u.uid for u in auth.list_users().iterate_all()})
        orphans = again(lambda: find_orphans(db, uids))
        if not orphans:
            print("✓ Nothing left over.")
            return
        for uid, what in orphans.items():
            print(f"   {uid}: {what}")
        if not dry and input(f"\nType DELETE to clean up these {len(orphans)} accounts: ").strip() != "DELETE":
            print("Cancelled.")
            return
        for uid, what in orphans.items():
            delete_one(db, auth, inc, uid, f"leftovers ({what})", dry, ask=False)
        return
    uid = again(lambda: resolve(db, auth, args[0]))
    if not uid:
        die(f"No account found for '{args[0]}'.")
    prof = again(lambda: db.collection("users").document(uid).get().to_dict() or {})
    label = f"@{prof.get('username', '?')}  {prof.get('email', '')}".strip()
    delete_one(db, auth, inc, uid, label, dry)


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except KeyboardInterrupt:
        print("\nStopped.")
