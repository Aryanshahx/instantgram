import test from "node:test";
import assert from "node:assert/strict";
import { notify, serviceAccount, messageBody, activityBody, decodeValue, forgetToken } from "../lib/push.js";

// a made-up service account with a real RSA key, so signing really runs
const pair = await crypto.subtle.generateKey(
  { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
  true, ["sign", "verify"],
);
const pkcs8 = Buffer.from(await crypto.subtle.exportKey("pkcs8", pair.privateKey)).toString("base64");
const pem = `-----BEGIN PRIVATE KEY-----\n${pkcs8.match(/.{1,64}/g).join("\n")}\n-----END PRIVATE KEY-----\n`;
const SA = { type: "service_account", project_id: "demo-p", client_email: "push@demo-p.iam.gserviceaccount.com", private_key: pem };
const ENV = { FIREBASE_SERVICE_ACCOUNT: JSON.stringify(SA) };
const NOW = Date.parse("2026-10-08T12:00:00Z");

const enc = (v) => {
  if (v instanceof Date) return { timestampValue: v.toISOString() };
  if (typeof v === "string") return { stringValue: v };
  if (typeof v === "boolean") return { booleanValue: v };
  if (typeof v === "number") return { integerValue: String(v) };
  if (Array.isArray(v)) return { arrayValue: { values: v.map(enc) } };
  if (v && typeof v === "object") return { mapValue: { fields: Object.fromEntries(Object.entries(v).map(([k, x]) => [k, enc(x)])) } };
  return { nullValue: null };
};

/** A fake Google: docs = {path: fields}; records what was sent. */
function fakeGoogle(docs, { fcmStatus = () => 200 } = {}) {
  const sent = [];
  const patched = [];
  const fetch = async (url, init = {}) => {
    url = String(url);
    if (url.startsWith("https://oauth2.googleapis.com/token")) {
      assert.match(String(init.body), /assertion=[\w-]+\.[\w-]+\.[\w-]+/);
      return new Response(JSON.stringify({ access_token: "AT", expires_in: 3600 }));
    }
    const fs = url.match(/documents\/([^?]+)/);
    if (fs && (init.method || "GET") === "GET") {
      const d = docs[fs[1]];
      if (!d) return new Response("{}", { status: 404 });
      return new Response(JSON.stringify({ fields: enc(d).mapValue.fields }));
    }
    if (fs && init.method === "PATCH") {
      patched.push({ path: fs[1], body: JSON.parse(init.body) });
      return new Response("{}");
    }
    if (url.includes("fcm.googleapis.com")) {
      assert.equal(init.headers.authorization, "Bearer AT");
      const msg = JSON.parse(init.body).message;
      sent.push(msg);
      return new Response("{}", { status: fcmStatus(msg.token) });
    }
    throw new Error("unexpected " + url);
  };
  return { fetch, sent, patched };
}

const recent = new Date(NOW - 5000);
const base = () => ({
  "chats/a_b": { members: ["a", "b"] },
  "chats/a_b/messages/m1": { senderId: "a", type: "text", text: "hello there", createdAt: recent },
  "users/a": { username: "aryan" },
  "pushTokens/b": { tokens: ["t1", "t2"] },
});

test("service account: JSON or base64; missing = not set up", async () => {
  assert.equal(serviceAccount(ENV).project, "demo-p");
  assert.equal(serviceAccount({ FIREBASE_SERVICE_ACCOUNT: Buffer.from(JSON.stringify(SA)).toString("base64") }).email, SA.client_email);
  assert.equal(serviceAccount({}), null);
  assert.equal(serviceAccount({ FIREBASE_SERVICE_ACCOUNT: "{bad" }), null);
  const r = await notify({ kind: "message" }, {}, "a");
  assert.equal(r.status, 503);
});

test("texts", () => {
  assert.equal(messageBody({ type: "text", text: "hi" }), "hi");
  assert.equal(messageBody({ type: "text", text: "secret", vanish: "seen" }), "Sent a disappearing message");
  assert.match(messageBody({ type: "image" }), /photo/);
  assert.equal(messageBody({ type: "post", postIsClip: true }), "Shared a clip");
  assert.equal(messageBody({ type: "call" }), null);
  assert.equal(messageBody({ type: "system" }), null);
  assert.equal(messageBody({ type: "text", text: "x", deleted: true }), null);
  assert.equal(activityBody({ type: "like", actorName: "zoe" }), "zoe liked your post");
  assert.equal(activityBody({ type: "super", actorName: "zoe" }), "zoe sent you a super heart 💖");
  assert.equal(activityBody({ type: "comment", actorName: "zoe", text: "nice" }), "zoe commented: nice");
  assert.equal(activityBody({ type: "follow", actorName: "zoe" }), "zoe started following you");
  assert.deepEqual(decodeValue({ mapValue: { fields: { a: { arrayValue: { values: [{ integerValue: "3" }] } } } } }), { a: [3] });
});

test("a message is pushed to every phone of the other person", async () => {
  forgetToken();
  const g = fakeGoogle(base());
  const r = await notify({ kind: "message", chatId: "a_b", messageId: "m1" }, ENV, "a", { fetch: g.fetch, now: NOW });
  assert.equal(r.status, 200);
  assert.equal(r.body.sent, 2);
  assert.deepEqual(g.sent.map((m) => m.token), ["t1", "t2"]);
  const m = g.sent[0];
  assert.equal(m.notification.title, "aryan");
  assert.equal(m.notification.body, "hello there");
  assert.equal(m.android.notification.channel_id, "messages");
  assert.equal(m.android.notification.icon, "ic_stat_instantgram");
  assert.deepEqual(m.data, { type: "message", from: "a", chatId: "a_b" });
});

test("no push: not a member, someone else's message, old message, muted, blocked, off", async () => {
  const run = async (docs, uid = "a", body = { kind: "message", chatId: "a_b", messageId: "m1" }) => {
    forgetToken();
    const g = fakeGoogle(docs);
    const r = await notify(body, ENV, uid, { fetch: g.fetch, now: NOW });
    return { r, sent: g.sent.length };
  };
  assert.equal((await run(base(), "c")).r.status, 403);
  const other = base(); other["chats/a_b/messages/m1"].senderId = "b";
  assert.equal((await run(other)).r.status, 403);
  const old = base(); old["chats/a_b/messages/m1"].createdAt = new Date(NOW - 3600_000);
  assert.equal((await run(old)).r.status, 403);
  const muted = base(); muted["chats/a_b"].muteMessages = { b: true };
  assert.equal((await run(muted)).r.body.skipped, "muted");
  const mutedByMe = base(); mutedByMe["chats/a_b"].muteMessages = { a: true };
  assert.equal((await run(mutedByMe)).sent, 2, "my own mute does not silence the other person");
  const blocked = base(); blocked["users/b/blocked/a"] = { at: recent };
  assert.equal((await run(blocked)).r.body.skipped, "blocked");
  const off = base(); off["pushTokens/b"].off = true;
  assert.equal((await run(off)).sent, 0);
  assert.equal((await run(base(), "a", { kind: "message", chatId: "../x", messageId: "m1" })).r.status, 400);
  assert.equal((await run(base(), "a", { kind: "nope" })).r.status, 400);
});

test("calls: only the caller of a ringing call; video text", async () => {
  forgetToken();
  const docs = { ...base(), "calls/c1": { callerId: "a", calleeId: "b", video: true, status: "ringing", createdAt: recent } };
  const g = fakeGoogle(docs);
  const r = await notify({ kind: "call", callId: "c1" }, ENV, "a", { fetch: g.fetch, now: NOW });
  assert.equal(r.body.sent, 2);
  assert.match(g.sent[0].notification.body, /video call/);
  assert.equal(g.sent[0].android.notification.channel_id, "calls");
  assert.equal(g.sent[0].android.ttl, "40s");
  const r2 = await notify({ kind: "call", callId: "c1" }, ENV, "b", { fetch: g.fetch, now: NOW });
  assert.equal(r2.status, 403);
  docs["calls/c1"].status = "ended";
  assert.equal((await notify({ kind: "call", callId: "c1" }, ENV, "a", { fetch: g.fetch, now: NOW })).status, 403);
});

test("activity: the actor must be the caller", async () => {
  forgetToken();
  const docs = { ...base(), "notifications/b/items/n1": { type: "comment", actorId: "a", actorName: "aryan", text: "wow", postId: "p1", at: recent } };
  const g = fakeGoogle(docs);
  const r = await notify({ kind: "activity", to: "b", itemId: "n1" }, ENV, "a", { fetch: g.fetch, now: NOW });
  assert.equal(r.body.sent, 2);
  assert.equal(g.sent[0].notification.body, "aryan commented: wow");
  assert.equal(g.sent[0].data.postId, "p1");
  assert.equal((await notify({ kind: "activity", to: "b", itemId: "n1" }, ENV, "c", { fetch: g.fetch, now: NOW })).status, 403);
});

test("phones that are gone are removed from the list", async () => {
  forgetToken();
  const g = fakeGoogle(base(), { fcmStatus: (t) => (t === "t1" ? 404 : 200) });
  const r = await notify({ kind: "message", chatId: "a_b", messageId: "m1" }, ENV, "a", { fetch: g.fetch, now: NOW });
  assert.equal(r.body.sent, 1);
  assert.equal(g.patched.length, 1);
  assert.equal(g.patched[0].path, "pushTokens/b");
  assert.deepEqual(g.patched[0].body.fields.tokens.arrayValue.values, [{ stringValue: "t2" }]);
});

test("story view: only the first view of a picked person, once", async () => {
  forgetToken();
  const docs = {
    ...base(),
    "stories/s1": { authorId: "b" },
    "stories/s1/views/a": { count: 1, first: recent, last: recent },
    "storyAlerts/b": { uids: ["a"] },
  };
  const g = fakeGoogle(docs);
  const created = [];
  const fetch = async (url, init = {}) => {
    if (init.method === "POST" && String(url).includes("/documents/notifications/b/items")) {
      created.push(JSON.parse(init.body).fields);
      return new Response("{}");
    }
    if (init.method === "PATCH" && String(url).includes("/views/a")) {
      assert.match(String(url), /updateMask.fieldPaths=alerted/);
      docs["stories/s1/views/a"].alerted = true;
      return new Response("{}");
    }
    return g.fetch(url, init);
  };
  const r = await notify({ kind: "storyView", storyId: "s1" }, ENV, "a", { fetch, now: NOW });
  assert.equal(r.body.sent, 2);
  assert.equal(g.sent[0].notification.body, "aryan viewed your moment");
  assert.equal(created.length, 1);
  assert.equal(created[0].type.stringValue, "story_view");
  assert.equal(created[0].actorId.stringValue, "a");
  // second call: already told
  const again = await notify({ kind: "storyView", storyId: "s1" }, ENV, "a", { fetch, now: NOW });
  assert.equal(again.body.skipped, "already");
  // not on the list
  docs["storyAlerts/b"].uids = ["zed"];
  delete docs["stories/s1/views/a"].alerted;
  assert.equal((await notify({ kind: "storyView", storyId: "s1" }, ENV, "a", { fetch, now: NOW })).body.skipped, "not picked");
  // no view line / old view
  assert.equal((await notify({ kind: "storyView", storyId: "s1" }, ENV, "c", { fetch, now: NOW })).status, 403);
  docs["stories/s1/views/a"].first = new Date(NOW - 3600_000);
  assert.equal((await notify({ kind: "storyView", storyId: "s1" }, ENV, "a", { fetch, now: NOW })).status, 403);
});

test("story view of a list-only moment reads privateStories", async () => {
  forgetToken();
  const docs = {
    ...base(),
    "privateStories/s9": { authorId: "b", audience: ["a", "b"] },
    "privateStories/s9/views/a": { count: 1, first: recent, last: recent },
    "storyAlerts/b": { uids: ["a"] },
  };
  const g = fakeGoogle(docs);
  const fetch = async (url, init = {}) => {
    if (init.method === "POST" || init.method === "PATCH") {
      if (String(url).includes("/views/a")) assert.match(String(url), /privateStories\/s9\/views\/a/);
      return new Response("{}");
    }
    return g.fetch(url, init);
  };
  const r = await notify({ kind: "storyView", storyId: "s9", col: "p" }, ENV, "a", { fetch, now: NOW });
  assert.equal(r.body.sent, 2);
  // without col it looks in stories (not there)
  assert.equal((await notify({ kind: "storyView", storyId: "s9" }, ENV, "a", { fetch, now: NOW })).status, 403);
});

test("test kind: to my own phones, and says why it failed", async () => {
  forgetToken();
  const g = fakeGoogle({ "pushTokens/b": { tokens: ["t1"] } });
  const r = await notify({ kind: "test" }, ENV, "b", { fetch: g.fetch, now: NOW });
  assert.equal(r.body.ok, true);
  assert.equal(r.body.sent, 1);
  assert.equal(g.sent[0].token, "t1");

  const none = await notify({ kind: "test" }, ENV, "zz", { fetch: g.fetch, now: NOW });
  assert.equal(none.body.ok, false);
  assert.match(none.body.detail, /no phone/);

  forgetToken();
  const bad = fakeGoogle({ "pushTokens/b": { tokens: ["t1"] } }, { fcmStatus: () => 403 });
  const r2 = await notify({ kind: "test" }, ENV, "b", { fetch: bad.fetch, now: NOW });
  assert.equal(r2.body.ok, false);
  assert.match(r2.body.detail, /403/);
  assert.match(r2.body.detail, /Cloud Messaging API/);
});

test("moment likes have their own lines", () => {
  assert.equal(activityBody({ type: "story_like", actorName: "a" }), "a liked your moment");
  assert.match(activityBody({ type: "story_super", actorName: "a" }), /super heart/);
});
