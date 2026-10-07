import test from "node:test";
import assert from "node:assert/strict";
import { handle, presign, s3Store, verifyFirebaseToken, AuthError, sniffOk, parseKey, LIMITS } from "../lib/core.js";

const PROJECT = "demo-project";
const b64u = (buf) => Buffer.from(buf).toString("base64url");

// ---- a fake Google (we sign tokens ourselves and serve the public key as the JWKS)
const pair = await crypto.subtle.generateKey(
  { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
  true, ["sign", "verify"],
);
const jwk = { ...(await crypto.subtle.exportKey("jwk", pair.publicKey)), kid: "k1", alg: "RS256", use: "sig" };
const realFetch = globalThis.fetch;
globalThis.fetch = async (url, init) => {
  if (String(url).includes("securetoken@system.gserviceaccount.com")) {
    return new Response(JSON.stringify({ keys: [jwk] }), { status: 200 });
  }
  return realFetch(url, init);
};

async function token(over = {}, header = {}, key = pair.privateKey) {
  const now = Math.floor(Date.now() / 1000);
  const claims = {
    iss: `https://securetoken.google.com/${PROJECT}`, aud: PROJECT, sub: "user1abc",
    iat: now - 5, exp: now + 3600, ...over,
  };
  const h = { alg: "RS256", kid: "k1", typ: "JWT", ...header };
  const data = `${b64u(JSON.stringify(h))}.${b64u(JSON.stringify(claims))}`;
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(data));
  return `${data}.${b64u(sig)}`;
}

// ---- fake storage (same interface as s3Store)
class FakeBucket {
  constructor() { this.objs = new Map(); this.deleted = []; }
  put(key, bytes) { this.objs.set(key, new Uint8Array(bytes)); }
  async head(key) { const o = this.objs.get(key); return o ? { size: o.length } : null; }
  async get(key, opts) {
    const o = this.objs.get(key);
    if (!o) return null;
    const part = opts?.range ? o.slice(opts.range.offset, opts.range.offset + opts.range.length) : o;
    return { arrayBuffer: async () => part.buffer.slice(part.byteOffset, part.byteOffset + part.byteLength) };
  }
  async delete(key) { this.objs.delete(key); this.deleted.push(key); }
}

const baseEnv = () => ({
  FIREBASE_PROJECT_ID: PROJECT, TIGRIS_BUCKET: "instantgram-media",
  TIGRIS_ACCESS_KEY_ID: "tid_test", TIGRIS_SECRET_ACCESS_KEY: "sekret", BUCKET: new FakeBucket(),
});

// env.BUCKET (when present) is used as the storage, like the real s3Store would be
const call = async (path, body, tok, env = baseEnv(), method = "POST") =>
  handle(new Request("https://w.example/api" + path, {
    method,
    headers: { "content-type": "application/json", ...(tok ? { authorization: "Bearer " + tok } : {}) },
    body: method === "POST" ? JSON.stringify(body ?? {}) : undefined,
  }), env, path.slice(1), path === "/sign" ? null : env.BUCKET);

// ---------------------------------------------------------------- tests
test("SigV4 presign matches the AWS documentation example", async () => {
  // https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-query-string-auth.html
  const url = await presign({
    method: "GET", host: "examplebucket.s3.amazonaws.com", path: "/test.txt", region: "us-east-1",
    service: "s3", accessKeyId: "AKIAIOSFODNN7EXAMPLE",
    secret: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", expires: 86400,
    date: new Date("2013-05-24T00:00:00Z"),
  });
  assert.ok(url.endsWith("X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"), url);
  assert.ok(url.startsWith("https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request"));
});

test("Firebase tokens: good one passes, bad ones are refused", async () => {
  assert.equal(await verifyFirebaseToken(await token(), PROJECT), "user1abc");
  const now = Math.floor(Date.now() / 1000);
  const other = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign"]);
  const bad = [
    await token({ exp: now - 600 }), await token({ aud: "other" }), await token({ iss: "https://evil" }),
    await token({ sub: "" }), await token({ iat: now + 600 }), await token({}, { kid: "nope" }),
    await token({}, {}, other.privateKey), await token({}, { alg: "none" }), "garbage", "",
  ];
  for (const t of bad) await assert.rejects(() => verifyFirebaseToken(t, PROJECT), AuthError);
});

