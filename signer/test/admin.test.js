import test from "node:test";
import assert from "node:assert/strict";
import { runPanelOp, restDb, mediaKeys, STAGES, trustOf, imageFlag } from "../lib/admin.js";
import { handle } from "../lib/core.js";

// ---- Firestore in memory, with the interface of restDb
class FakeDb {
  constructor(docs = {}) { this.docs = new Map(Object.entries(docs)); this.reads = 0; }
  _in(collPath) {
    const depth = collPath.split("/").length + 1;
    return [...this.docs.keys()].filter((p) => p.startsWith(collPath + "/") && p.split("/").length === depth).sort();
  }
  _doc(p) { return { id: p.split("/").pop(), path: p, data: structuredClone(this.docs.get(p)) }; }
  async get(p) { this.reads++; return this.docs.has(p) ? this._doc(p) : null; }
  async query(collection, q = {}, parent = "") {
    let rows = this._in(parent ? `${parent}/${collection}` : collection).map((p) => this._doc(p));
    for (const [f, op, v] of q.where || []) {
      rows = rows.filter((d) => {
        const x = d.data[f];
        const t = (a) => (a instanceof Date ? a.getTime() : a);
        if (op === "==") return t(x) === t(v);
        if (op === ">=") return x != null && t(x) >= t(v);
        if (op === ">") return x != null && t(x) > t(v);
        if (op === "<") return x != null && t(x) < t(v);
        if (op === "in") return v.includes(x);
        if (op === "array-contains") return Array.isArray(x) && x.includes(v);
        throw new Error(op);
      });
    }
    const key = (d, f) => (f === "__name__" ? d.path : d.data[f] instanceof Date ? d.data[f].getTime() : d.data[f]);
    for (const [f, dir] of [...(q.orderBy || [])].reverse()) {
      rows.sort((a, b) => (key(a, f) < key(b, f) ? -1 : key(a, f) > key(b, f) ? 1 : 0) * (dir === "desc" ? -1 : 1));
    }
    if (q.after) {
      const at = rows.findIndex((d) => d.path === q.after[q.after.length - 1]);
      rows = rows.slice(at + 1);
    }
    return rows.slice(0, q.limit || 1000);
  }
  async list(collPath, pageSize = 100, token = "") {
    let paths = this._in(collPath);
    if (token) paths = paths.filter((p) => p > token);
    const page = paths.slice(0, pageSize);
    return { docs: page.map((p) => this._doc(p)), next: paths.length > pageSize ? page[page.length - 1] : "" };
  }
  async count(collection, where = []) { return (await this.query(collection, { where })).length; }
  async write(writes) {
    for (const w of writes) {
      if (w.del) { this.docs.delete(w.del); continue; }
      if (w.create) {
        if (this.docs.has(w.create)) throw new Error("exists " + w.create);
        this.docs.set(w.create, { ...(w.data || {}) });
        continue;
      }
      if (w.put) { this.docs.set(w.put, { ...(this.docs.get(w.put) || {}), ...(w.data || {}) }); continue; }
      if (!this.docs.has(w.set)) continue; // currentDocument.exists
      const d = this.docs.get(w.set);
      Object.assign(d, w.data || {});
      for (const [f, n] of Object.entries(w.add || {})) d[f] = (d[f] || 0) + n;
    }
  }
}

const KEY = (kind, uid, n) => `${kind}/${uid}/${String(n).padStart(32, "a")}.jpg`;
const now = Date.parse("2026-10-09T12:00:00Z");
const ago = (min) => new Date(now - min * 60_000);

