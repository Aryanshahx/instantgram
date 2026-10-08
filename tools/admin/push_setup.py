"""Push notification setup (developer only). Uses the service-account key from
`bash tools/delete_user.sh setup` (~/.instantgram-admin/service-account.json).

  rules   publish firebase/firestore.rules to Firestore (no copy-paste in the console)
  key     write the value for the Vercel setting FIREBASE_SERVICE_ACCOUNT into a file
"""
import base64
import json
import os
import sys

HOME = os.path.expanduser("~/.instantgram-admin")
KEY_FILE = os.path.join(HOME, "service-account.json")
OUT_FILE = os.path.join(HOME, "vercel_push_key.txt")


def need_key():
    if not os.path.isfile(KEY_FILE):
        sys.exit("No service-account key yet. Run first:  bash tools/delete_user.sh setup")
    with open(KEY_FILE) as f:
        return json.load(f)


def rules():
    sa = need_key()
    project = sa["project_id"]
    from google.oauth2 import service_account
    from google.auth.transport.requests import AuthorizedSession

    creds = service_account.Credentials.from_service_account_file(
        KEY_FILE, scopes=["https://www.googleapis.com/auth/cloud-platform"])
    s = AuthorizedSession(creds)
    with open("firebase/firestore.rules") as f:
        source = f.read()
    base = f"https://firebaserules.googleapis.com/v1/projects/{project}"
    last = None
    for _ in range(4):  # the Pi's network drops now and then
        try:
            r = s.post(f"{base}/rulesets", json={"source": {"files": [{"name": "firestore.rules", "content": source}]}}, timeout=60)
            if r.status_code != 200:
                sys.exit(f"Firestore did not accept the rules ({r.status_code}):\n{r.text[:800]}")
            ruleset = r.json()["name"]
            name = f"projects/{project}/releases/cloud.firestore"
            r = s.patch(f"{base}/releases/cloud.firestore", json={"release": {"name": name, "rulesetName": ruleset}}, timeout=60)
            if r.status_code != 200:
                sys.exit(f"Could not switch to the new rules ({r.status_code}):\n{r.text[:800]}")
            print("Firestore rules published.")
            return
        except Exception as e:  # network
            last = e
    sys.exit(f"Network problem: {last}. Run the same command again.")


def key():
    need_key()
    with open(KEY_FILE, "rb") as f:
        value = base64.b64encode(f.read()).decode()
    with open(OUT_FILE, "w") as f:
        f.write(value + "\n")
    os.chmod(OUT_FILE, 0o600)
    print(f"Saved the Vercel value to {OUT_FILE}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "rules":
        rules()
    elif cmd == "key":
        key()
    else:
        print(__doc__)
