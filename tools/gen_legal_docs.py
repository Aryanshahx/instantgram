#!/usr/bin/env python3
"""Writes docs/privacy.html, docs/terms.html and the .md sources from the text below.

Run:   python3 tools/gen_legal_docs.py
Push, and GitHub Pages (Settings > Pages > main / docs) shows the same pages the app opens.
"""
import os

UPDATED = "7 October 2026"
APP = "InstantGram"
MAIL = "techlabs.hyper@gmail.com"
BASE = "https://aryanshahx.github.io/instantgram"

PRIVACY = [
    (
        "The short version",
        "We keep what the app needs to work: your account, what you post, and who you talk "
        "to. We do not sell your personal data. You can delete your account in the app at "
        "any time, and that erases your content, your messages and your details.",
    ),
    (
        "What we keep",
        "Your account details (name, username, email, date of birth, country, language), "
        "the photos, clips, moments, comments and messages you send, the people you follow "
        "and who follows you, what you like, save and repost, and simple counts such as "
        "views, reach and watch time.",
    ),
    (
        "Why we keep it",
        "To run the app: to show your content to the audience you choose, to let people find "
        "and message you, to show you analytics about your own posts, and to keep the service "
        "safe. We do not sell your personal data and we do not share it with advertisers.",
    ),
    (
        "Who can see it",
        "Posts are visible to everyone unless you pick Followers only or Only me, or switch "
        "on a private account. Messages are visible to the people in the chat. Analytics are "
        "only ever shown to you, and they are totals, never a list of who watched. You can "
        "block anyone in Settings.",
    ),
    (
        "Where it is stored",
        "Your account and your messages live in Google Firebase (Firebase Authentication and "
        "Cloud Firestore). Photos, clips, voice files and sounds you add from your phone live "
        "in our own media storage. Songs in Hit songs are 30 second previews from Apple "
        "(iTunes). Free music comes from the Jamendo catalogue, found through Openverse.",
    ),
    (
        "On your phone",
        "The app saves your language, accessibility choices, watch history and screen time on "
        "your phone only. It asks your permission before it uses the camera, the microphone, "
        "your photos or your location, and you can take it back in Android settings.",
    ),
    (
        "Deleting your account",
        "Settings > Account > Delete account. We send a 6 digit code to the email address of "
        "the account and ask for your password; enter both and the account is deleted. That "
        "erases your profile and details, your posts, clips, moments and stories, your "
        "comments and replies, your likes, saves and reposts, your chats and messages, your "
        "followers and following lists, your blocks and your notifications. The photos, "
        "clips and sound files you uploaded are removed from storage, and the sign-in itself "
        "is removed from Firebase Authentication. It cannot be undone. A short record of "
        "reports and blocks may be kept for up to 30 days to keep the service safe, and "
        "nothing else is kept. You can also write to "
        + MAIL
        + " and we will delete it for you.",
    ),
    (
        "Children",
        "You must be at least 13 years old to make an account. That is why we ask for your "
        "date of birth. If a child's account is reported to us, we remove it and its content.",
    ),
    (
        "Your choices",
        "You can edit or delete any post at any time, clear your watch history and screen "
        "time, make your account private, block people, and ask for a copy of what we hold by "
        "writing to " + MAIL + ".",
    ),
    (
        "Changes",
        "If this policy changes, the new version is published on this page with a new date. "
        "Keeping the app installed means you accept it.",
    ),
    ("Contact", "Questions, or anything about your data: " + MAIL + "."),
]

TERMS = [
    (
        "Using the app",
        "You must be at least 13 years old. You are responsible for your account and for what "
        "you post. Keep your password to yourself and do not let anyone else use your account.",
    ),
    (
        "Your content",
        "You keep the rights to what you post. By posting you allow "
        + APP
        + " to store it and show it to the audience you choose, and to remove it when it "
        "breaks these terms. Only post what you have the right to share.",
    ),
    (
        "Not allowed",
        "Hate, harassment, threats, nudity or sexual content involving minors, scams, spam, "
        "violence, and anything that breaks the law or other people's rights. Impersonating "
        "someone, and automated posting, are not allowed either.",
    ),
    (
        "Audio",
        "You can import your own audio from your phone: add only audio you have the right to "
        "use, and it is uploaded with your post and removed with it. Hit songs are 30 second "
        "previews that Apple offers to promote its music; they belong to their owners, are "
        "used only inside the app, and the artist's name is always shown. Free music is "
        "shared by its artists under Creative Commons licences (the Jamendo catalogue, found "
        "through Openverse) and is credited in the app. Do not copy, download or resell any "
        "of it outside " + APP + ".",
    ),
    (
        "Deleting your account",
        "You can delete your account in the app: Settings > Account > Delete account. It is "
        "confirmed with a code sent to your email and your password. Everything that goes "
        "with the account (content, messages and details) is erased, and it cannot be undone. "
        "The details are in the Privacy Policy.",
    ),
    (
        "Reports and removal",
        "People can report clips, posts and comments. We may remove content or accounts that "
        "break these terms, usually after a look at the report. Repeated or serious cases are "
        "removed without warning.",
    ),
    (
        "The app is provided as is",
        APP
        + " is free and provided as is. We do our best to keep it running, but we are not "
        "liable for lost content, lost reach or anything else that comes with using a free "
        "service. Keep your own copies of anything precious to you.",
    ),
    (
        "Changes",
        "We may update these terms. Using the app after a change means you accept it.",
    ),
    ("Contact", "Questions or reports: " + MAIL + "."),
]