function world() {
  return new FakeDb({
    "users/alice1": { username: "alice", email: "a@x.com", createdAt: ago(60), lastActive: ago(1), online: true, postsCount: 2, followersCount: 1, followingCount: 1 },
    "users/bob2": { username: "bob", email: "b@x.com", createdAt: ago(3000), lastActive: ago(600), postsCount: 1, followersCount: 1, followingCount: 1 },
    "usernames/alice": { uid: "alice1" },
    "usernames/bob": { uid: "bob2" },
    "users/alice1/following/bob2": {},
    "users/bob2/followers/alice1": {},
    "users/bob2/following/alice1": {},
    "users/alice1/followers/bob2": {},
    "posts/p1": { authorId: "alice1", authorUsername: "alice", type: "image", createdAt: ago(30), imageUrl: "m:" + KEY("image", "alice1", 1), media: [{ u: "m:" + KEY("image", "alice1", 2), th: "m:" + KEY("thumb", "alice1", 3) }], likeCount: 1, commentCount: 1 },
    "posts/p1/likes/bob2": {},
    "posts/p1/comments/c1": { authorId: "bob2", text: "nice" },
    "posts/p1/comments/c1/likes/alice1": {},
    "posts/p2": { authorId: "alice1", type: "video", createdAt: ago(20), videoUrl: "m:" + KEY("video", "alice1", 4), likeCount: 0, commentCount: 0 },
    "posts/p3": { authorId: "bob2", authorUsername: "bob", type: "image", createdAt: ago(10), imageUrl: "https://elsewhere/x.jpg", likeCount: 1, viewCount: 1, commentCount: 2 },
    "posts/p3/likes/alice1": {},
    "posts/p3/views/alice1": {},
    "posts/p3/comments/c2": { authorId: "alice1", text: "hey" },
    "posts/p3/comments/c3": { authorId: "bob2", text: "yo" },
    "stories/s1": { authorId: "alice1", createdAt: ago(5), expiresAt: new Date(now + 3600_000), imageUrl: "m:" + KEY("image", "alice1", 5) },
    "stories/s2": { authorId: "bob2", createdAt: ago(5), expiresAt: new Date(now + 3600_000) },
    "stories/s2/views/alice1": {},
    "chats/alice1_bob2": { members: ["alice1", "bob2"], lastSender: "alice1", lastText: "bye" },
    "chats/alice1_bob2/messages/m1": { senderId: "bob2", text: "hi", createdAt: ago(9) },
    "chats/alice1_bob2/messages/m2": { senderId: "alice1", text: "bye", createdAt: ago(8) },
    "calls/k1": { callerId: "alice1", calleeId: "bob2" },
    "notifications/alice1": {},
    "notifications/alice1/items/n1": {},
    "pushTokens/alice1": { tokens: ["ta1", "ta-old"] },
    "pushTokens/bob2": { tokens: ["tb1"], off: true },
    "storyAlerts/alice1": { uids: [] },
    "reports/r1": { kind: "post", postId: "p3", ownerId: "bob2", by: "alice1", reason: "Spam", status: "open", createdAt: ago(3) },
  });
}

function ctxFor(db, over = {}) {
  const deleted = [];
  const authCalls = [];
  return {
    deleted, authCalls,
    ctx: {
      db,
      nowMs: now,
      store: { async delete(k) { deleted.push(k); } },
      wipeFiles: async () => ({ deleted: 3, more: false }),
      auth: {
        async lookup(uid) { return { email: uid + "@x.com", disabled: false, created: 0, lastLogin: 0 }; },
        async setDisabled(uid, off) { authCalls.push(["disable", uid, off]); },
        async remove(uid) { authCalls.push(["remove", uid]); },
      },
      push: async (token) => (token.endsWith("old") ? "stale" : "ok"),
      ...over,
    },
  };
}

test("stats count users, activity, content and open reports", async () => {
  const { ctx } = ctxFor(world());
  const r = await runPanelOp({ op: "stats" }, ctx);
  assert.equal(r.stats.users, 2);
  assert.equal(r.stats.new24h, 1);
  assert.equal(r.stats.activeNow, 1);
  assert.equal(r.stats.posts, 3);
  assert.equal(r.stats.clips, 1);
  assert.equal(r.stats.moments, 2);
  assert.equal(r.stats.reports, 1);
  assert.equal(r.stats.phones, 2);
});

test("users: newest first, search by username prefix and by email", async () => {
  const { ctx } = ctxFor(world());
  const all = await runPanelOp({ op: "users" }, ctx);
  assert.deepEqual(all.users.map((u) => u.username), ["alice", "bob"]);
  const b = await runPanelOp({ op: "users", q: "@Bo" }, ctx);
  assert.deepEqual(b.users.map((u) => u.uid), ["bob2"]);
  const e = await runPanelOp({ op: "users", q: "A@X.com" }, ctx);
  assert.deepEqual(e.users.map((u) => u.uid), ["alice1"]);
});