test("keys are parsed strictly", () => {
  const id = "a".repeat(32);
  assert.deepEqual(parseKey(`video/u1/${id}.mp4`), { kind: "video", uid: "u1", ext: "mp4" });
  for (const k of [`video/u1/${id}.mp4/..`, `x/u1/${id}.mp4`, `video/u1/short.mp4`, `video/../${id}.mp4`, "", undefined])
    assert.equal(parseKey(k), null);
});

test("sniffing", () => {
  const mp4 = Uint8Array.from([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x6d, 0x70, 0x34, 0x32, 0, 0, 0, 0]);
  const jpg = Uint8Array.from([0xff, 0xd8, 0xff, 0xe0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  assert.ok(sniffOk(mp4, "video") && !sniffOk(jpg, "video"));
  assert.ok(sniffOk(jpg, "image") && sniffOk(jpg, "thumb") && !sniffOk(mp4, "image"));
});

test("sign: needs login, checks input, returns links under the user's folder", async () => {
  assert.equal((await call("/sign", { kind: "video", ext: "mp4" })).status, 401);
  assert.equal((await call("/sign", { kind: "video", ext: "mp4" }, "junk")).status, 401);
  const t = await token();
  assert.equal((await call("/sign", { kind: "audio", ext: "mp3" }, t)).status, 400);
  assert.equal((await call("/sign", { kind: "video", ext: "html" }, t)).status, 400);
  assert.equal((await call("/sign", { kind: "image", ext: "mp4" }, t)).status, 400);
  const res = await call("/sign", { kind: "video", ext: "MP4", thumb: true }, t);
  assert.equal(res.status, 200);
  const j = await res.json();
  assert.match(j.key, /^video\/user1abc\/[a-f0-9]{32}\.mp4$/);
  assert.match(j.thumbKey, /^thumb\/user1abc\/[a-f0-9]{32}\.jpg$/);
  assert.equal(j.type, "video/mp4");
  assert.ok(j.url.startsWith(`https://instantgram-media.t3.storage.dev/${j.key}?`));
  assert.ok(j.url.includes("X-Amz-Credential=tid_test%2F"));
  assert.ok(j.url.includes("X-Amz-Signature=") && j.url.includes("X-Amz-SignedHeaders=host"));
  assert.ok(!JSON.stringify(j).includes("sekret"));
  const img = await (await call("/sign", { kind: "image", ext: "jpg", thumb: true }, t)).json();
  assert.equal(img.thumbKey, undefined); // thumbs only for video
  const noCfg = baseEnv(); delete noCfg.TIGRIS_SECRET_ACCESS_KEY;
  assert.equal((await call("/sign", { kind: "image", ext: "jpg" }, t, noCfg)).status, 500);
  const weird = await token({ sub: "a/../b" });
  assert.equal((await call("/sign", { kind: "image", ext: "jpg" }, weird)).status, 403);
});

test("confirm: accepts real files, deletes bad or oversized ones, protects other users", async () => {
  const env = baseEnv();
  const t = await token();
  const id = "b".repeat(32);
  const mp4 = new Uint8Array(2000); mp4.set([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70], 0);
  env.BUCKET.put(`video/user1abc/${id}.mp4`, mp4);
  const ok = await call("/confirm", { key: `video/user1abc/${id}.mp4` }, t, env);
  assert.equal(ok.status, 200); assert.equal((await ok.json()).size, 2000);

  env.BUCKET.put(`video/user1abc/${"c".repeat(32)}.mp4`, new Uint8Array(100).fill(65)); // text, not a video
  const wrong = await call("/confirm", { key: `video/user1abc/${"c".repeat(32)}.mp4` }, t, env);
  assert.equal(wrong.status, 400);
  assert.ok(env.BUCKET.deleted.includes(`video/user1abc/${"c".repeat(32)}.mp4`));

  const big = new Uint8Array(LIMITS.thumb + 1); big.set([0xff, 0xd8, 0xff]);
  env.BUCKET.put(`thumb/user1abc/${"d".repeat(32)}.jpg`, big);
  assert.equal((await call("/confirm", { key: `thumb/user1abc/${"d".repeat(32)}.jpg` }, t, env)).status, 413);
  assert.ok(env.BUCKET.deleted.includes(`thumb/user1abc/${"d".repeat(32)}.jpg`));

  assert.equal((await call("/confirm", { key: `video/user1abc/${"e".repeat(32)}.mp4` }, t, env)).status, 404);
  assert.equal((await call("/confirm", { key: `video/someoneelse/${id}.mp4` }, t, env)).status, 403);
  assert.equal((await call("/confirm", { key: "../x" }, t, env)).status, 400);
  assert.equal((await call("/confirm", { key: `video/user1abc/${id}.mp4` }, null, env)).status, 401);
});

test("delete: only your own files", async () => {
  const env = baseEnv();
  const t = await token();
  const mine = `image/user1abc/${"a".repeat(32)}.jpg`;
  env.BUCKET.put(mine, new Uint8Array(10));
  const theirs = `image/other/${"a".repeat(32)}.jpg`;
  env.BUCKET.put(theirs, new Uint8Array(10));
  assert.equal((await call("/delete", { keys: [theirs] }, t, env)).status, 403);
  assert.ok(env.BUCKET.objs.has(theirs));
  assert.equal((await call("/delete", { keys: [mine, theirs] }, t, env)).status, 403);
  assert.ok(env.BUCKET.objs.has(mine)); // nothing deleted when any key is not yours
  const ok = await call("/delete", { keys: [mine] }, t, env);
  assert.equal(ok.status, 200); assert.ok(!env.BUCKET.objs.has(mine));
  assert.equal((await call("/delete", { keys: [mine] }, null, env)).status, 401);
});

test("health and unknown routes", async () => {
  const health = await call("/health", null, null, baseEnv(), "GET");
  assert.equal(health.status, 200);
  assert.deepEqual(await health.json(), { ok: true, ready: true, music: true, musicKey: false });
  const half = baseEnv(); delete half.TIGRIS_BUCKET;
  assert.equal((await (await call("/health", null, null, half, "GET")).json()).ready, false);
  assert.equal((await call("/nope", {}, await token())).status, 404);
  assert.equal((await call("/sign", null, null, baseEnv(), "GET")).status, 404);
});

// ---- an in-process fake Tigris: checks every signature exactly like S3 would
test("s3Store talks to a signed S3 API: head / ranged get / delete, and sign links work", async () => {
  const env = { ...baseEnv(), BUCKET: undefined };
  const objects = new Map();
  const seen = [];
  const prevFetch = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const u = new URL(String(input));
    if (u.hostname !== "instantgram-media.t3.storage.dev") return prevFetch(input, init);
    const method = (init.method || "GET").toUpperCase();
    seen.push(method);
    // re-sign with the same date and compare
    const stamp = u.searchParams.get("X-Amz-Date");
    const date = new Date(`${stamp.slice(0, 4)}-${stamp.slice(4, 6)}-${stamp.slice(6, 8)}T${stamp.slice(9, 11)}:${stamp.slice(11, 13)}:${stamp.slice(13, 15)}Z`);
    const expect = await presign({
      method, host: u.host, path: decodeURIComponent(u.pathname), region: "auto", service: "s3",
      accessKeyId: "tid_test", secret: "sekret", expires: Number(u.searchParams.get("X-Amz-Expires")), date,
    });
    if (new URL(expect).searchParams.get("X-Amz-Signature") !== u.searchParams.get("X-Amz-Signature"))
      return new Response("<Error><Code>SignatureDoesNotMatch</Code></Error>", { status: 403 });
    const key = decodeURIComponent(u.pathname.slice(1));
    if (method === "PUT") { objects.set(key, new Uint8Array(await new Response(init.body).arrayBuffer())); return new Response("", { status: 200 }); }
    if (method === "DELETE") { objects.delete(key); return new Response(null, { status: 204 }); }
    const o = objects.get(key);
    if (!o) return new Response("<Error><Code>NoSuchKey</Code></Error>", { status: 404 });
    if (method === "HEAD") return new Response(null, { status: 200, headers: { "content-length": String(o.length) } });
    const m = /bytes=(\d+)-(\d+)/.exec(new Headers(init.headers).get("range") || "");
    return m ? new Response(o.slice(Number(m[1]), Number(m[2]) + 1), { status: 206 }) : new Response(o, { status: 200 });
  };
  try {
    const t = await token();
    const sign = await (await call("/sign", { kind: "video", ext: "mp4", thumb: true }, t, env)).json();
    // "upload" with the signed link exactly as the app does
    const mp4 = new Uint8Array(5000); mp4.set([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70]);
    assert.equal((await fetch(sign.url, { method: "PUT", body: mp4 })).status, 200);
    // a link made for another key or method must not work
    assert.equal((await fetch(sign.url.replace(sign.key, "video/user1abc/" + "f".repeat(32) + ".mp4"), { method: "PUT", body: mp4 })).status, 403);
    assert.equal((await fetch(sign.url, { method: "DELETE" })).status, 403);
    // confirm through the real s3Store
    const real = s3Store(env);
    const ok = await handle(new Request("https://x/api/confirm", { method: "POST", headers: { authorization: "Bearer " + t }, body: JSON.stringify({ key: sign.key }) }), env, "confirm");
    assert.equal(ok.status, 200); assert.equal((await ok.json()).size, 5000);
    // a text file uploaded as .mp4 is rejected and removed
    const bad = await (await call("/sign", { kind: "video", ext: "mp4" }, t, env)).json();
    await fetch(bad.url, { method: "PUT", body: new TextEncoder().encode("<html>not a video</html>") });
    const rej = await handle(new Request("https://x/api/confirm", { method: "POST", headers: { authorization: "Bearer " + t }, body: JSON.stringify({ key: bad.key }) }), env, "confirm");
    assert.equal(rej.status, 400); assert.ok(!objects.has(bad.key));
    // never uploaded -> 404 after retries
    assert.equal(await real.head("video/user1abc/" + "9".repeat(32) + ".mp4"), null);
    // delete
    const del = await handle(new Request("https://x/api/delete", { method: "POST", headers: { authorization: "Bearer " + t }, body: JSON.stringify({ keys: [sign.key] }) }), env, "delete");
    assert.equal(del.status, 200); assert.ok(!objects.has(sign.key));
    assert.ok(seen.includes("HEAD") && seen.includes("GET") && seen.includes("DELETE"));
  } finally {
    globalThis.fetch = prevFetch;
  }
});

const ID1 = "74230e03-50fd-4dcf-b665-90731e275907";
const ID2 = "cc41efd9-ab00-4e06-a21a-ba3e7d2ae5e8";

test("music: search and stream link come from Openverse, no key needed", async () => {
  const prevFetch = globalThis.fetch;
  const seen = [];
  globalThis.fetch = async (url, init) => {
    const u = String(url);
    if (u.includes("securetoken@system.gserviceaccount.com")) return new Response(JSON.stringify({ keys: [jwk] }), { status: 200 });
    if (u.startsWith("https://api.openverse.org/v1/")) {
      seen.push({ url: new URL(u), auth: init && init.headers && init.headers.authorization });
      if (u.includes("/audio/" + ID1 + "/")) return new Response(JSON.stringify({ id: ID1, url: "https://prod-1.storage.jamendo.com/?trackid=1&format=mp32" }), { status: 200 });
      if (u.includes("/audio/" + ID2 + "/")) return new Response(JSON.stringify({ id: ID2, url: "http://insecure/x.mp3" }), { status: 200 });
      return new Response(JSON.stringify({
        page_count: 3,
        results: [
          { id: ID1, title: "Sunrise", creator: "Ann", duration: 143000, thumbnail: "https://api.openverse.org/v1/audio/x/thumb/", secret: "x" },
          { id: "not-a-uuid", title: "Broken", creator: "Bo", duration: 1000 },
        ],
      }), { status: 200 });
    }
    return prevFetch(url, init);
  };
  try {
    const t = await token();
    const env = baseEnv();
    const found = await (await call("/music", { op: "search", term: "sunrise" }, t, env)).json();
    assert.deepEqual(found.tracks, [{ id: ID1, title: "Sunrise", artist: "Ann", seconds: 143, bpm: 0, cover: "https://api.openverse.org/v1/audio/x/thumb/" }]);
    assert.equal(found.hasMore, true);
    assert.equal(found.nextOffset, 30);
    const q = seen[0].url.searchParams;
    assert.equal(q.get("q"), "sunrise");
    assert.equal(q.get("category"), "music");
    assert.ok(!q.get("license").includes("nd"), "No-Derivatives licences are never asked for");
    assert.equal(seen[0].auth, undefined);
    // second page, and the last page has no more
    await call("/music", { op: "search", term: "sunrise", offset: 60 }, t, env);
    assert.equal(seen.at(-1).url.searchParams.get("page"), "3");
    const last = await (await call("/music", { op: "search", term: "sunrise", offset: 60 }, t, env)).json();
    assert.equal(last.hasMore, false);
    // nothing typed: a default word
    await call("/music", { op: "search", term: "" }, t, env);
    assert.equal(seen.at(-1).url.searchParams.get("q"), "chill");
    // the same search is not asked twice
    const before = seen.length;
    await call("/music", { op: "search", term: "sunrise" }, t, env);
    assert.equal(seen.length, before);
    // stream link
    const link = await (await call("/music", { op: "url", id: ID1 }, t, env)).json();
    assert.ok(link.url.startsWith("https://prod-1.storage.jamendo.com/"));
    assert.equal((await call("/music", { op: "url", id: ID2 }, t, env)).status, 404);
    // bad id, no login
    assert.equal((await call("/music", { op: "url", id: "../x" }, t, env)).status, 400);
    assert.equal((await call("/music", { op: "search" }, null, env)).status, 401);
  } finally {
    globalThis.fetch = prevFetch;
  }
});

test("music: a busy Openverse gives a friendly message, a registered key is used", async () => {
  const prevFetch = globalThis.fetch;
  let busy = true;
  const auths = [];
  globalThis.fetch = async (url, init) => {
    const u = String(url);
    if (u.includes("securetoken@system.gserviceaccount.com")) return new Response(JSON.stringify({ keys: [jwk] }), { status: 200 });
    if (u.endsWith("/auth_tokens/token/")) return new Response(JSON.stringify({ access_token: "TOK", expires_in: 36000 }), { status: 200 });
    if (u.startsWith("https://api.openverse.org/v1/audio/")) {
      auths.push(init.headers.authorization);
      if (busy) return new Response(JSON.stringify({ detail: "Request was throttled." }), { status: 429 });
      return new Response(JSON.stringify({ page_count: 1, results: [] }), { status: 200 });
    }
    return prevFetch(url, init);
  };
  const quiet = console.error;
  console.error = () => {};
  try {
    const t = await token();
    const env = { ...baseEnv(), OPENVERSE_CLIENT_ID: "cid", OPENVERSE_CLIENT_SECRET: "sec" };
    const bad = await call("/music", { op: "search", term: "busyword" }, t, env);
    assert.equal(bad.status, 502);
    assert.ok(((await bad.json()).detail || "").includes("busy"));
    busy = false;
    const ok = await call("/music", { op: "search", term: "freeword" }, t, env);
    assert.equal(ok.status, 200);
    assert.deepEqual(auths, ["Bearer TOK", "Bearer TOK"]);
  } finally {
    globalThis.fetch = prevFetch;
    console.error = quiet;
  }
});
