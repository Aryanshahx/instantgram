// Instantgram media signer (runs on Vercel, stores files in Tigris).
//
// The app never holds storage keys. It asks this service for a short-lived upload link (after
// proving who it is with its Firebase login), uploads straight to the Tigris bucket, then asks
// the service to confirm the file. Viewing needs no service: files are read from the public
// bucket address.
//
//   POST /api/sign     {kind:"image"|"video", ext:"jpg", thumb:true}  -> upload links
//   POST /api/confirm  {key}                                          -> checks size + file type
//   POST /api/delete   {keys:[...]}                                   -> removes your own files
//   POST /api/notify   {kind:"message"|"call"|"activity", ...}      -> push to the other phone (lib/push.js)
//   POST /api/music    {op:"search", term, offset, limit}             -> Epidemic Sound tracks
//   POST /api/music    {op:"url", id}                                 -> short-lived mp3 link
//   POST /api/admin    {op:"check"|"wipe"|panel ops}  header x-admin-key -> developer only (lib/admin.js)
//   GET  /admin                                                       -> the admin panel page (lib/panel.js)
//   GET  /api/health
//
// Settings (Vercel environment variables):
//   FIREBASE_PROJECT_ID, TIGRIS_BUCKET, TIGRIS_ACCESS_KEY_ID, TIGRIS_SECRET_ACCESS_KEY
//   (optional) TIGRIS_ENDPOINT, default t3.storage.dev
//   (optional, for music) OPENVERSE_CLIENT_ID and OPENVERSE_CLIENT_SECRET - raise the music search limit
//   (optional, for deleting accounts) ADMIN_KEY - a long random secret only the developer has
//   (optional, for push notifications) FIREBASE_SERVICE_ACCOUNT - see lib/push.js

const MB = 1024 * 1024;
import { notify, serviceAccount } from "./push.js";
import { runPanelOp, restDb, restAuth, fcmSender, AdminError, PANEL_OPS } from "./admin.js";
export const LIMITS = { image: 30 * MB, video: 300 * MB, thumb: 2 * MB };
const TYPES = {
  jpg: "image/jpeg", jpeg: "image/jpeg", png: "image/png", webp: "image/webp", gif: "image/gif",
  mp4: "video/mp4", m4v: "video/mp4", mov: "video/quicktime", webm: "video/webm",
};
const KINDS = {
  image: ["jpg", "jpeg", "png", "webp", "gif"],
  video: ["mp4", "m4v", "mov", "webm"],
};
const SIGN_SECONDS = 3600;

// ------------------------------------------------------------------ helpers
const enc = new TextEncoder();
const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
const b64urlToBytes = (s) => {
  s = s.replace(/-/g, "+").replace(/_/g, "/");
  while (s.length % 4) s += "=";
  return Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
};
const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json" } });
const fail = (status, detail) => json({ detail }, status);