test("user detail has posts, live moments and report count", async () => {
  const { ctx } = ctxFor(world());
  const r = await runPanelOp({ op: "user", uid: "bob2" }, ctx);
  assert.equal(r.user.username, "bob");
  assert.deepEqual(r.posts.map((p) => p.id), ["p3"]);
  assert.equal(r.moments.length, 1);
  assert.equal(r.reports, 1);
  await assert.rejects(runPanelOp({ op: "user", uid: "../x" }, ctx), /Bad user id/);
});

test("ban blocks sign-in and marks the profile; unban undoes it", async () => {
  const db = world();
  const { ctx, authCalls } = ctxFor(db);
  await runPanelOp({ op: "ban", uid: "bob2", reason: "spam" }, ctx);
  assert.equal(db.docs.get("users/bob2").banned, true);
  assert.equal(db.docs.get("users/bob2").bannedReason, "spam");
  await runPanelOp({ op: "ban", uid: "bob2", on: false }, ctx);
  assert.equal(db.docs.get("users/bob2").banned, false);
  assert.deepEqual(authCalls, [["disable", "bob2", true], ["disable", "bob2", false]]);
});

test("posts list filters clips and pages", async () => {
  const { ctx } = ctxFor(world());
  assert.deepEqual((await runPanelOp({ op: "posts" }, ctx)).posts.map((p) => p.id), ["p3", "p2", "p1"]);
  assert.deepEqual((await runPanelOp({ op: "posts", kind: "clip" }, ctx)).posts.map((p) => p.id), ["p2"]);
  assert.deepEqual((await runPanelOp({ op: "posts", kind: "post" }, ctx)).posts.map((p) => p.id), ["p3", "p1"]);
});

test("deletePost removes likes, comments, files and lowers the author's count", async () => {
  const db = world();
  const { ctx, deleted } = ctxFor(db);
  const r = await runPanelOp({ op: "deletePost", id: "p1" }, ctx);
  assert.equal(r.files, 3);
  assert.deepEqual(deleted.sort(), [KEY("image", "alice1", 1), KEY("image", "alice1", 2), KEY("thumb", "alice1", 3)].sort());
  assert.ok(![...db.docs.keys()].some((k) => k.startsWith("posts/p1")));
  assert.equal(db.docs.get("users/alice1").postsCount, 1);
  assert.equal((await runPanelOp({ op: "deletePost", id: "p1" }, ctx)).gone, true);
});

test("mediaKeys only takes well-formed bucket keys", () => {
  assert.deepEqual(mediaKeys({ imageUrl: "m:../../etc", videoUrl: "https://x/y.mp4", thumbnailUrl: "m:" + KEY("thumb", "u1", 9) }), [KEY("thumb", "u1", 9)]);
});

test("deleteComment fixes the comment count", async () => {
  const db = world();
  const { ctx } = ctxFor(db);
  await runPanelOp({ op: "deleteComment", postId: "p1", id: "c1" }, ctx);
  assert.ok(!db.docs.has("posts/p1/comments/c1") && !db.docs.has("posts/p1/comments/c1/likes/alice1"));
  assert.equal(db.docs.get("posts/p1").commentCount, 0);
});

test("reports: open list with the post, then resolve", async () => {
  const db = world();
  const { ctx } = ctxFor(db);
  const r = await runPanelOp({ op: "reports" }, ctx);
  assert.equal(r.reports.length, 1);
  assert.equal(r.posts.p3.author, "bob");
  assert.equal(r.reports[0].byUsername, "alice");
  await runPanelOp({ op: "resolveReport", id: "r1", action: "removed" }, ctx);
  assert.equal(db.docs.get("reports/r1").status, "done");
  assert.equal((await runPanelOp({ op: "reports" }, ctx)).reports.length, 0);
  assert.equal((await runPanelOp({ op: "reports", status: "done" }, ctx)).reports[0].action, "removed");
});

