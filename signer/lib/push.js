// Push notifications (Firebase Cloud Messaging), sent by the media signer.
//
// The app tells the signer that something happened; the signer checks that it really
// happened (it reads the message, call or activity line from Firestore with the service
// account), writes the text itself, and sends it to the other person's phones. So nobody
// can push made-up text to anybody.
//
//   POST /api/notify {kind:"message", chatId, messageId}
//   POST /api/notify {kind:"call", callId}
//   POST /api/notify {kind:"activity", to, itemId}
//   POST /api/notify {kind:"storyView", storyId, col?:"p"}   (first view; only people the author picked)
//
// Phones: pushTokens/{uid} = {tokens:[...], off:false}
// Setting (Vercel): FIREBASE_SERVICE_ACCOUNT = the service-account JSON (plain or base64)

const enc = new TextEncoder();
const b64u = (bytes) =>
  btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const b64uText = (s) => b64u(enc.encode(s));

/** The service account from the environment, or null when push is not set up. */
export function serviceAccount(env) {
  const raw = (env.FIREBASE_SERVICE_ACCOUNT || "").trim();
  if (!raw) return null;
  let text = raw;
  if (!raw.startsWith("{")) {
    try { text = atob(raw); } catch { return null; }
  }
  try {
    const sa = JSON.parse(text);
    if (!sa.client_email || !sa.private_key) return null;
    return { email: sa.client_email, key: sa.private_key, project: sa.project_id || "" };
  } catch {
    return null;
  }
}

async function importKey(pem) {
  const body = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
}

// identitytoolkit + cloud-platform: the admin panel bans and deletes sign-in accounts
const SCOPES = "https://www.googleapis.com/auth/firebase.messaging https://www.googleapis.com/auth/datastore https://www.googleapis.com/auth/identitytoolkit https://www.googleapis.com/auth/cloud-platform";
let tokenCache = null; // {email, value, until}

/** An OAuth access token for the service account (kept until shortly before it expires). */
export async function googleToken(sa, fetchFn = fetch, nowMs = Date.now()) {
  if (tokenCache && tokenCache.email === sa.email && tokenCache.until > nowMs + 60_000) return tokenCache.value;
  const iat = Math.floor(nowMs / 1000);
  const head = b64uText(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = b64uText(JSON.stringify({
    iss: sa.email, scope: SCOPES, aud: "https://oauth2.googleapis.com/token", iat, exp: iat + 3600,
  }));
  const key = await importKey(sa.key);
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, enc.encode(`${head}.${claims}`));
  const res = await fetchFn("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: `grant_type=${encodeURIComponent("urn:ietf:params:oauth:grant-type:jwt-bearer")}&assertion=${head}.${claims}.${b64u(sig)}`,
  });
  if (!res.ok) throw new Error(`google token ${res.status}`);
  const j = await res.json();
  tokenCache = { email: sa.email, value: j.access_token, until: nowMs + (j.expires_in || 3600) * 1000 };
  return j.access_token;
}

export function forgetToken() { tokenCache = null; }

// ------------------------------------------------------------- Firestore REST

/** A Firestore REST value -> plain JS. */
export function decodeValue(v) {
  if (!v || typeof v !== "object") return null;
  if ("stringValue" in v) return v.stringValue;
  if ("booleanValue" in v) return v.booleanValue;
  if ("integerValue" in v) return Number(v.integerValue);
  if ("doubleValue" in v) return v.doubleValue;
  if ("timestampValue" in v) return new Date(v.timestampValue);
  if ("nullValue" in v) return null;
  if ("arrayValue" in v) return (v.arrayValue.values || []).map(decodeValue);
  if ("mapValue" in v) return decodeFields(v.mapValue.fields || {});
  return null;
}
/** Plain JS -> a Firestore REST value. */
export function encodeValue(v) {
  if (v === null || v === undefined) return { nullValue: null };
  if (v instanceof Date) return { timestampValue: v.toISOString() };
  if (typeof v === "boolean") return { booleanValue: v };
  if (typeof v === "number") return Number.isInteger(v) ? { integerValue: String(v) } : { doubleValue: v };
  if (typeof v === "string") return { stringValue: v };
  if (Array.isArray(v)) return { arrayValue: { values: v.map(encodeValue) } };
  return { mapValue: { fields: Object.fromEntries(Object.entries(v).map(([k, x]) => [k, encodeValue(x)])) } };
}

export function decodeFields(f) {
  const out = {};
  for (const [k, v] of Object.entries(f || {})) out[k] = decodeValue(v);
  return out;
}