// RFC 3986 percent-encoding (what AWS Signature V4 requires)
const enc3986 = (s) =>
  encodeURIComponent(s).replace(/[!'()*]/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase());

async function sha256Hex(data) {
  return hex(await crypto.subtle.digest("SHA-256", typeof data === "string" ? enc.encode(data) : data));
}
async function hmac(key, data) {
  const k = await crypto.subtle.importKey(
    "raw", typeof key === "string" ? enc.encode(key) : key,
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, enc.encode(data)));
}

// ------------------------------------------------- AWS Signature V4, query form
/** Returns a pre-signed URL. Only the Host header is signed; the body is not hashed. */
export async function presign({
  method, host, path, region, service, accessKeyId, secret, expires, date, params = {},
}) {
  const stamp = date.toISOString().replace(/[:-]|\.\d{3}/g, ""); // 20130524T000000Z
  const day = stamp.slice(0, 8);
  const scope = `${day}/${region}/${service}/aws4_request`;
  const canonicalUri = path.split("/").map(enc3986).join("/");
  const query = {
    "X-Amz-Algorithm": "AWS4-HMAC-SHA256",
    "X-Amz-Credential": `${accessKeyId}/${scope}`,
    "X-Amz-Date": stamp,
    "X-Amz-Expires": String(expires),
    "X-Amz-SignedHeaders": "host",
    ...params,
  };
  const canonicalQuery = Object.keys(query).sort()
    .map((k) => `${enc3986(k)}=${enc3986(query[k])}`).join("&");
  const canonicalRequest =
    `${method}\n${canonicalUri}\n${canonicalQuery}\nhost:${host}\n\nhost\nUNSIGNED-PAYLOAD`;
  const stringToSign = `AWS4-HMAC-SHA256\n${stamp}\n${scope}\n${await sha256Hex(canonicalRequest)}`;
  let k = await hmac("AWS4" + secret, day);
  k = await hmac(k, region);
  k = await hmac(k, service);
  k = await hmac(k, "aws4_request");
  const signature = hex(await hmac(k, stringToSign));
  return `https://${host}${canonicalUri}?${canonicalQuery}&X-Amz-Signature=${signature}`;
}

// ------------------------------------------------------- Firebase login check
const JWKS_URL =
  "https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com";
let jwks = { keys: null, exp: 0 };

async function getJwks() {
  if (jwks.keys && Date.now() < jwks.exp) return jwks.keys;
  const res = await fetch(JWKS_URL);
  if (!res.ok) throw new Error("could not load Google keys");
  const body = await res.json();
  jwks = { keys: body.keys, exp: Date.now() + 3600 * 1000 };
  return jwks.keys;
}

export class AuthError extends Error {}

/** Verifies a Firebase ID token and returns the user's uid. */
export async function verifyFirebaseToken(token, project, nowMs = Date.now()) {
  try {
    const parts = (token || "").split(".");
    if (parts.length !== 3) throw new AuthError("malformed token");
    const header = JSON.parse(new TextDecoder().decode(b64urlToBytes(parts[0])));
    if (header.alg !== "RS256" || !header.kid) throw new AuthError("bad header");
    const jwk = (await getJwks()).find((k) => k.kid === header.kid);
    if (!jwk) throw new AuthError("unknown key");
    const key = await crypto.subtle.importKey(
      "jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"],
    );
    const ok = await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5", key, b64urlToBytes(parts[2]), enc.encode(parts[0] + "." + parts[1]),
    );
    if (!ok) throw new AuthError("bad signature");
    const c = JSON.parse(new TextDecoder().decode(b64urlToBytes(parts[1])));
    const now = Math.floor(nowMs / 1000);
    if (c.aud !== project) throw new AuthError("wrong audience");
    if (c.iss !== `https://securetoken.google.com/${project}`) throw new AuthError("wrong issuer");
    if (typeof c.exp !== "number" || c.exp < now - 30) throw new AuthError("expired");
    if (typeof c.iat !== "number" || c.iat > now + 30) throw new AuthError("issued in the future");
    if (typeof c.sub !== "string" || !c.sub) throw new AuthError("no subject");
    return c.sub;
  } catch (e) {
    if (e instanceof AuthError) throw e;
    throw new AuthError(String(e && e.message ? e.message : e));
  }
}

async function authenticate(request, env) {
  const h = request.headers.get("authorization") || "";
  if (!h.toLowerCase().startsWith("bearer ")) throw new AuthError("missing token");
  return verifyFirebaseToken(h.slice(7).trim(), env.FIREBASE_PROJECT_ID);
}

// ------------------------------------------------------------ file checking
export function sniffOk(head, kind) {
  const b = head;
  const at = (i, s) => [...s].every((ch, n) => b[i + n] === ch.charCodeAt(0));
  if (kind === "image" || kind === "thumb") {
    return (
      (b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) ||
      (b[0] === 0x89 && at(1, "PNG")) ||
      at(0, "GIF8") ||
      (at(0, "RIFF") && at(8, "WEBP"))
    );
  }
  // video: mp4 / mov ("ftyp" at byte 4) or webm / mkv (EBML header)
  return at(4, "ftyp") || (b[0] === 0x1a && b[1] === 0x45 && b[2] === 0xdf && b[3] === 0xa3);
}

