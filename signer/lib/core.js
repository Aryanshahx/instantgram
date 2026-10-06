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
//   POST /api/music    {op:"search", term, offset, limit}             -> Epidemic Sound tracks
//   POST /api/music    {op:"url", id}                                 -> short-lived mp3 link
//   GET  /api/health
//
// Settings (Vercel environment variables):
//   FIREBASE_PROJECT_ID, TIGRIS_BUCKET, TIGRIS_ACCESS_KEY_ID, TIGRIS_SECRET_ACCESS_KEY
//   (optional) TIGRIS_ENDPOINT, default t3.storage.dev
//   (optional, for music) EPIDEMIC_API_KEY  - the Epidemic Sound key stays here, never in the app

const MB = 1024 * 1024;
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
  method, host, path, region, service, accessKeyId, secret, expires, date,
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
  const link = (method, key, expires = 300) =>
    presign({
      method, host, path: `/${key}`, region: "auto", service: "s3",
      accessKeyId: env.TIGRIS_ACCESS_KEY_ID, secret: env.TIGRIS_SECRET_ACCESS_KEY,
      expires, date: new Date(),
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
    link,
  };
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

// ------------------------------------------------------- Epidemic Sound (music)
const EPIDEMIC_BASE = "https://partner-content-api.epidemicsound.com";

async function epidemic(env, uid, path, withUser = true) {
  const headers = {
    authorization: `Bearer ${env.EPIDEMIC_API_KEY}`,
    accept: "application/json",
  };
  if (withUser && uid) headers["x-partner-user-id"] = uid;
  return fetch(EPIDEMIC_BASE + path, { headers });
}

/**
 * Asks Epidemic Sound. A 400 means "something in the request is not accepted", so the
 * request is tried again in plainer forms (fewer parameters, then without the end-user header)
 * before giving up. Returns the first answer that is not a 400, or the last 400.
 */
export async function epidemicTry(env, uid, paths) {
  let last = null;
  for (const path of paths) {
    for (const withUser of [true, false]) {
      const res = await epidemic(env, uid, path, withUser);
      if (res.status !== 400) return res;
      last = res;
      console.error(`epidemic 400 for ${path} (user header ${withUser}): ${await reason(res)}`);
    }
  }
  return last;
}

/** What Epidemic Sound wrote in its error answer (a short text), or "". */
export async function reason(res) {
  try {
    const text = (await res.clone().text()).trim();
    if (!text) return "";
    try {
      const j = JSON.parse(text);
      const extra = Array.isArray(j.errors)
        ? j.errors.map((e) => `${e.key}: ${(e.messages || []).join(" ")}`).join("; ")
        : "";
      return [j.message, extra].filter(Boolean).join(" - ").slice(0, 200);
    } catch {
      return text.slice(0, 200);
    }
  } catch {
    return "";
  }
}

async function epidemicFail(res) {
  const why = await reason(res);
  return fail(502, `Epidemic Sound answered ${res.status}${why ? `: ${why}` : "."}`);
}

/** Keeps only what the app shows. */
export function slimTrack(t) {
  const artists = [...(t.mainArtists || []), ...(t.featuredArtists || [])].filter(Boolean);
  const img = t.images || {};
  return {
    id: String(t.id),
    title: String(t.title || ""),
    artist: artists.slice(0, 2).join(", "),
    seconds: Number(t.length) || 0,
    bpm: Number(t.bpm) || 0,
    cover: img.XS || img.S || img.default || "",
    vocals: t.hasVocals === true,
  };
}

async function handleMusic(request, env, uid) {
  if (!env.EPIDEMIC_API_KEY) return fail(503, "Audio search is not set up yet (EPIDEMIC_API_KEY is missing).");
  const body = await readJson(request);
  if (body.op === "search") {
    const term = String(body.term || "").slice(0, 80);
    const limit = Math.min(Math.max(parseInt(body.limit, 10) || 30, 1), 60);
    const offset = Math.max(parseInt(body.offset, 10) || 0, 0);
    // Epidemic Sound answers 400 to a search without a term: use a default one
    const word = term.trim() || "popular";
    const full = new URLSearchParams({ term: word, limit: String(limit), offset: String(offset) });
    const plain = new URLSearchParams({ term: word });
    const res = await epidemicTry(env, uid, [`/v0/tracks/search?${full}`, `/v0/tracks/search?${plain}`]);
    if (res.status === 401 || res.status === 403) return fail(502, "Epidemic Sound refused the key. Check EPIDEMIC_API_KEY and your partner access.");
    if (!res.ok) return epidemicFail(res);
    const data = await res.json();
    const tracks = (data.tracks || []).map(slimTrack);
    return json({ tracks, hasMore: Boolean(data.links && data.links.next) });
  }
  if (body.op === "url") {
    const id = String(body.id || "");
    if (!/^[A-Za-z0-9_-]{4,64}$/.test(id)) return fail(400, "Bad track id.");
    const base = `/v0/tracks/${encodeURIComponent(id)}/download`;
    const res = await epidemicTry(env, uid, [`${base}?format=mp3&quality=normal`, `${base}?format=mp3`, base]);
    if (res.status === 401 || res.status === 403) return fail(502, "Epidemic Sound refused this download (check your partner access).");
    if (!res.ok) return epidemicFail(res);
    const data = await res.json();
    if (!data.url) return fail(502, "Epidemic Sound sent no link.");
    return json({ url: data.url, expires: data.expires || null });
  }
  return fail(400, "Unknown music request.");
}

const ROUTES = { sign: handleSign, confirm: handleConfirm, delete: handleDelete, music: handleMusic };

/** One entry point for every function in api/. `store` is only replaced in tests. */
export async function handle(request, env, route, store = null) {
  if (route === "health") {
    return request.method === "GET" ? json({ ok: true, ready: configured(env), music: Boolean(env.EPIDEMIC_API_KEY) }) : fail(404, "Not found");
  }
  const fn = ROUTES[route];
  if (!fn || request.method !== "POST") return fail(404, "Not found");
  let uid;
  try {
    uid = await authenticate(request, env);
  } catch (e) {
    return fail(401, "Please log in again.");
  }
  if (route !== "music" && !store && !configured(env)) return fail(500, "The media service is not fully set up (missing settings).");
  try {
    return await fn(request, env, uid, store || s3Store(env));
  } catch (e) {
    console.error("media signer error", e && e.stack ? e.stack : e);
    return fail(500, "The media service had a problem. Try again.");
  }
}
