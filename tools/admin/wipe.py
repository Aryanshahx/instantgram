"""Removes everything one InstantGram account stored in Firestore.

Used by tools/delete_user.sh (see delete_user.py). Written against a small part of the
Firestore Admin API so it can be tested with a fake database (tools/admin/test_wipe.py):

    db.collection(name) -> col; col.document(id) -> ref; col.where(field, op, value) -> query
    col.stream() / query.stream() -> docs (doc.id, doc.exists, doc.to_dict(), doc.reference)
    ref.get() -> doc; ref.collection(name) -> col; ref.delete(); ref.update(dict)
    increment(n) -> a value that adds n to a number field

What is removed for the account (uid):
  * their posts and clips, with the likes, views and comments on them;
  * their likes, views and comments on other people's posts (and the counters go down);
  * their moments, their notifications, their calls;
  * their messages in every chat; a chat left without messages is removed, otherwise the
    other person keeps it and sees "User not available";
  * their followers / following lists on both sides (the counters go down), follow requests;
  * their saved posts, reposts, blocks, the username, and the profile itself.
Files (photos, clips, sounds) are removed by the media signer; the sign-in by Firebase Auth.
"""

from __future__ import annotations

from dataclasses import dataclass, field

USER_SUBCOLLECTIONS = [
    "followers", "following", "saved", "reposts", "blocked",
    "requests", "approved", "sent_requests", "audiences", "highlights",
]


@dataclass
class Report:
    """What was (or, in a dry run, would be) removed."""
    posts: int = 0
    comments: int = 0
    likes: int = 0
    views: int = 0
    stories: int = 0
    messages: int = 0
    chats_removed: int = 0
    chats_kept: int = 0
    calls: int = 0
    notifications: int = 0
    follow_links: int = 0
    other: int = 0
    notes: list = field(default_factory=list)

    def lines(self):
        return [
            f"posts and clips      {self.posts}",
            f"comments             {self.comments}",
            f"likes                {self.likes}",
            f"views                {self.views}",
            f"moments              {self.stories}",
            f"messages             {self.messages}",
            f"chats removed        {self.chats_removed}",
            f"chats kept (other person sees 'User not available')  {self.chats_kept}",
            f"calls                {self.calls}",
            f"notifications        {self.notifications}",
            f"follow links         {self.follow_links}",
            f"other records        {self.other}",
        ]