function randomId() {
  const b = crypto.getRandomValues(new Uint8Array(16));
  return hex(b);
}

/** `video/<uid>/<id>.mp4` -> {kind, uid}; null when the key is not one of ours. */
export function parseKey(key) {
  const m = /^(image|video|thumb)\/([A-Za-z0-9]{1,128})\/([a-f0-9]{32})\.([a-z0-9]{2,4})$/.exec(key || "");
  if (!m) return null;
  return { kind: m[1], uid: m[2], ext: m[4] };
}

async function readJson(request) {
  try {
    const data = await request.json();
    return data && typeof data === "object" ? data : {};
  } catch {
    return {};
  }
}

// ------------------------------------------------------- Tigris (S3 API) access
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Talks to the bucket with short-lived signed links made from the secret keys. */
export function s3Store(env) {
  const host = `${env.TIGRIS_BUCKET}.${env.TIGRIS_ENDPOINT || "t3.storage.dev"}`;
  const link = (method, key, expires = 300, params = {}) =>
    presign({
      method, host, path: `/${key}`, region: "auto", service: "s3",
      accessKeyId: env.TIGRIS_ACCESS_KEY_ID, secret: env.TIGRIS_SECRET_ACCESS_KEY,
      expires, date: new Date(), params,
    });
  return {
    /** {size} or null when the object is not there (after a few short retries). */
    async head(key) {
      for (let i = 0; i < 4; i++) {
        const res = await fetch(await link("HEAD", key), { method: "HEAD" });
        if (res.status === 200) return { size: Number(res.headers.get("content-length") || 0) };
        if (res.status !== 404) throw new Error(`storage HEAD answered ${res.status}`);
        await sleep(400);
      }
      return null;
    },
    /** First `length` bytes of the object (never downloads the rest). */
    async get(key, { range: { offset, length } }) {
      const res = await fetch(await link("GET", key), {
        headers: { range: `bytes=${offset}-${offset + length - 1}` },
      });
      if (res.status === 404) return null;
      if (res.status !== 200 && res.status !== 206) throw new Error(`storage GET answered ${res.status}`);
      const out = new Uint8Array(length);
      let got = 0;
      const reader = res.body.getReader();
      while (got < length) {
        const { done, value } = await reader.read();
        if (done) break;
        const take = Math.min(value.length, length - got);
        out.set(value.subarray(0, take), got);
        got += take;
      }
      await reader.cancel().catch(() => {});
      const bytes = out.slice(0, got);
      return { arrayBuffer: async () => bytes.buffer };
    },
    async delete(key) {
      const res = await fetch(await link("DELETE", key), { method: "DELETE" });
      if (![200, 204, 404].includes(res.status)) throw new Error(`storage DELETE answered ${res.status}`);
    },
    /** Up to 1000 keys that start with `prefix` -> {keys, next} (next = "" when done). */
    async list(prefix, token = "") {
      const params = { "list-type": "2", prefix, "max-keys": "1000" };
      if (token) params["continuation-token"] = token;
      const res = await fetch(await link("GET", "", 300, params));
      if (res.status !== 200) throw new Error(`storage LIST answered ${res.status}`);
      return parseList(await res.text());
    },
    link,
  };
}

/** The keys and the continuation token of a ListObjectsV2 answer. */
export function parseList(xml) {
  const unescape = (t) => t.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'").replace(/&amp;/g, "&");
  const keys = [...xml.matchAll(/<Key>([^<]*)<\/Key>/g)].map((m) => unescape(m[1]));
  const truncated = /<IsTruncated>true<\/IsTruncated>/.test(xml);
  const next = truncated ? (/<NextContinuationToken>([^<]*)<\/NextContinuationToken>/.exec(xml) || [])[1] || "" : "";
  return { keys, next: unescape(next) };
}

const configured = (env) =>
  Boolean(env.FIREBASE_PROJECT_ID && env.TIGRIS_BUCKET && env.TIGRIS_ACCESS_KEY_ID && env.TIGRIS_SECRET_ACCESS_KEY);