test("broadcast skips phones with notifications off and forgets old tokens", async () => {
  const db = world();
  const sentTo = [];
  const { ctx } = ctxFor(db, { push: async (t, title, body) => { sentTo.push([t, title, body]); return t.endsWith("old") ? "stale" : "ok"; } });
  const r = await runPanelOp({ op: "broadcast", title: "Hi", body: "New stuff" }, ctx);
  assert.equal(r.sent, 1);
  assert.equal(r.failed, 1);
  assert.equal(r.more, false);
  assert.deepEqual(sentTo.map((s) => s[0]).sort(), ["ta-old", "ta1"]);
  assert.deepEqual(db.docs.get("pushTokens/alice1").tokens, ["ta1"]);
  await assert.rejects(runPanelOp({ op: "broadcast", body: " " }, ctx), /Write the message/);
});

test("deleteAccount goes through every stage, also in many small calls", async () => {
  for (const budgetMs of [8000, -1]) {
    const db = world();
    const { ctx, authCalls, deleted } = ctxFor(db, { budgetMs });
    let body = { op: "deleteAccount", uid: "alice1" };
    let calls = 0;
    const seen = new Set();
    for (;;) {
      const r = await runPanelOp(body, ctx);
      seen.add(r.stage);
      calls++;
      assert.ok(calls < 200, "never finishes");
      if (r.done) break;
      body = { op: "deleteAccount", uid: "alice1", stage: r.stage, cursor: r.cursor };
    }
    if (budgetMs < 0) assert.ok(calls > STAGES.length, `only ${calls} calls`);
    const left = [...db.docs.keys()];
    // nothing of alice is left
    for (const k of left) assert.ok(!k.includes("alice1") || k.startsWith("chats/alice1_bob2"), `left: ${k}`); // the chat stays for bob
    assert.ok(!db.docs.has("posts/p1") && !db.docs.has("posts/p2") && !db.docs.has("stories/s1"));
    assert.ok(!db.docs.has("usernames/alice"));
    // bob's things are fixed, not deleted
    const p3 = db.docs.get("posts/p3");
    assert.equal(p3.likeCount, 0);
    assert.equal(p3.viewCount, 0);
    assert.equal(p3.commentCount, 1);
    assert.ok(db.docs.has("posts/p3/comments/c3"));
    assert.equal(db.docs.get("users/bob2").followersCount, 0);
    assert.equal(db.docs.get("users/bob2").followingCount, 0);
    assert.ok(db.docs.has("chats/alice1_bob2/messages/m1") && !db.docs.has("chats/alice1_bob2/messages/m2"));
    assert.equal(db.docs.get("chats/alice1_bob2").lastText, "hi");
    assert.equal(db.docs.get("chats/alice1_bob2").lastSender, "bob2");
    assert.ok(!db.docs.has("calls/k1"));
    assert.ok(db.docs.has("stories/s2"));
    assert.deepEqual(authCalls, [["remove", "alice1"]]);
    assert.ok(deleted.length >= 4);
  }
});

test("a chat with only their messages goes away", async () => {
  const db = new FakeDb({
    "chats/x_y": { members: ["xx", "yy"] },
    "chats/x_y/messages/m": { senderId: "xx", text: "a" },
  });
  const { ctx } = ctxFor(db);
  let body = { op: "deleteAccount", uid: "xx" };
  for (;;) { const r = await runPanelOp(body, ctx); if (r.done) break; body = { ...body, stage: r.stage, cursor: r.cursor }; }
  assert.equal(db.docs.size, 0);
});

test("unknown ops and missing settings are refused through the signer", async () => {
  const env = { ADMIN_KEY: "k".repeat(40), FIREBASE_PROJECT_ID: "demo", TIGRIS_BUCKET: "b" };
  const store = { list: async () => ({ keys: [], next: "" }), delete: async () => {} };
  const call = (body, deps) => handle(new Request("https://x/api/admin", {
    method: "POST", headers: { "x-admin-key": env.ADMIN_KEY, "content-type": "application/json" }, body: JSON.stringify(body),
  }), env, "admin", store, deps);
  assert.equal((await call({ op: "nope" })).status, 400);
  assert.equal((await call({ op: "toString" })).status, 400);
  assert.equal((await call({ op: "stats" })).status, 503); // no FIREBASE_SERVICE_ACCOUNT
  const check = await (await call({ op: "check" })).json();
  assert.equal(check.panel, false);
  assert.equal(check.media, "https://b.t3.tigrisfiles.io");
  const { ctx } = ctxFor(world());
  const r = await call({ op: "stats" }, { panel: ctx });
  assert.equal(r.status, 200);
  assert.equal((await r.json()).stats.users, 2);
  const bad = await call({ op: "user", uid: "a/b" }, { panel: ctx });
  assert.equal(bad.status, 400);
});

