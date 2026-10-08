"""Tests for wipe.py with an in-memory stand-in for Firestore.  Run:  python3 tools/admin/test_wipe.py"""

import datetime
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))
from wipe import Wiper, find_orphans  # noqa: E402


class Inc:
    def __init__(self, n):
        self.n = n


class Doc:
    def __init__(self, ref, data):
        self.reference = ref
        self.id = ref.id
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return None if self._data is None else dict(self._data)


class Ref:
    def __init__(self, db, path):
        self.db = db
        self.path = path
        self.id = path[-1]

    def get(self):
        return Doc(self, self.db.docs.get(self.path))

    def collection(self, name):
        return Col(self.db, self.path + (name,))

    def delete(self):
        self.db.docs.pop(self.path, None)

    def update(self, data):
        if self.path not in self.db.docs:
            raise KeyError("no such document")
        d = self.db.docs[self.path]
        for k, v in data.items():
            d[k] = d.get(k, 0) + v.n if isinstance(v, Inc) else v

    def set(self, data):
        self.db.docs[self.path] = dict(data)


class Col:
    def __init__(self, db, path, filters=()):
        self.db = db
        self.path = path
        self.filters = filters

    def document(self, id):
        return Ref(self.db, self.path + (id,))

    def where(self, field, op, value):
        return Col(self.db, self.path, self.filters + ((field, op, value),))

    def stream(self):
        out = []
        for p, d in list(self.db.docs.items()):
            if len(p) != len(self.path) + 1 or p[:-1] != self.path:
                continue
            ok = True
            for f, op, v in self.filters:
                if op == "==" and d.get(f) != v:
                    ok = False
                if op == "array_contains" and v not in (d.get(f) or []):
                    ok = False
            if ok:
                out.append(Doc(Ref(self.db, p), d))
        return out


class DB:
    def __init__(self):
        self.docs = {}

    def collection(self, name):
        return Col(self, (name,))

    def put(self, path, data):
        self.docs[tuple(path.split("/"))] = dict(data)

    def has(self, path):
        return tuple(path.split("/")) in self.docs

    def get(self, path):
        return self.docs[tuple(path.split("/"))]


def world():
    """dead = the deleted account; amy and bob stay."""
    db = DB()
    t = lambda m: datetime.datetime(2026, 10, 1, 12, m)  # noqa: E731
    db.put("users/dead", {"username": "dead", "followersCount": 1, "followingCount": 1})
    db.put("users/amy", {"username": "amy", "followersCount": 1, "followingCount": 1})
    db.put("users/bob", {"username": "bob", "followersCount": 0, "followingCount": 0})
    db.put("usernames/dead", {"uid": "dead"})
    db.put("usernames/amy", {"uid": "amy"})
    # dead follows amy, amy follows dead
    db.put("users/dead/following/amy", {})
    db.put("users/amy/followers/dead", {})
    db.put("users/amy/following/dead", {})
    db.put("users/dead/followers/amy", {})
    db.put("users/dead/saved/p2", {})
    db.put("users/dead/sent_requests/bob", {})
    db.put("users/bob/requests/dead", {})
    # dead's post with someone else's like and comment
    db.put("posts/p1", {"authorId": "dead", "likeCount": 1, "commentCount": 1})
    db.put("posts/p1/likes/amy", {})
    db.put("posts/p1/views/amy", {})
    db.put("posts/p1/comments/c1", {"authorId": "amy"})
    db.put("posts/p1/comments/c1/likes/bob", {})
    # amy's post: dead liked, viewed, commented twice and liked bob's comment
    db.put("posts/p2", {"authorId": "amy", "likeCount": 2, "commentCount": 3, "viewCount": 2})
    db.put("posts/p2/likes/dead", {})
    db.put("posts/p2/likes/bob", {})
    db.put("posts/p2/views/dead", {})
    db.put("posts/p2/views/bob", {})
    db.put("posts/p2/comments/c2", {"authorId": "dead"})
    db.put("posts/p2/comments/c3", {"authorId": "dead"})
    db.put("posts/p2/comments/c4", {"authorId": "bob"})
    db.put("posts/p2/comments/c4/likes/dead", {})
    # moments
    db.put("stories/s1", {"authorId": "dead"})
    db.put("stories/s1/views/amy", {})
    db.put("stories/s2", {"authorId": "amy"})
    db.put("stories/s2/views/dead", {"count": 2})
    db.put("stories/s2/views/bob", {"count": 1})
    db.put("pushTokens/dead", {"tokens": ["t"]})
    db.put("storyAlerts/dead", {"uids": ["amy"]})
    db.put("pushTokens/amy", {"tokens": ["t2"]})
    # chats: with amy (both wrote; dead wrote last), with bob (only dead wrote)
    db.put("chats/amy_dead", {"members": ["amy", "dead"], "lastText": "bye", "lastSender": "dead"})
    db.put("chats/amy_dead/messages/m1", {"senderId": "amy", "text": "hi", "createdAt": t(1)})
    db.put("chats/amy_dead/messages/m2", {"senderId": "dead", "text": "bye", "createdAt": t(2)})
    db.put("chats/bob_dead", {"members": ["bob", "dead"], "lastText": "yo", "lastSender": "dead"})
    db.put("chats/bob_dead/messages/m3", {"senderId": "dead", "text": "yo", "createdAt": t(3)})
    db.put("chats/amy_bob", {"members": ["amy", "bob"]})
    db.put("chats/amy_bob/messages/m4", {"senderId": "amy", "text": "x"})
    # calls and notifications
    db.put("calls/k1", {"callerId": "dead", "calleeId": "amy"})
    db.put("calls/k2", {"callerId": "bob", "calleeId": "dead"})
    db.put("calls/k3", {"callerId": "amy", "calleeId": "bob"})
    db.put("notifications/dead/items/n1", {"actorId": "amy"})
    return db