// ------------------------------------------------------------------- routes
async function handleSign(request, env, uid, store) {
  const body = await readJson(request);
  if (!/^[A-Za-z0-9]{1,128}$/.test(uid)) return fail(403, "This account cannot upload.");
  const kind = body.kind;
  const ext = String(body.ext || "").toLowerCase().replace(/^\./, "");
  if (!KINDS[kind]) return fail(400, "kind must be image or video.");
  if (!KINDS[kind].includes(ext)) return fail(400, "This file type is not supported.");
  const key = `${kind}/${uid}/${randomId()}.${ext}`;
  const out = { key, url: await store.link("PUT", key, SIGN_SECONDS), type: TYPES[ext], expiresIn: SIGN_SECONDS };
  if (kind === "video" && body.thumb === true) {
    out.thumbKey = `thumb/${uid}/${randomId()}.jpg`;
    out.thumbUrl = await store.link("PUT", out.thumbKey, SIGN_SECONDS);
    out.thumbType = "image/jpeg";
  }
  return json(out);
}

async function handleConfirm(request, env, uid, store) {
  const body = await readJson(request);
  const parsed = parseKey(body.key);
  if (!parsed) return fail(400, "Bad file key.");
  if (parsed.uid !== uid) return fail(403, "Not your file.");
  const head = await store.head(body.key);
  if (!head) return fail(404, "The upload did not arrive. Try again.");
  if (head.size === 0 || head.size > LIMITS[parsed.kind]) {
    await store.delete(body.key);
    return fail(413, "File is too large.");
  }
  const part = await store.get(body.key, { range: { offset: 0, length: 16 } });
  const bytes = part ? new Uint8Array(await part.arrayBuffer()) : new Uint8Array(0);
  if (!sniffOk(bytes, parsed.kind)) {
    await store.delete(body.key);
    return fail(400, "Unsupported file type.");
  }
  return json({ ok: true, key: body.key, size: head.size });
}

async function handleDelete(request, env, uid, store) {
  const body = await readJson(request);
  const keys = Array.isArray(body.keys) ? body.keys.slice(0, 4) : [];
  const mine = [];
  for (const k of keys) {
    const p = parseKey(k);
    if (!p) return fail(400, "Bad file key.");
    if (p.uid !== uid) return fail(403, "Not your file.");
    mine.push(k);
  }
  for (const k of mine) await store.delete(k);
  return json({ ok: true, deleted: mine.length });
}

// ------------------------------------------------------------- developer only
// Deleting an account: the developer's tool (tools/delete_user.sh) removes everything the
// user stored in Firestore, then asks here to remove their files. Only a request carrying
// ADMIN_KEY gets in; without ADMIN_KEY set this route is switched off.