test("restDb sends the right Firestore requests", async () => {
  const seen = [];
  const fetchFn = async (url, init = {}) => {
    if (String(url).includes("oauth2")) return new Response(JSON.stringify({ access_token: "tok", expires_in: 3600 }));
    seen.push({ url: String(url), body: init.body ? JSON.parse(init.body) : null, method: init.method });
    if (String(url).endsWith(":runQuery")) return new Response(JSON.stringify([{ document: { name: "projects/p/databases/(default)/documents/users/u1", fields: { username: { stringValue: "al" } } } }, { readTime: "x" }]));
    if (String(url).endsWith(":runAggregationQuery")) return new Response(JSON.stringify([{ result: { aggregateFields: { n: { integerValue: "7" } } } }]));
    return new Response("{}");
  };
  const { privateKey } = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign", "verify"]);
  const pem = `-----BEGIN PRIVATE KEY-----\n${Buffer.from(await crypto.subtle.exportKey("pkcs8", privateKey)).toString("base64")}\n-----END PRIVATE KEY-----`;
  const db = restDb({ email: "sa-admin@x", key: pem }, "p", fetchFn);
  const rows = await db.query("users", { orderBy: [["createdAt", "desc"]], limit: 30, after: ["2026-10-01T00:00:00.000Z", "users/u9"] });
  assert.deepEqual(rows, [{ id: "u1", path: "users/u1", data: { username: "al" } }]);
  const q = seen[0].body.structuredQuery;
  assert.equal(q.orderBy.length, 2);
  assert.equal(q.orderBy[1].field.fieldPath, "__name__");
  assert.deepEqual(q.startAt.values[0], { timestampValue: "2026-10-01T00:00:00.000Z" });
  assert.equal(q.startAt.values[1].referenceValue, "projects/p/databases/(default)/documents/users/u9");
  assert.equal(await db.count("users", [["banned", "==", true]]), 7);
  assert.equal(seen[1].body.structuredAggregationQuery.structuredQuery.where.fieldFilter.op, "EQUAL");
  await db.write([{ del: "posts/a" }, { set: "users/u1", data: {}, add: { postsCount: -1 } }]);
  const w = seen[2].body.writes;
  assert.equal(w[0].delete, "projects/p/databases/(default)/documents/posts/a");
  assert.deepEqual(w[1].updateTransforms, [{ fieldPath: "postsCount", increment: { integerValue: "-1" } }]);
  assert.deepEqual(w[1].currentDocument, { exists: true });
  await db.query("chats", { where: [["members", "array-contains", "u1"]], orderBy: [["__name__", "asc"]], after: ["chats/c1"] });
  const cq = seen[3].body.structuredQuery;
  assert.equal(cq.orderBy.length, 1);
  assert.deepEqual(cq.startAt.values, [{ referenceValue: "projects/p/databases/(default)/documents/chats/c1" }]);
  await db.write([{ put: "config/app", data: { autoHide: 3 } }, { create: "notifications/u1/items/x", data: { text: "hi" } }]);
  const pw = seen[4].body.writes;
  assert.equal(pw[0].currentDocument, undefined);
  assert.deepEqual(pw[0].updateMask, { fieldPaths: ["autoHide"] });
  assert.deepEqual(pw[1].currentDocument, { exists: false });
  assert.equal(pw[1].updateMask, undefined);
  await db.query("posts", { select: ["createdAt"], limit: 5 });
  assert.deepEqual(seen[5].body.structuredQuery.select, { fields: [{ fieldPath: "createdAt" }] });
});

test("the panel page is served with a strict policy", async () => {
  const { default: panel } = await import("../api/panel.js");
  const res = await panel.fetch(new Request("https://x/admin"));
  assert.equal(res.status, 200);
  assert.match(res.headers.get("content-security-policy"), /frame-ancestors 'none'/);
  const html = await res.text();
  assert.match(html, /InstantGram Admin/);
  assert.match(html, /\/api\/admin/);
  assert.equal((await panel.fetch(new Request("https://x/admin", { method: "POST" }))).status, 404);
});