def page(title: str, lead: str, sections) -> str:
    nav = (
        '<nav><a href="index.html">Home</a>'
        '<a href="privacy.html">Privacy Policy</a>'
        '<a href="terms.html">Terms of Use</a></nav>'
    )
    body = "".join(
        "<h2>%s</h2><p>%s</p>" % (h, p.replace("&", "&amp;").replace("<", "&lt;"))
        for h, p in sections
    )
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{title} - {APP}</title><style>
:root{{color-scheme:light dark;--bg:#fff;--fg:#14161a;--mut:#5d6470;--acc:#7a9a00;--line:#e4e7ec}}
@media(prefers-color-scheme:dark){{:root{{--bg:#0e0f12;--fg:#f2f3f5;--mut:#a0a6b0;--acc:#c6f432;--line:#25282e}}}}
body{{margin:0;background:var(--bg);color:var(--fg);font:16px/1.65 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}}
main{{max-width:720px;margin:0 auto;padding:40px 22px 80px}}
h1{{font-size:32px;letter-spacing:-1px;margin:0 0 4px}}
h2{{font-size:19px;margin:32px 0 6px}}
p,li{{color:var(--fg)}}
.mut{{color:var(--mut);font-size:14px}}
a{{color:var(--acc);font-weight:600}}
nav{{margin-bottom:28px;font-size:14px}}nav a{{margin-right:16px}}
hr{{border:0;border-top:1px solid var(--line);margin:36px 0}}
</style></head><body><main>
{nav}
<h1>{title}</h1>
<p class="mut">{APP} &middot; Last updated {UPDATED}</p>
<p>{lead}</p>
{body}
<hr><p class="mut">This page is part of the {APP} app. The app opens it from Settings &gt; About,
and from the sign-up screen. In-app address: {BASE}/{'privacy' if 'Privacy' in title else 'terms'}.html</p>
</main></body></html>
"""


def markdown(title: str, lead: str, sections) -> str:
    out = [f"# {title}", "", f"*{APP} - last updated {UPDATED}*", "", lead, ""]
    for h, p in sections:
        out += [f"## {h}", "", p, ""]
    return "\n".join(out)


def dart_file() -> str:
    """The same text as Dart constants, so the app and the web page can never differ."""

    def q(s: str) -> str:
        s = s.replace("\\", "\\\\").replace("$", "\\$").replace("'", "\\'")
        return "        '" + s + "'"

    def block(name: str, secs) -> str:
        rows = ",\n".join(
            "      (\n%s,\n%s,\n      )" % (q(h), q(p)) for h, p in secs
        )
        return "const List<(String, String)> %s = [\n%s,\n];\n" % (name, rows)

    return (
        "// Generated by tools/gen_legal_docs.py - do not edit by hand.\n"
        "// Edit the text in that script and run it again: the app and the pages on\n"
        "// GitHub Pages then always show the same words.\n\n"
        "/// The date both pages were last changed.\n"
        "const String kLegalUpdated = '%s';\n\n%s\n%s"
        % (UPDATED, block("kPrivacySections", PRIVACY), block("kTermsSections", TERMS))
    )


def main() -> None:
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    docs = os.path.join(root, "docs")
    os.makedirs(docs, exist_ok=True)

    jobs = [
        (
            "privacy",
            "Privacy Policy",
            "How " + APP + " handles your account, your content and your messages.",
            PRIVACY,
        ),
        (
            "terms",
            "Terms of Use",
            "The rules for using " + APP + " and for what you post on it.",
            TERMS,
        ),
    ]
    for slug, title, lead, sections in jobs:
        with open(os.path.join(docs, slug + ".html"), "w") as f:
            f.write(page(title, lead, sections))
        with open(os.path.join(docs, slug + ".md"), "w") as f:
            f.write(markdown(title, lead, sections))
        print("wrote docs/%s.html and docs/%s.md" % (slug, slug))

    # Pages then serves the files as they are, with no Jekyll build
    with open(os.path.join(docs, ".nojekyll"), "w"):
        pass
    print("wrote docs/.nojekyll")

    # The app shows the same words when there is no internet
    path = os.path.join(root, "lib", "core", "legal_text.dart")
    with open(path, "w") as f:
        f.write(dart_file())
    print("wrote lib/core/legal_text.dart")


if __name__ == "__main__":
    main()