/** Same length and same characters, compared without stopping at the first difference. */
export function sameSecret(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

const UID = /^[A-Za-z0-9]{1,128}$/;
// Each call removes at most this many files, so it ends well inside Vercel's time limit;
// the tool calls again while `more` is true.
const WIPE_BATCH = 150;

async function handleAdmin(request, env, store, deps = null) {
  const key = env.ADMIN_KEY || "";
  if (key.length < 32) return fail(404, "Not found");
  if (!sameSecret(request.headers.get("x-admin-key") || "", key)) return fail(403, "Wrong admin key.");
  const body = await readJson(request);
  if (body.op === "check") {
    const media = (env.MEDIA_PUBLIC_URL || `https://${env.TIGRIS_BUCKET}.t3.tigrisfiles.io`).replace(/\/+$/, "");
    return json({ ok: true, panel: Boolean(serviceAccount(env)), media, bucket: env.TIGRIS_BUCKET || "" });
  }
  if (body.op === "wipe") {
    const uid = String(body.uid || "");
    if (!UID.test(uid)) return fail(400, "Bad user id.");
    return json(await wipeFiles(store, uid));
  }
  if (!Object.hasOwn(PANEL_OPS, body.op || "")) return fail(400, "Unknown op.");
  // the admin panel: Firestore and sign-in through the service account
  let ctx = deps && deps.panel;
  if (!ctx) {
    const sa = serviceAccount(env);
    if (!sa) return fail(503, "Set FIREBASE_SERVICE_ACCOUNT in Vercel first (the same key push notifications use).");
    const project = env.FIREBASE_PROJECT_ID || sa.project;
    ctx = { db: restDb(sa, project), auth: restAuth(sa, project), push: fcmSender(sa, project) };
  }
  try {
    return json(await runPanelOp(body, { store, wipeFiles: (uid) => wipeFiles(store, uid), ...ctx }));
  } catch (e) {
    if (e instanceof AdminError) return fail(e.status, e.message);
    throw e;
  }
}

/** Removes up to WIPE_BATCH files of one user; {deleted, more}. */
async function wipeFiles(store, uid) {
  // First the whole list, then the deletes: deleting while paging could skip files.
  const keys = [];
  for (const kind of ["image", "video", "thumb"]) {
    let token = "";
    do {
      const page = await store.list(`${kind}/${uid}/`, token);
      for (const k of page.keys) {
        const p = parseKey(k);
        if (p && p.uid === uid) keys.push(k); // never anything outside this user's folders
      }
      token = page.next;
    } while (token);
  }
  const now = keys.slice(0, WIPE_BATCH);
  for (const k of now) await store.delete(k);
  return { ok: true, deleted: now.length, more: keys.length > now.length };
}

// ------------------------------------------------------- Openverse (free music)
// Openverse (openverse.org, run by WordPress) searches Creative Commons audio. Its music is
// the Jamendo catalogue. No sign-up is needed; with OPENVERSE_CLIENT_ID and
// OPENVERSE_CLIENT_SECRET (optional) the daily limit is much higher.
const OPENVERSE = "https://api.openverse.org/v1";
// Licences that allow music under a video: no "No Derivatives" ones.
const OK_LICENSES = "by,by-sa,by-nc,by-nc-sa,cc0,pdm";
const DEFAULT_TERM = "chill";
const PAGE = 30;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

let tokenCache = { value: "", until: 0 };
const answers = new Map();

/** Remembers answers for ten minutes, so the same search is not asked twice. */
function remember(key, value) {
  if (answers.size > 300) answers.delete(answers.keys().next().value);
  answers.set(key, { value, until: Date.now() + 10 * 60 * 1000 });
}
function recall(key) {
  const hit = answers.get(key);
  if (!hit) return null;
  if (hit.until < Date.now()) {
    answers.delete(key);
    return null;
  }
  return hit.value;
}

async function openverseHeaders(env) {
  const headers = { accept: "application/json" };
  if (env.OPENVERSE_CLIENT_ID && env.OPENVERSE_CLIENT_SECRET) {
    if (!tokenCache.value || tokenCache.until < Date.now() + 60000) {
      const res = await fetch(`${OPENVERSE}/auth_tokens/token/`, {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          grant_type: "client_credentials",
          client_id: env.OPENVERSE_CLIENT_ID,
          client_secret: env.OPENVERSE_CLIENT_SECRET,
        }),
      });
      if (res.ok) {
        const j = await res.json();
        tokenCache = { value: String(j.access_token || ""), until: Date.now() + (Number(j.expires_in) || 3600) * 1000 };
      } else {
        console.error(`openverse token ${res.status}`);
      }
    }
    if (tokenCache.value) headers.authorization = `Bearer ${tokenCache.value}`;
  }
  return headers;
}

/** Asks Openverse; returns {data} or {error} (a short text for the user). */
async function openverse(env, path) {
  const res = await fetch(OPENVERSE + path, { headers: await openverseHeaders(env) });
  if (res.status === 429) {
    console.error("openverse 429 (limit reached)");
    return { error: "Music search is busy right now. Try again in a minute." };
  }
  if (!res.ok) {
    console.error(`openverse ${res.status} for ${path.split("?")[0]}`);
    return { error: `The music service answered ${res.status}. Try again later.` };
  }
  try {
    return { data: await res.json() };
  } catch {
    return { error: "The music service sent an unreadable answer." };
  }
}