// ---------------------------------------------------------------- v1.30 tools

test("charts: daily sign-ups, uploads, active people and the top lists", async () => {
  const db = world();
  db.docs.set("dailyStats/2026-10-09", { active: 7 });
  const { ctx } = ctxFor(db);
  const r = await runPanelOp({ op: "charts", days: 7 }, ctx);
  assert.equal(r.days.length, 7);
  assert.equal(r.days[6], "2026-10-09");
  assert.equal(r.signups[6], 1); // alice today; bob two days ago
  assert.equal(r.signups[4], 1);
  assert.equal(r.uploads[6], 3);
  assert.equal(r.clips[6], 1);
  assert.equal(r.active[6], 7);
  assert.equal(r.topPosts.length, 3);
  assert.equal(r.topCreators.length, 2);
});

test("verify, suspend for some days, warn and message with a picture", async () => {
  const db = world();
  const sent = [];
  const { ctx, authCalls } = ctxFor(db, { push: async (t, title, text, extra) => { sent.push({ t, title, text, extra }); return "ok"; } });
  await runPanelOp({ op: "verify", uid: "bob2" }, ctx);
  assert.equal(db.docs.get("users/bob2").verified, true);
  const b = await runPanelOp({ op: "ban", uid: "bob2", days: 3, reason: "spam" }, ctx);
  assert.equal(b.until, new Date(now + 3 * 86400_000).toISOString());
  assert.equal(db.docs.get("users/bob2").banned, true);
  assert.deepEqual(authCalls[0], ["disable", "bob2", false]); // login stays on for a timed suspension
  await runPanelOp({ op: "ban", uid: "bob2", on: false }, ctx);
  assert.equal(db.docs.get("users/bob2").bannedUntil, null);
  const w = await runPanelOp({ op: "notifyUser", uid: "alice1", warn: true, body: "Stop spamming" }, ctx);
  assert.equal(w.sent, 2);
  const item = db.docs.get(`notifications/alice1/items/${w.id}`);
  assert.equal(item.type, "warning");
  assert.equal(item.text, "Stop spamming");
  assert.equal(db.docs.get("users/alice1").warnings, 1);
  assert.match(sent[0].title, /Warning/);
  await runPanelOp({ op: "notifyUser", uid: "alice1", title: "Hi", body: "New stickers!", image: "https://cdn.example/x.jpg" }, ctx);
  assert.equal(sent[2].extra.image, "https://cdn.example/x.jpg");
  await assert.rejects(runPanelOp({ op: "notifyUser", uid: "alice1", body: "x", image: "javascript:alert(1)" }, ctx), /https/);
  await assert.rejects(runPanelOp({ op: "notifyUser", uid: "alice1", body: "" }, ctx), /Write/);
});

test("reset username swaps the name everywhere; reset photo removes the file", async () => {
  const db = world();
  db.docs.get("users/alice1").photoUrl = "m:" + KEY("image", "alice1", 9);
  const { ctx, deleted } = ctxFor(db);
  const r = await runPanelOp({ op: "resetUsername", uid: "alice1" }, ctx);
  assert.match(r.username, /^user_[a-z0-9]{6}$/);
  assert.equal(db.docs.get("users/alice1").username, r.username);
  assert.equal(db.docs.has("usernames/alice"), false);
  assert.equal(db.docs.get(`usernames/${r.username}`).uid, "alice1");
  assert.equal(db.docs.get("posts/p1").authorUsername, r.username);
  await runPanelOp({ op: "resetPhoto", uid: "alice1" }, ctx);
  assert.equal(db.docs.get("users/alice1").photoUrl, "");
  assert.deepEqual(deleted, [KEY("image", "alice1", 9)]);
});