function firestore(sa, project, fetchFn) {
  const base = `https://firestore.googleapis.com/v1/projects/${project}/databases/(default)/documents`;
  const auth = async () => ({ authorization: `Bearer ${await googleToken(sa, fetchFn)}` });
  return {
    async get(path) {
      const res = await fetchFn(`${base}/${path}`, { headers: await auth() });
      if (res.status === 404) return null;
      if (!res.ok) throw new Error(`firestore get ${res.status}`);
      return decodeFields((await res.json()).fields);
    },
    async create(collectionPath, data) {
      const fields = Object.fromEntries(Object.entries(data).map(([k, v]) => [k, encodeValue(v)]));
      const res = await fetchFn(`${base}/${collectionPath}`, {
        method: "POST", headers: { ...(await auth()), "content-type": "application/json" }, body: JSON.stringify({ fields }),
      });
      if (!res.ok) throw new Error(`firestore create ${res.status}`);
    },
    async patch(path, data) {
      const fields = Object.fromEntries(Object.entries(data).map(([k, v]) => [k, encodeValue(v)]));
      const mask = Object.keys(data).map((k) => `updateMask.fieldPaths=${encodeURIComponent(k)}`).join("&");
      const res = await fetchFn(`${base}/${path}?${mask}&currentDocument.exists=true`, {
        method: "PATCH", headers: { ...(await auth()), "content-type": "application/json" }, body: JSON.stringify({ fields }),
      });
      if (!res.ok) throw new Error(`firestore patch ${res.status}`);
    },
    async setTokens(uid, tokens) {
      const body = { fields: { tokens: { arrayValue: { values: tokens.map((t) => ({ stringValue: t })) } } } };
      await fetchFn(`${base}/pushTokens/${uid}?updateMask.fieldPaths=tokens`, {
        method: "PATCH", headers: { ...(await auth()), "content-type": "application/json" }, body: JSON.stringify(body),
      });
    },
  };
}

// ------------------------------------------------------------------ the texts

const SAFE_ID = /^[A-Za-z0-9_-]{1,128}$/;
const RECENT_MS = 10 * 60 * 1000; // only fresh events are pushed (no replays)
const cut = (s, n) => (s.length > n ? s.slice(0, n - 1) + "\u2026" : s);

/** What the notification of a chat message says. Null = no notification for it. */
export function messageBody(m) {
  if (!m || m.deleted) return null;
  if (m.vanish) return "Sent a disappearing message";
  switch (m.type || "text") {
    case "text": return cut(String(m.text || ""), 140) || null;
    case "image": return "\u{1F4F7} Sent a photo";
    case "gif": return "Sent a GIF";
    case "voice": return "\u{1F3A4} Voice message";
    case "location": return "\u{1F4CD} Shared a location";
    case "post": return m.postIsClip ? "Shared a clip" : "Shared a post";
    default: return null; // call lines and notes in the chat are not pushed
  }
}

/** The line of an activity notification ("aryan liked your post"). */
export function activityBody(item, what = "post") {
  const who = item.actorName || "Someone";
  const text = cut(String(item.text || ""), 100);
  switch (item.type) {
    case "like": return `${who} liked your ${what}`;
    case "super": return `${who} sent your ${what} a super heart 💖`;
    case "comment": return text ? `${who} commented on your ${what}: ${text}` : `${who} commented on your ${what}`;
    case "reply": return text ? `${who} replied: ${text}` : `${who} replied to your comment`;
    case "mention": return `${who} mentioned you`;
    case "follow": return `${who} started following you`;
    case "story_view": return `${who} viewed your moment`;
    case "story_like": return `${who} liked your moment`;
    case "story_super": return `${who} sent your moment a super heart 💖`;
    default: return `${who} interacted with your ${what}`;
  }
}

const UPLOADS = {
  post: "Your post is live \u2705",
  clip: "Your clip is live \u2705",
  moment: "Your moment is live \u2705",
};

const mutedFor = (v, uid) => (v && typeof v === "object" ? v[uid] === true : v === true);
const fresh = (d, nowMs) => d instanceof Date && nowMs - d.getTime() < RECENT_MS && d.getTime() - nowMs < 60_000;

// ------------------------------------------------------------------- handler

/**
 * Works out who gets what, then sends it. Returns {ok, sent, skipped?}.
 * deps.fetch is replaced in the tests.
 */