class Wiper:
    def __init__(self, db, increment, dry_run=False, log=print):
        self.db = db
        self.inc = increment
        self.dry = dry_run
        self.log = log

    # ------------------------------------------------------------- helpers
    def _delete(self, ref):
        if not self.dry:
            ref.delete()

    def _update(self, ref, data):
        if not self.dry:
            try:
                ref.update(data)
            except Exception as e:  # the other document may be gone already
                self.log(f"   (skipped an update: {e})")

    def _delete_all(self, col):
        n = 0
        for d in col.stream():
            self._delete(d.reference)
            n += 1
        return n

    # ----------------------------------------------------------------- run
    def wipe(self, uid: str) -> Report:
        r = Report()
        self._own_posts(uid, r)
        self._activity_on_other_posts(uid, r)
        self._stories(uid, r)
        self._chats(uid, r)
        self._calls(uid, r)
        self._notifications(uid, r)
        self._push_and_story_views(uid, r)
        self._follow_links(uid, r)
        self._profile(uid, r)
        return r

    def _own_posts(self, uid, r):
        for p in self.db.collection("posts").where("authorId", "==", uid).stream():
            ref = p.reference
            r.likes += self._delete_all(ref.collection("likes"))
            r.views += self._delete_all(ref.collection("views"))
            for c in ref.collection("comments").stream():
                self._delete_all(c.reference.collection("likes"))
                self._delete(c.reference)
                r.comments += 1
            self._delete(ref)
            r.posts += 1

    def _activity_on_other_posts(self, uid, r):
        for p in self.db.collection("posts").stream():
            data = p.to_dict() or {}
            if data.get("authorId") == uid:
                continue  # already gone with their own posts
            ref = p.reference
            like = ref.collection("likes").document(uid)
            if like.get().exists:
                self._delete(like)
                self._update(ref, {"likeCount": self.inc(-1)})
                r.likes += 1
            view = ref.collection("views").document(uid)
            if view.get().exists:
                self._delete(view)
                self._update(ref, {"viewCount": self.inc(-1)})
                r.views += 1
            removed = 0
            for c in ref.collection("comments").stream():
                cref = c.reference
                if (c.to_dict() or {}).get("authorId") == uid:
                    self._delete_all(cref.collection("likes"))
                    self._delete(cref)
                    removed += 1
                else:
                    cl = cref.collection("likes").document(uid)
                    if cl.get().exists:
                        self._delete(cl)
                        r.other += 1
            if removed:
                self._update(ref, {"commentCount": self.inc(-removed)})
                r.comments += removed

    def _stories(self, uid, r):
        for s in self._all_stories(uid):
            for sub in ("views", "likes", "replies"):
                self._delete_all(s.reference.collection(sub))
            self._delete(s.reference)
            r.stories += 1

    def _all_stories(self, uid):
        for col in ("stories", "privateStories"):
            yield from self.db.collection(col).where("authorId", "==", uid).stream()

    def _chats(self, uid, r):
        for c in self.db.collection("chats").where("members", "array_contains", uid).stream():
            ref = c.reference
            left = []
            for m in ref.collection("messages").stream():
                if (m.to_dict() or {}).get("senderId") == uid:
                    self._delete(m.reference)
                    r.messages += 1
                else:
                    left.append(m)
            if not left:
                self._delete(ref)
                r.chats_removed += 1
                continue
            r.chats_kept += 1
            data = c.to_dict() or {}
            if data.get("lastSender") == uid:
                newest = max(left, key=lambda m: _when((m.to_dict() or {}).get("createdAt")))
                md = newest.to_dict() or {}
                self._update(ref, {
                    "lastText": md.get("text", "") or "",
                    "lastSender": md.get("senderId", "") or "",
                })

    def _calls(self, uid, r):
        seen = set()
        for f in ("callerId", "calleeId"):
            for c in self.db.collection("calls").where(f, "==", uid).stream():
                if c.id in seen:
                    continue
                seen.add(c.id)
                self._delete(c.reference)
                r.calls += 1

    def _notifications(self, uid, r):
        r.notifications += self._delete_all(
            self.db.collection("notifications").document(uid).collection("items"))
        self._delete(self.db.collection("notifications").document(uid))

    def _push_and_story_views(self, uid, r):
        # their phones' push addresses, their story-view alert list
        for col in ("pushTokens", "storyAlerts"):
            ref = self.db.collection(col).document(uid)
            if ref.get().exists:
                self._delete(ref)
                r.other += 1
        # their "viewed" line on other people's moments
        for col in ("stories", "privateStories"):
            for s in self.db.collection(col).stream():
                v = s.reference.collection("views").document(uid)
                if v.get().exists:
                    self._delete(v)
                    r.other += 1

    def _follow_links(self, uid, r):
        users = self.db.collection("users")
        me = users.document(uid)
        # people they follow: drop them from those people's followers
        for f in me.collection("following").stream():
            other = users.document(f.id)
            back = other.collection("followers").document(uid)
            if back.get().exists:
                self._delete(back)
                self._update(other, {"followersCount": self.inc(-1)})
                r.follow_links += 1
        # their followers: drop them from those people's following
        for f in me.collection("followers").stream():
            other = users.document(f.id)
            back = other.collection("following").document(uid)
            if back.get().exists:
                self._delete(back)
                self._update(other, {"followingCount": self.inc(-1)})
                r.follow_links += 1
        # follow requests both ways
        for q in me.collection("sent_requests").stream():
            ref = users.document(q.id).collection("requests").document(uid)
            if ref.get().exists:
                self._delete(ref)
                r.other += 1
        for q in me.collection("requests").stream():
            ref = users.document(q.id).collection("sent_requests").document(uid)
            if ref.get().exists:
                self._delete(ref)
                r.other += 1

    def _profile(self, uid, r):
        users = self.db.collection("users")
        me = users.document(uid)
        for sub in USER_SUBCOLLECTIONS:
            r.other += self._delete_all(me.collection(sub))
        for u in self.db.collection("usernames").where("uid", "==", uid).stream():
            self._delete(u.reference)
            r.other += 1
        if me.get().exists:
            self._delete(me)
            r.other += 1


def _when(v):
    """Sort key for a Firestore time (datetime, or missing)."""
    try:
        return v.timestamp()
    except Exception:
        return 0.0


def find_orphans(db, auth_uids: set) -> dict:
    """uid -> a short description, for everybody who left data but has no sign-in any more."""
    seen: dict = {}

    def note(uid, what):
        if uid and uid not in auth_uids:
            seen.setdefault(uid, set()).add(what)

    for u in db.collection("users").stream():
        note(u.id, "profile")
    for p in db.collection("posts").stream():
        note((p.to_dict() or {}).get("authorId", ""), "posts")
    for col in ("stories", "privateStories"):
        for s in db.collection(col).stream():
            note((s.to_dict() or {}).get("authorId", ""), "moments")
    for c in db.collection("chats").stream():
        for m in (c.to_dict() or {}).get("members", []) or []:
            note(m, "chats")
    for n in db.collection("usernames").stream():
        note((n.to_dict() or {}).get("uid", ""), "username")
    return {k: ", ".join(sorted(v)) for k, v in seen.items()}