test("devices, post search, hide and auto-hide setting", async () => {
  const db = world();
  db.docs.get("pushTokens/alice1").devices = { d1: { os: "android", osVersion: "14", app: "1.30.0", at: ago(2) } };
  db.docs.get("posts/p3").caption = "Sunset at the #beach";
  const { ctx } = ctxFor(db);
  const d = await runPanelOp({ op: "devices", uid: "alice1" }, ctx);
  assert.equal(d.phones, 2);
  assert.equal(d.devices[0].os, "android");
  assert.deepEqual((await runPanelOp({ op: "searchPosts", q: "#BEACH" }, ctx)).posts.map((p) => p.id), ["p3"]);
  assert.deepEqual((await runPanelOp({ op: "searchPosts", q: "@alice" }, ctx)).posts.map((p) => p.id), ["p2", "p1"]);
  await runPanelOp({ op: "hidePost", id: "p3" }, ctx);
  assert.equal(db.docs.get("posts/p3").hidden, true);
  assert.equal((await runPanelOp({ op: "config", set: { autoHide: 5 } }, ctx)).config.autoHide, 5);
  assert.equal(db.docs.get("config/app").autoHide, 5);
});

test("chats can only be read when reported", async () => {
  const db = world();
  const { ctx } = ctxFor(db);
  await assert.rejects(runPanelOp({ op: "chat", chatId: "alice1_bob2" }, ctx), /reported/);
  db.docs.set("reports/r2", { kind: "chat", chatId: "alice1_bob2", by: "alice1", status: "open" });
  const c = await runPanelOp({ op: "chat", chatId: "alice1_bob2" }, ctx);
  assert.deepEqual(c.messages.map((m) => m.text), ["hi", "bye"]);
  assert.equal(c.names.bob2, "bob");
  await runPanelOp({ op: "deleteMessage", chatId: "alice1_bob2", id: "m1" }, ctx);
  assert.equal(db.docs.has("chats/alice1_bob2/messages/m1"), false);
});

test("pictures are uploaded for notifications; only real images", async () => {
  const puts = [];
  const { ctx } = ctxFor(world(), { publicBase: "https://media.example/", store: { async put(k, b, t) { puts.push([k, b.length, t]); }, async delete() {} } });
  const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0]).toString("base64");
  const r = await runPanelOp({ op: "uploadImage", data: "data:image/png;base64," + png }, ctx);
  assert.match(r.key, /^image\/admin\/[a-f0-9]{32}\.png$/);
  assert.equal(r.url, "https://media.example/" + r.key);
  assert.equal(puts[0][2], "image/png");
  await assert.rejects(runPanelOp({ op: "uploadImage", data: Buffer.from("hello world!").toString("base64") }, ctx), /JPG/);
});

test("deleting an account can block its email; the list can be edited", async () => {
  const db = world();
  const { ctx } = ctxFor(db);
  let r = await runPanelOp({ op: "deleteAccount", uid: "bob2", blockEmail: true }, ctx);
  assert.equal(r.blocked, "bob2@x.com");
  assert.equal(db.docs.get("blockedEmails/bob2@x.com").uid, "bob2");
  const l = await runPanelOp({ op: "blockedEmails", add: "Spam@Mail.com" }, ctx);
  assert.deepEqual(l.emails.map((e) => e.email).sort(), ["bob2@x.com", "spam@mail.com"]);
  r = await runPanelOp({ op: "blockedEmails", remove: "bob2@x.com" }, ctx);
  assert.deepEqual(r.emails.map((e) => e.email), ["spam@mail.com"]);
  await assert.rejects(runPanelOp({ op: "blockedEmails", add: "nope" }, ctx), /Bad email/);
});

// ---------------------------------------------------------------- v1.31 moderation

test("modScan queues bad captions and names, hides blocked ones, and moves on", async () => {
  const db = world();
  db.docs.get("posts/p1").caption = "what the fuck";
  db.docs.get("posts/p2").caption = "madarchod";
  db.docs.set("users/carl3", { username: "fuck_boi", createdAt: ago(5) });
  const { ctx } = ctxFor(db);
  const r = await runPanelOp({ op: "modScan" }, ctx);
  assert.equal(r.flagged, 3);
  assert.equal(db.docs.get("modQueue/post_p1").severity, "mild");
  assert.equal(db.docs.get("posts/p1").hidden, undefined);
  assert.equal(db.docs.get("modQueue/post_p2").severity, "blocked");
  assert.equal(db.docs.get("posts/p2").hidden, true);
  assert.equal(db.docs.get("modQueue/user_carl3").kind, "user");
  assert.ok(db.docs.get("config/modscan").postsAt instanceof Date);
  const again = await runPanelOp({ op: "modScan" }, ctx);
  assert.equal(again.flagged, 0); // nothing new since
  const q = await runPanelOp({ op: "modQueue" }, ctx);
  assert.equal(q.items.length, 3);
  assert.equal(q.posts.p2.hidden, true);
  await runPanelOp({ op: "modResolve", id: "post_p2", action: "approved" }, ctx);
  assert.equal(db.docs.get("posts/p2").hidden, false);
  assert.equal(db.docs.get("modQueue/post_p2").status, "done");
  assert.equal((await runPanelOp({ op: "stats" }, ctx)).stats.review, 2);
});