/** Keeps only what the app shows. */
export function slimTrack(t) {
  return {
    id: String(t.id),
    title: String(t.title || "").slice(0, 120),
    artist: String(t.creator || "").slice(0, 80),
    seconds: Math.round((Number(t.duration) || 0) / 1000),
    bpm: 0,
    cover: typeof t.thumbnail === "string" && t.thumbnail.startsWith("https://") ? t.thumbnail : "",
  };
}

async function handleMusic(request, env, uid) {
  const body = await readJson(request);
  if (body.op === "search") {
    const term = String(body.term || "").trim().slice(0, 80) || DEFAULT_TERM;
    const offset = Math.max(parseInt(body.offset, 10) || 0, 0);
    const page = Math.floor(offset / PAGE) + 1;
    const q = new URLSearchParams({
      q: term,
      category: "music",
      license: OK_LICENSES,
      page: String(page),
      page_size: String(PAGE),
      filter_dead: "true",
    });
    const key = `s|${q}`;
    const cached = recall(key);
    if (cached) return json(cached);
    const r = await openverse(env, `/audio/?${q}`);
    if (r.error) return fail(502, r.error);
    const results = Array.isArray(r.data.results) ? r.data.results : [];
    const out = {
      tracks: results.filter((t) => t && UUID.test(String(t.id))).map(slimTrack),
      hasMore: page < (Number(r.data.page_count) || 0),
      nextOffset: page * PAGE,
    };
    remember(key, out);
    return json(out);
  }
  if (body.op === "url") {
    const id = String(body.id || "");
    if (!UUID.test(id)) return fail(400, "Bad track id.");
    const key = `u|${id}`;
    const cached = recall(key);
    if (cached) return json(cached);
    const r = await openverse(env, `/audio/${id}/`);
    if (r.error) return fail(502, r.error);
    const url = r.data && r.data.url;
    if (typeof url !== "string" || !url.startsWith("https://")) return fail(404, "That track is not available any more.");
    const out = { url, expires: null };
    remember(key, out);
    return json(out);
  }
  return fail(400, "Unknown music request.");
}

async function handleNotify(request, env, uid, deps) {
  let body;
  try {
    body = await request.json();
  } catch {
    return fail(400, "Send JSON.");
  }
  const r = await notify(body, env, uid, deps || {});
  return json(r.body, r.status);
}

const ROUTES = { sign: handleSign, confirm: handleConfirm, delete: handleDelete, music: handleMusic, notify: handleNotify };

/** One entry point for every function in api/. `store` is only replaced in tests. */
export async function handle(request, env, route, store = null, deps = null) {
  if (route === "health") {
    return request.method === "GET" ? json({ ok: true, ready: configured(env), push: Boolean(serviceAccount(env)), music: true, musicKey: Boolean(env.OPENVERSE_CLIENT_ID && env.OPENVERSE_CLIENT_SECRET) }) : fail(404, "Not found");
  }
  if (route === "admin") {
    if (request.method !== "POST") return fail(404, "Not found");
    if (!store && !configured(env)) return fail(500, "The media service is not fully set up (missing settings).");
    try {
      return await handleAdmin(request, env, store || s3Store(env), deps);
    } catch (e) {
      console.error("media signer admin error", e && e.stack ? e.stack : e);
      return fail(500, "The media service had a problem. Try again.");
    }
  }
  const fn = ROUTES[route];
  if (!fn || request.method !== "POST") return fail(404, "Not found");
  let uid;
  try {
    uid = await authenticate(request, env);
  } catch (e) {
    return fail(401, "Please log in again.");
  }
  if (route === "notify") {
    try {
      return await fn(request, env, uid, store);
    } catch (e) {
      console.error("push error", e && e.stack ? e.stack : e);
      return fail(502, "Could not send the notification.");
    }
  }
  if (route !== "music" && !store && !configured(env)) return fail(500, "The media service is not fully set up (missing settings).");
  try {
    return await fn(request, env, uid, store || s3Store(env));
  } catch (e) {
    console.error("media signer error", e && e.stack ? e.stack : e);
    return fail(500, "The media service had a problem. Try again.");
  }
}