class WipeTest(unittest.TestCase):
    def test_everything_of_the_account_goes_and_the_rest_stays(self):
        db = world()
        r = Wiper(db, Inc, log=lambda *_: None).wipe("dead")

        # their own post with everything under it
        for p in ["posts/p1", "posts/p1/likes/amy", "posts/p1/views/amy",
                  "posts/p1/comments/c1", "posts/p1/comments/c1/likes/bob"]:
            self.assertFalse(db.has(p), p)
        # their activity on amy's post, counters corrected
        for p in ["posts/p2/likes/dead", "posts/p2/views/dead", "posts/p2/comments/c2",
                  "posts/p2/comments/c3", "posts/p2/comments/c4/likes/dead"]:
            self.assertFalse(db.has(p), p)
        self.assertTrue(db.has("posts/p2/likes/bob"))
        self.assertTrue(db.has("posts/p2/comments/c4"))
        self.assertEqual(db.get("posts/p2")["likeCount"], 1)
        self.assertEqual(db.get("posts/p2")["viewCount"], 1)
        self.assertEqual(db.get("posts/p2")["commentCount"], 1)
        # moments
        self.assertFalse(db.has("stories/s1"))
        self.assertFalse(db.has("stories/s1/views/amy"))
        self.assertTrue(db.has("stories/s2"))
        self.assertFalse(db.has("stories/s2/views/dead"))
        self.assertTrue(db.has("stories/s2/views/bob"))
        self.assertFalse(db.has("pushTokens/dead"))
        self.assertFalse(db.has("storyAlerts/dead"))
        self.assertTrue(db.has("pushTokens/amy"))
        # chats: amy keeps hers (her message stays, preview updated), bob's is gone
        self.assertTrue(db.has("chats/amy_dead"))
        self.assertTrue(db.has("chats/amy_dead/messages/m1"))
        self.assertFalse(db.has("chats/amy_dead/messages/m2"))
        self.assertEqual(db.get("chats/amy_dead")["lastText"], "hi")
        self.assertEqual(db.get("chats/amy_dead")["lastSender"], "amy")
        self.assertFalse(db.has("chats/bob_dead"))
        self.assertFalse(db.has("chats/bob_dead/messages/m3"))
        self.assertTrue(db.has("chats/amy_bob/messages/m4"))
        # calls, notifications
        self.assertFalse(db.has("calls/k1"))
        self.assertFalse(db.has("calls/k2"))
        self.assertTrue(db.has("calls/k3"))
        self.assertFalse(db.has("notifications/dead/items/n1"))
        # follow links on both sides, counters corrected; requests
        self.assertFalse(db.has("users/amy/followers/dead"))
        self.assertFalse(db.has("users/amy/following/dead"))
        self.assertEqual(db.get("users/amy")["followersCount"], 0)
        self.assertEqual(db.get("users/amy")["followingCount"], 0)
        self.assertFalse(db.has("users/bob/requests/dead"))
        # the profile, its lists and the username
        for p in ["users/dead", "users/dead/following/amy", "users/dead/followers/amy",
                  "users/dead/saved/p2", "users/dead/sent_requests/bob", "usernames/dead"]:
            self.assertFalse(db.has(p), p)
        self.assertTrue(db.has("users/amy"))
        self.assertTrue(db.has("usernames/amy"))

        self.assertEqual(r.posts, 1)
        self.assertEqual(r.comments, 1 + 2)
        self.assertEqual(r.stories, 1)
        self.assertEqual(r.messages, 2)
        self.assertEqual(r.chats_removed, 1)
        self.assertEqual(r.chats_kept, 1)
        self.assertEqual(r.calls, 2)
        self.assertEqual(r.notifications, 1)
        self.assertEqual(r.follow_links, 2)

    def test_dry_run_changes_nothing_but_counts_the_same(self):
        db = world()
        before = {k: dict(v) for k, v in db.docs.items()}
        dry = Wiper(db, Inc, dry_run=True, log=lambda *_: None).wipe("dead")
        self.assertEqual(db.docs, before)
        real = Wiper(world(), Inc, log=lambda *_: None).wipe("dead")
        self.assertEqual(dry.lines(), real.lines())

    def test_wiping_twice_is_harmless(self):
        db = world()
        Wiper(db, Inc, log=lambda *_: None).wipe("dead")
        snapshot = {k: dict(v) for k, v in db.docs.items()}
        r = Wiper(db, Inc, log=lambda *_: None).wipe("dead")
        self.assertEqual(db.docs, snapshot)
        self.assertEqual(r.posts + r.messages + r.comments + r.follow_links, 0)

    def test_orphans_are_the_ones_without_a_sign_in(self):
        db = world()
        db.put("posts/p9", {"authorId": "ghost"})
        found = find_orphans(db, auth_uids={"amy", "bob"})
        self.assertEqual(set(found), {"dead", "ghost"})
        self.assertIn("posts", found["ghost"])
        self.assertIn("profile", found["dead"])
        self.assertEqual(find_orphans(db, auth_uids={"amy", "bob", "dead", "ghost"}), {})


if __name__ == "__main__":
    unittest.main(verbosity=2)