export async function notify(body, env, uid, deps = {}) {
  const fetchFn = deps.fetch || fetch;
  const nowMs = deps.now || Date.now();
  const sa = serviceAccount(env);
  if (!sa) return { status: 503, body: { detail: "Push notifications are not set up." } };
  const project = env.FIREBASE_PROJECT_ID || sa.project;
  const db = firestore(sa, project, fetchFn);
  const kind = body && body.kind;

  let to, title, text, data, android = {};
  if (kind === "test") {
    // Settings > Notifications > Send a test: to my own phones, with every step reported
    const reg = await db.get(`pushTokens/${uid}`);
    const tokens = reg && Array.isArray(reg.tokens) ? reg.tokens.filter((t) => typeof t === "string").slice(-5) : [];
    if (!tokens.length) return { status: 200, body: { ok: false, sent: 0, detail: "This account has no phone registered for notifications yet." } };
    let accessToken;
    try {
      accessToken = await googleToken(sa, fetchFn, nowMs);
    } catch (e) {
      return { status: 200, body: { ok: false, sent: 0, detail: `Google sign-in of the signer failed (${e.message}). Check FIREBASE_SERVICE_ACCOUNT in Vercel.` } };
    }
    let sent = 0;
    const errors = [];
    for (const token of tokens) {
      const res = await fetchFn(`https://fcm.googleapis.com/v1/projects/${project}/messages:send`, {
        method: "POST",
        headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
        body: JSON.stringify({ message: {
          token,
          notification: { title: "InstantGram", body: "Notifications work \u{1F389}" },
          data: { type: "test" },
          android: { priority: "HIGH", notification: { channel_id: "activity", icon: "ic_stat_instantgram", color: "#C6FF3D" } },
        } }),
      });
      if (res.ok) { sent++; continue; }
      let why = "";
      try { const j = await res.json(); why = (j && j.error && (j.error.status || j.error.message)) || ""; } catch { /* no body */ }
      errors.push(`${res.status}${why ? " " + why : ""}`);
    }
    const hint = errors.some((e) => e.startsWith("403"))
      ? " Turn on \"Firebase Cloud Messaging API\" in Google Cloud for this project."
      : errors.some((e) => e.startsWith("404") || e.includes("UNREGISTERED"))
        ? " The phone address is old: open the app again so it registers."
        : "";
    return { status: 200, body: { ok: sent > 0, sent, errors, detail: sent > 0 ? `Sent to ${sent} phone(s).` : `Not sent: ${errors.join(", ")}.${hint}` } };
  } else if (kind === "message") {
    const { chatId, messageId } = body;
    if (!SAFE_ID.test(chatId || "") || !SAFE_ID.test(messageId || "")) return bad("chatId and messageId are needed.");
    const chat = await db.get(`chats/${chatId}`);
    if (!chat || !Array.isArray(chat.members) || !chat.members.includes(uid)) return bad("Not your chat.", 403);
    to = chat.members.find((m) => m !== uid);
    const m = await db.get(`chats/${chatId}/messages/${messageId}`);
    if (!m || m.senderId !== uid || !fresh(m.createdAt, nowMs)) return bad("No such message.", 403);
    if (!to || mutedFor(chat.muteMessages, to)) return ok("muted");
    text = messageBody(m);
    if (!text) return ok("nothing to say");
    const me = await db.get(`users/${uid}`);
    title = (me && me.username) || "New message";
    data = { type: "message", from: uid, chatId };
    android = { channel: "messages", tag: `chat_${chatId}` };
  } else if (kind === "call") {
    const { callId } = body;
    if (!SAFE_ID.test(callId || "")) return bad("callId is needed.");
    const call = await db.get(`calls/${callId}`);
    if (!call || call.callerId !== uid || call.status !== "ringing" || !fresh(call.createdAt, nowMs)) {
      return bad("No such call.", 403);
    }
    to = call.calleeId;
    const chatId = [uid, to].sort().join("_");
    const chat = await db.get(`chats/${chatId}`);
    if (chat && mutedFor(chat.muteCalls, to)) return ok("muted");
    const me = await db.get(`users/${uid}`);
    title = (me && me.username) || "InstantGram";
    text = call.video ? "\u{1F4F9} Incoming video call" : "\u{1F4DE} Incoming voice call";
    data = { type: "call", from: uid, callId };
    android = { channel: "calls", tag: `call_${callId}`, ttl: "40s" };
  } else if (kind === "activity") {
    const { to: target, itemId } = body;
    if (!SAFE_ID.test(target || "") || !SAFE_ID.test(itemId || "")) return bad("to and itemId are needed.");
    const item = await db.get(`notifications/${target}/items/${itemId}`);
    if (!item || item.actorId !== uid || !fresh(item.at, nowMs)) return bad("No such activity.", 403);
    to = target;
    title = "InstantGram";
    // a clip is called a clip
    let what = "post";
    if (item.postId && SAFE_ID.test(String(item.postId))) {
      try {
        const p = await db.get(`posts/${item.postId}`);
        if (p && (p.type === "video" || p.type === "photoclip")) what = "clip";
      } catch { /* "post" */ }
    }
    text = activityBody(item, what);
    data = { type: "activity", from: uid, postId: String(item.postId || "") };
    android = { channel: "activity", tag: `act_${item.type}_${item.postId || uid}` };
  } else if (kind === "storyView") {
    const { storyId } = body;
    if (!SAFE_ID.test(storyId || "")) return bad("storyId is needed.");
    const col = body.col === "p" ? "privateStories" : "stories"; // p = for one audience list
    const story = await db.get(`${col}/${storyId}`);
    if (!story || !story.authorId) return bad("No such moment.", 403);
    const viewPath = `${col}/${storyId}/views/${uid}`;
    const view = await db.get(viewPath);
    if (!view || !fresh(view.first, nowMs)) return bad("No such view.", 403);
    if (view.alerted === true) return ok("already");
    to = story.authorId;
    if (to === uid) return ok("nobody");
    const wanted = await db.get(`storyAlerts/${to}`);
    if (!wanted || !Array.isArray(wanted.uids) || !wanted.uids.includes(uid)) return ok("not picked");
    await db.patch(viewPath, { alerted: true }); // once per person and moment
    const me = await db.get(`users/${uid}`);
    const item = {
      type: "story_view", actorId: uid, actorName: (me && me.username) || "",
      actorPhoto: (me && me.photoUrl) || "", postId: "", thumb: "", text: "",
      at: new Date(nowMs), read: false,
    };
    try { await db.create(`notifications/${to}/items`, item); } catch { /* the push still goes */ }
    title = "InstantGram";
    text = activityBody(item);
    data = { type: "activity", from: uid, postId: "" };
    android = { channel: "activity", tag: `sv_${storyId}_${uid}` };
  } else if (kind === "upload") {
    // my own upload is online: only my own phones hear about it
    const what = UPLOADS[body.what] ? body.what : "post";
    to = uid;
    title = "InstantGram";
    text = UPLOADS[what];
    data = { type: "upload", what };
    android = { channel: "activity", tag: `upload_${what}` };
  } else {
    return bad("Unknown kind.");
  }
  if (!to || (to === uid && kind !== "upload")) return ok("nobody");

  // blocked people never reach you
  if (to !== uid && await db.get(`users/${to}/blocked/${uid}`)) return ok("blocked");
  const reg = await db.get(`pushTokens/${to}`);
  const tokens = reg && Array.isArray(reg.tokens) ? reg.tokens.filter((t) => typeof t === "string").slice(-5) : [];
  if (reg && reg.off === true) return ok("off");
  if (!tokens.length) return ok("no phone");

  const accessToken = await googleToken(sa, fetchFn, nowMs);
  let sent = 0;
  const stale = [];
  for (const token of tokens) {
    const message = {
      token,
      notification: { title: cut(title, 60), body: text },
      data,
      android: {
        priority: "HIGH",
        ...(android.ttl ? { ttl: android.ttl } : {}),
        notification: {
          channel_id: android.channel,
          tag: android.tag,
          icon: "ic_stat_instantgram",
          color: "#C6FF3D",
          ...(kind === "call" ? { default_sound: true, visibility: "PUBLIC" } : {}),
        },
      },
    };
    const res = await fetchFn(`https://fcm.googleapis.com/v1/projects/${project}/messages:send`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: JSON.stringify({ message }),
    });
    if (res.ok) {
      sent++;
    } else {
      if (res.status === 404) stale.push(token); // the app was removed or the token is old
      console.error("fcm send failed", res.status);
    }
  }
  if (stale.length) {
    try { await db.setTokens(to, tokens.filter((t) => !stale.includes(t))); } catch { /* next time */ }
  }
  return { status: 200, body: { ok: true, sent } };

  function ok(skipped) { return { status: 200, body: { ok: true, sent: 0, skipped } }; }
  function bad(detail, status = 400) { return { status, body: { detail } }; }
}