test("modWords saves the panel lists; modTest tries a text", async () => {
  const db = world();
  const { ctx } = ctxFor(db);
  const w = await runPanelOp({ op: "modWords", set: { blocked: ["ScamLink", "", 5], mild: ["meanie"], allow: ["ass"] } }, ctx);
  assert.deepEqual(w.blocked, ["scamlink"]);
  assert.ok(w.defaults.blocked > 0);
  assert.equal((await runPanelOp({ op: "modTest", text: "go to scamlink" }, ctx)).blocked, true);
  assert.equal((await runPanelOp({ op: "modTest", text: "ass" }, ctx)).clean, true);
});

// ---------------------------------------------------------------- v1.32 photos + trust

test("trustOf: new accounts near 40, age/followers/posts add, strikes take away", () => {
  const n = Date.now();
  const day = 86400_000;
  assert.equal(trustOf({ createdAt: new Date(n) }, n), 40);
  assert.equal(trustOf({ createdAt: new Date(n - 90 * day), followersCount: 1000, postsCount: 20 }, n), 80);
  assert.equal(trustOf({ createdAt: new Date(n), verified: true }, n), 55);
  assert.equal(trustOf({ createdAt: new Date(n), strikes: 1, flags: 1 }, n), 20);
  assert.equal(trustOf({ createdAt: new Date(n), warnings: 9 }, n), 0);
  assert.equal(trustOf({ createdAt: new Date(n - 90 * day), banned: true }, n), 0);
});

test("imageFlag: likely nudity and unchecked photos go to review", () => {
  assert.equal(imageFlag({ sensitive: true, nsfw: 0.93 }).severity, "image");
  assert.equal(imageFlag({ sensitive: true, nsfw: 0.7 }), null); // blurred, no review
  assert.equal(imageFlag({ imgCheck: "skipped" }).severity, "unchecked");
  assert.equal(imageFlag({ imgCheck: "ok" }), null);
});

test("modScan queues flagged photos and works out trust; resolving adds strikes", async () => {
  const db = world();
  db.docs.get("posts/p1").sensitive = true;
  db.docs.get("posts/p1").nsfw = 0.91;
  db.docs.get("posts/p2").imgCheck = "skipped";
  const { ctx } = ctxFor(db);
  const r = await runPanelOp({ op: "modScan" }, ctx);
  assert.equal(db.docs.get("modQueue/post_p1").severity, "image");
  assert.equal(db.docs.get("modQueue/post_p2").severity, "unchecked");
  assert.ok(r.trusted > 0);
  assert.equal(typeof db.docs.get("users/bob2").trust, "number");
  assert.ok(db.docs.get("config/modscan").trustAt instanceof Date);
  const author = db.docs.get("modQueue/post_p1").uid;
  const before = db.docs.get(`users/${author}`).trust;
  await runPanelOp({ op: "modResolve", id: "post_p1", action: "hidden" }, ctx);
  assert.equal(db.docs.get(`users/${author}`).strikes, 1);
  assert.equal(db.docs.get(`users/${author}`).trust, Math.max(0, before - 15));
  await runPanelOp({ op: "modResolve", id: "post_p2", action: "blurred" }, ctx);
  assert.equal(db.docs.get("posts/p2").sensitive, true);
  const t = await runPanelOp({ op: "trust", uid: author }, ctx);
  assert.equal(t.trust, db.docs.get(`users/${author}`).trust);
  const again = await runPanelOp({ op: "modScan" }, ctx);
  assert.equal(again.trusted, 0); // once a day
});
