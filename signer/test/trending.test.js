import test from "node:test";
import assert from "node:assert/strict";
import { trendScore, canTrend, rankTrending, trending } from "../lib/trending.js";
import { handle } from "../lib/core.js";

const now = Date.UTC(2026, 9, 10, 12);
const hAgo = (h) => new Date(now - h * 3600_000);

function fakeDb(posts) {
  const docs = new Map();
  return {
    docs,
    reads: 0,
    async get(path) { const d = docs.get(path); return d ? { id: path.split("/").pop(), data: d } : null; },
    async query(col, q) {
      this.reads++;
      const since = q.where[0][2].getTime();
      return posts.filter((p) => p.data.createdAt.getTime() > since);
    },
    async write(ws) { for (const w of ws) docs.set(w.put, w.data); },
  };
}

test("trendScore: newer and busier wins", () => {
  const a = trendScore({ likeCount: 10, createdAt: hAgo(1) }, now);
  const b = trendScore({ likeCount: 10, createdAt: hAgo(20) }, now);
  const c = trendScore({ likeCount: 2, commentCount: 4, createdAt: hAgo(1) }, now);
  assert.ok(a > b);
  assert.ok(c === a);
  assert.equal(trendScore({ createdAt: hAgo(1) }, now), 0);
});

test("canTrend: only public, visible, safe posts", () => {
  assert.equal(canTrend({}), true);
  for (const bad of [{ hidden: true }, { sensitive: true }, { profileOnly: true }, { authorPrivate: true }, { audience: "followers" }, { reportCount: 3 }]) {
    assert.equal(canTrend(bad), false, JSON.stringify(bad));
  }
});

test("rankTrending splits posts and clips, max 3 per author", () => {
  const docs = [];
  for (let i = 0; i < 6; i++) docs.push({ id: `a${i}`, data: { authorId: "a", type: "image", likeCount: 50 - i, createdAt: hAgo(1) } });
  docs.push({ id: "b1", data: { authorId: "b", type: "image", likeCount: 1, createdAt: hAgo(1) } });
  docs.push({ id: "c1", data: { authorId: "c", type: "video", likeCount: 5, createdAt: hAgo(2) } });
  docs.push({ id: "c2", data: { authorId: "c", type: "photoclip", likeCount: 9, createdAt: hAgo(2) } });
  docs.push({ id: "z", data: { authorId: "z", type: "image", likeCount: 0, createdAt: hAgo(1) } });
  const r = rankTrending(docs, now);
  assert.deepEqual(r.posts, ["a0", "a1", "a2", "b1"]);
  assert.deepEqual(r.clips, ["c2", "c1"]);
});

test("trending() works it out at most once an hour", async () => {
  const db = fakeDb([{ id: "p1", data: { authorId: "a", type: "image", likeCount: 3, createdAt: hAgo(3) } }]);
  const r = await trending(db, now);
  assert.equal(r.fresh, true);
  assert.deepEqual(db.docs.get("config/trending").posts, ["p1"]);
  assert.equal((await trending(db, now + 30 * 60_000)).fresh, false);
  assert.equal(db.reads, 1);
  assert.equal((await trending(db, now + 61 * 60_000)).fresh, true);
});

test("the trending route needs a signed-in phone", async () => {
  const res = await handle(new Request("https://x/api/trending", { method: "POST" }), {}, "trending");
  assert.equal(res.status, 401);
  const get = await handle(new Request("https://x/api/trending"), {}, "trending");
  assert.equal(get.status, 404);
});
