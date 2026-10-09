// The admin panel's work (https://<signer>/admin). Only requests carrying ADMIN_KEY reach
// this file (see handleAdmin in core.js). It reads and changes Firestore and Firebase sign-in
// with the service account (FIREBASE_SERVICE_ACCOUNT), and removes files from the bucket.
//
// Every op answers quickly: long jobs (deleting an account, a push to everybody) do a part
// and answer {more:true, cursor}; the panel calls again with that cursor until it is done.

import { googleToken, encodeValue, decodeFields } from "./push.js";
import { filterFor, DEFAULT_WORDS } from "./moderation.js";

const ID = /^[A-Za-z0-9_-]{1,128}$/;
const UIDRE = /^[A-Za-z0-9]{1,128}$/;
const MEDIA_KEY = /^(image|video|thumb)\/([A-Za-z0-9]{1,128})\/([a-f0-9]{32})\.([a-z0-9]{2,4})$/;

export const USER_SUBCOLLECTIONS = [
  "followers", "following", "saved", "reposts", "blocked",
  "requests", "approved", "sent_requests", "audiences", "highlights",
];

export class AdminError extends Error {
  constructor(message, status = 400) { super(message); this.status = status; }
}

// ------------------------------------------------------------------ Firestore REST

/** Firestore through its REST API: the same small interface the tests fake in memory. */
export function restDb(sa, project, fetchFn = fetch) {
  const root = `projects/${project}/databases/(default)/documents`;
  const base = `https://firestore.googleapis.com/v1/${root}`;
  const headers = async () => ({ authorization: `Bearer ${await googleToken(sa, fetchFn)}`, "content-type": "application/json" });
  const toDoc = (d) => ({ id: d.name.split("/").pop(), path: d.name.slice(root.length + 1), data: decodeFields(d.fields) });
  const call = async (url, init, what) => {
    const res = await fetchFn(url, { ...init, headers: await headers() });
    if (!res.ok) {
      let why = "";
      try { const j = await res.json(); why = (j && j.error && j.error.message) || ""; } catch { /* none */ }
      throw new AdminError(`Firestore ${what} failed (${res.status}) ${why}`.trim(), 502);
    }
    return res.json();
  };
  const filter = (where) => {
    const one = ([field, op, value]) => ({
      fieldFilter: { field: { fieldPath: field }, op: OPS[op], value: encodeValue(value) },
    });
    if (!where || !where.length) return undefined;
    if (where.length === 1) return one(where[0]);
    return { compositeFilter: { op: "AND", filters: where.map(one) } };
  };
  const structured = (collection, q = {}) => {
    const s = { from: [{ collectionId: collection }] };
    const w = filter(q.where);
    if (w) s.where = w;
    if (q.orderBy) {
      s.orderBy = q.orderBy.map(([f, dir]) => ({ field: { fieldPath: f }, direction: dir === "desc" ? "DESCENDING" : "ASCENDING" }));
    }
    if (q.after && q.orderBy) {
      // a cursor is the values of the order fields, then the document path
      const named = q.orderBy[q.orderBy.length - 1][0] === "__name__";
      const vals = q.after.slice(0, -1).slice(0, named ? q.orderBy.length - 1 : q.orderBy.length).map((v, i) => encodeValue(isDateField(q.orderBy[i][0]) && v ? new Date(v) : v));
      if (q.orderBy[q.orderBy.length - 1][0] !== "__name__") {
        s.orderBy.push({ field: { fieldPath: "__name__" }, direction: s.orderBy[s.orderBy.length - 1].direction });
      }
      s.startAt = { values: [...vals, { referenceValue: `${root}/${q.after[q.after.length - 1]}` }], before: false };
    }
    if (q.limit) s.limit = q.limit;
    if (q.select) s.select = { fields: q.select.map((f) => ({ fieldPath: f })) };
    return s;
  };
  return {
    async get(path) {
      const res = await fetchFn(`${base}/${path}`, { headers: await headers() });
      if (res.status === 404) return null;
      if (!res.ok) throw new AdminError(`Firestore read failed (${res.status})`, 502);
      return toDoc(await res.json());
    },
    /** q = {where:[[field, op, value]], orderBy:[[field, "desc"]], limit, after} ; parent = "" or a doc path */
    async query(collection, q = {}, parent = "") {
      const url = `${base}${parent ? "/" + parent : ""}:runQuery`;
      const rows = await call(url, { method: "POST", body: JSON.stringify({ structuredQuery: structured(collection, q) }) }, "query");
      return rows.filter((r) => r.document).map((r) => toDoc(r.document));
    },
    async list(collectionPath, pageSize = 100, pageToken = "") {
      const url = `${base}/${collectionPath}?pageSize=${pageSize}${pageToken ? `&pageToken=${encodeURIComponent(pageToken)}` : ""}`;
      const j = await call(url, { method: "GET" }, "list");
      return { docs: (j.documents || []).map(toDoc), next: j.nextPageToken || "" };
    },
    async count(collection, where = []) {
      const s = structured(collection, { where });
      const body = { structuredAggregationQuery: { structuredQuery: s, aggregations: [{ alias: "n", count: {} }] } };
      const rows = await call(`${base}:runAggregationQuery`, { method: "POST", body: JSON.stringify(body) }, "count");
      const v = rows[0] && rows[0].result && rows[0].result.aggregateFields && rows[0].result.aggregateFields.n;
      return v ? Number(v.integerValue || 0) : 0;
    },
    /** Many deletes and updates in one go. writes = [{del: path}] | [{set: path, data, add: {field: n}}] */
    async write(writes) {
      for (let i = 0; i < writes.length; i += 400) {
        const part = writes.slice(i, i + 400).map((w) => {
          if (w.del) return { delete: `${root}/${w.del}` };
          const fields = Object.fromEntries(Object.entries(w.data || {}).map(([k, v]) => [k, encodeValue(v)]));
          // set = update an existing doc; put = create or update; create = only a new doc
          const path = w.set || w.put || w.create;
          const out = {
            update: { name: `${root}/${path}`, fields },
            updateMask: { fieldPaths: Object.keys(w.data || {}).map((k) => (/^[A-Za-z_][A-Za-z0-9_]*$/.test(k) ? k : "`" + k + "`")) },
          };
          if (w.set) out.currentDocument = { exists: true };
          if (w.create) { out.currentDocument = { exists: false }; delete out.updateMask; }
          if (w.add) {
            out.updateTransforms = Object.entries(w.add).map(([f, n]) => ({ fieldPath: f, increment: encodeValue(n) }));
          }
          return out;
        });
        // a missing document in an update makes the whole commit fail: those go one by one
        try {
          await call(`${base}:commit`, { method: "POST", body: JSON.stringify({ writes: part }) }, "write");
        } catch (e) {
          const must = (w) => w.delete || !w.currentDocument || w.currentDocument.exists === false;
          if (part.length === 1) { if (must(part[0])) throw e; continue; }
          for (const w of part) {
            try { await call(`${base}:commit`, { method: "POST", body: JSON.stringify({ writes: [w] }) }, "write"); } catch (e2) { if (must(w)) throw e2; }
          }
        }
      }
    },
  };
}

const OPS = { "==": "EQUAL", "<": "LESS_THAN", "<=": "LESS_THAN_OR_EQUAL", ">": "GREATER_THAN", ">=": "GREATER_THAN_OR_EQUAL", "array-contains": "ARRAY_CONTAINS", in: "IN" };
const isDateField = (f) => /At$|^lastActive$/.test(f);

// ------------------------------------------------------------- Firebase sign-in REST

export function restAuth(sa, project, fetchFn = fetch) {
  const base = `https://identitytoolkit.googleapis.com/v1/projects/${project}`;
  const call = async (path, body) => {
    const res = await fetchFn(`${base}/${path}`, {
      method: "POST",
      headers: { authorization: `Bearer ${await googleToken(sa, fetchFn)}`, "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    const j = await res.json().catch(() => ({}));
    if (!res.ok) {
      const why = (j && j.error && j.error.message) || String(res.status);
      if (why.includes("USER_NOT_FOUND")) return null;
      throw new AdminError(`Firebase sign-in: ${why}${res.status === 403 ? " (the service account needs the Firebase Authentication Admin role)" : ""}`, 502);
    }
    return j;
  };
  return {
    async lookup(uid) {
      const j = await call("accounts:lookup", { localId: [uid] });
      const u = j && j.users && j.users[0];
      if (!u) return null;
      return {
        email: u.email || "", disabled: Boolean(u.disabled),
        created: u.createdAt ? Number(u.createdAt) : 0, lastLogin: u.lastLoginAt ? Number(u.lastLoginAt) : 0,
      };
    },
    /** Blocks sign-in and logs the account out everywhere (or lets it back in). */
    async setDisabled(uid, off) {
      const body = { localId: uid, disableUser: off };
      if (off) body.validSince = String(Math.floor(Date.now() / 1000));
      return call("accounts:update", body);
    },
    async remove(uid) { return call("accounts:delete", { localId: uid }); },
  };
}

// --------------------------------------------------------------------- helpers

const when = (v) => (v instanceof Date ? v.toISOString() : v || null);
const str = (v) => (typeof v === "string" ? v : "");
const num = (v) => (typeof v === "number" ? v : 0);

/** Files a post or moment points at (m:<key>), only well-formed bucket keys. */
export function mediaKeys(data) {
  const refs = [data.imageUrl, data.videoUrl, data.thumbnailUrl];
  for (const m of Array.isArray(data.media) ? data.media : []) {
    if (m && typeof m === "object") refs.push(m.u, m.th);
  }
  const out = new Set();
  for (const r of refs) {
    if (typeof r === "string" && r.startsWith("m:") && MEDIA_KEY.test(r.slice(2))) out.add(r.slice(2));
  }
  return [...out];
}

function userRow(d) {
  const u = d.data;
  return {
    uid: d.id, username: str(u.username), fullName: str(u.fullName), email: str(u.email),
    photo: str(u.photoUrl), createdAt: when(u.createdAt), lastActive: when(u.lastActive),
    online: u.online === true, banned: u.banned === true, posts: num(u.postsCount),
    followers: num(u.followersCount), following: num(u.followingCount), bio: str(u.bio), private: u.isPrivate === true,
    verified: u.verified === true, bannedUntil: when(u.bannedUntil), warnings: num(u.warnings),
  };
}

function postRow(d) {
  const p = d.data;
  return {
    id: d.id, type: str(p.type) || "image", authorId: str(p.authorId), author: str(p.authorUsername),
    caption: str(p.caption).slice(0, 300), createdAt: when(p.createdAt),
    image: str(p.thumbnailUrl) || str(p.imageUrl) || (Array.isArray(p.media) && p.media[0] ? str(p.media[0].th) || str(p.media[0].u) : ""),
    video: str(p.videoUrl), likes: num(p.likeCount), comments: num(p.commentCount), views: num(p.viewCount),
    reports: num(p.reportCount), hidden: p.hidden === true,
  };
}

function storyRow(d, col) {
  const s = d.data;
  return {
    id: d.id, col, authorId: str(s.authorId), author: str(s.authorUsername), createdAt: when(s.createdAt),
    expiresAt: when(s.expiresAt), image: str(s.thumbnailUrl) || str(s.imageUrl), video: str(s.videoUrl),
  };
}

/** Deletes every document of a collection (and the sub-collections named in `subs`), until the time runs out. */
async function clearCollection(ctx, path, subs = []) {
  let n = 0;
  for (;;) {
    if (n > 0 && ctx.late()) return { n, more: true }; // at least one page per call, so it always moves on
    const page = await ctx.db.list(path, 200);
    if (!page.docs.length) return { n, more: false };
    for (const d of page.docs) {
      for (const s of subs) {
        const r = await clearCollection(ctx, `${d.path}/${s}`);
        if (r.more) return { n, more: true };
      }
    }
    await ctx.db.write(page.docs.map((d) => ({ del: d.path })));
    n += page.docs.length;
  }
}

async function removeFiles(ctx, keys) {
  let n = 0;
  for (const k of keys) {
    try { await ctx.store.delete(k); n++; } catch { /* already gone */ }
  }
  return n;
}

// ------------------------------------------------------------------------- ops

async function stats(ctx) {
  const now = ctx.nowMs;
  const ago = (ms) => new Date(now - ms);
  const H = 3600_000;
  const jobs = {
    users: ctx.db.count("users"),
    new24h: ctx.db.count("users", [["createdAt", ">=", ago(24 * H)]]),
    new7d: ctx.db.count("users", [["createdAt", ">=", ago(7 * 24 * H)]]),
    activeNow: ctx.db.count("users", [["lastActive", ">=", ago(4 * 60_000)]]),
    active24h: ctx.db.count("users", [["lastActive", ">=", ago(24 * H)]]),
    banned: ctx.db.count("users", [["banned", "==", true]]),
    posts: ctx.db.count("posts"),
    clips: ctx.db.count("posts", [["type", "in", ["video", "photoclip"]]]),
    posts24h: ctx.db.count("posts", [["createdAt", ">=", ago(24 * H)]]),
    moments: ctx.db.count("stories", [["expiresAt", ">", new Date(now)]]),
    privateMoments: ctx.db.count("privateStories", [["expiresAt", ">", new Date(now)]]),
    chats: ctx.db.count("chats"),
    reports: ctx.db.count("reports", [["status", "==", "open"]]),
    review: ctx.db.count("modQueue", [["status", "==", "open"]]),
    phones: ctx.db.count("pushTokens"),
  };
  const out = {};
  await Promise.all(Object.entries(jobs).map(async ([k, p]) => {
    try { out[k] = await p; } catch { out[k] = null; }
  }));
  out.moments = (out.moments || 0) + (out.privateMoments || 0);
  delete out.privateMoments;
  return { ok: true, stats: out, at: new Date(now).toISOString() };
}

async function users(ctx, body) {
  const q = str(body.q).trim().replace(/^@/, "");
  let docs = [];
  if (q.includes("@")) {
    docs = await ctx.db.query("users", { where: [["email", "==", q.toLowerCase()]], limit: 20 });
    if (!docs.length && q !== q.toLowerCase()) docs = await ctx.db.query("users", { where: [["email", "==", q]], limit: 20 });
  } else if (q) {
    const lower = q.toLowerCase();
    docs = await ctx.db.query("users", { where: [["username", ">=", lower], ["username", "<", lower + "\uf8ff"]], orderBy: [["username", "asc"]], limit: 30 });
    if (UIDRE.test(q) && q.length >= 20 && !docs.some((d) => d.id === q)) {
      const one = await ctx.db.get(`users/${q}`);
      if (one) docs.unshift(one);
    }
    return { ok: true, users: docs.map(userRow), next: null };
  } else {
    docs = await ctx.db.query("users", { orderBy: [["createdAt", "desc"]], limit: 30, after: Array.isArray(body.after) ? body.after : undefined });
  }
  const last = docs[docs.length - 1];
  return { ok: true, users: docs.map(userRow), next: !q && docs.length === 30 && last ? [when(last.data.createdAt), last.path] : null };
}

async function user(ctx, body) {
  const uid = needUid(body.uid);
  const d = await ctx.db.get(`users/${uid}`);
  let login = null;
  try { login = await ctx.auth.lookup(uid); } catch (e) { login = { error: e.message }; }
  if (!d && !login) throw new AdminError("No such account.", 404);
  const posts = await ctx.db.query("posts", { where: [["authorId", "==", uid]], orderBy: [["createdAt", "desc"]], limit: 30 });
  let moments = [];
  for (const col of ["stories", "privateStories"]) {
    const s = await ctx.db.query(col, { where: [["authorId", "==", uid]], limit: 30 });
    moments = moments.concat(s.filter((x) => x.data.expiresAt instanceof Date && x.data.expiresAt.getTime() > ctx.nowMs).map((x) => storyRow(x, col)));
  }
  const reported = await ctx.db.query("reports", { where: [["ownerId", "==", uid]], limit: 50 });
  return {
    ok: true,
    user: d ? { ...userRow(d), bannedReason: str(d.data.bannedReason) } : { uid, username: "(no profile)", banned: false },
    login, posts: posts.map(postRow), moments, reports: reported.length,
  };
}

async function ban(ctx, body) {
  const uid = needUid(body.uid);
  const on = body.on !== false;
  // days > 0: suspended for a while (login stays on; the app logs them out until then)
  const days = on ? Math.min(365, Math.max(0, Math.floor(Number(body.days) || 0))) : 0;
  const until = days > 0 ? new Date(ctx.nowMs + days * 86400_000) : null;
  await ctx.auth.setDisabled(uid, on && !until);
  await ctx.db.write([{ set: `users/${uid}`, data: { banned: on, bannedReason: on ? str(body.reason).slice(0, 200) : "", bannedUntil: until } }]);
  return { ok: true, banned: on, until: when(until) };
}

async function posts(ctx, body) {
  const kind = str(body.kind);
  const where = kind === "clip" ? [["type", "in", ["video", "photoclip"]]] : kind === "post" ? [["type", "==", "image"]] : [];
  const docs = await ctx.db.query("posts", { where, orderBy: [["createdAt", "desc"]], limit: 24, after: Array.isArray(body.after) ? body.after : undefined });
  const last = docs[docs.length - 1];
  return { ok: true, posts: docs.map(postRow), next: docs.length === 24 && last ? [when(last.data.createdAt), last.path] : null };
}

async function moments(ctx) {
  let out = [];
  for (const col of ["stories", "privateStories"]) {
    const docs = await ctx.db.query(col, { where: [["expiresAt", ">", new Date(ctx.nowMs)]], orderBy: [["expiresAt", "desc"]], limit: 60 });
    out = out.concat(docs.map((d) => storyRow(d, col)));
  }
  out.sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
  return { ok: true, moments: out };
}

async function deletePost(ctx, body) {
  const id = needId(body.id);
  const d = await ctx.db.get(`posts/${id}`);
  if (!d) return { ok: true, gone: true };
  for (const sub of ["likes", "views", "reporters"]) {
    if ((await clearCollection(ctx, `posts/${id}/${sub}`)).more) return { ok: true, more: true };
  }
  if ((await clearCollection(ctx, `posts/${id}/comments`, ["likes"])).more) return { ok: true, more: true };
  const files = await removeFiles(ctx, mediaKeys(d.data));
  const writes = [{ del: `posts/${id}` }];
  if (str(d.data.authorId)) writes.push({ set: `users/${d.data.authorId}`, data: {}, add: { postsCount: -1 } });
  await ctx.db.write(writes);
  return { ok: true, files };
}

async function deleteMoment(ctx, body) {
  const col = body.col === "privateStories" ? "privateStories" : "stories";
  const id = needId(body.id);
  const d = await ctx.db.get(`${col}/${id}`);
  if (!d) return { ok: true, gone: true };
  for (const sub of ["views", "likes", "replies"]) {
    if ((await clearCollection(ctx, `${col}/${id}/${sub}`)).more) return { ok: true, more: true };
  }
  const files = await removeFiles(ctx, mediaKeys(d.data));
  await ctx.db.write([{ del: `${col}/${id}` }]);
  return { ok: true, files };
}

async function comments(ctx, body) {
  const id = needId(body.postId);
  const page = await ctx.db.list(`posts/${id}/comments`, 100, str(body.after));
  const rows = page.docs.map((d) => ({
    id: d.id, authorId: str(d.data.authorId), author: str(d.data.authorUsername),
    text: str(d.data.text).slice(0, 500), createdAt: when(d.data.createdAt), hasMedia: Boolean(d.data.gifUrl || d.data.mediaUrl || d.data.clipId),
  }));
  return { ok: true, comments: rows, next: page.next || null };
}

async function deleteComment(ctx, body) {
  const postId = needId(body.postId);
  const id = needId(body.id);
  const d = await ctx.db.get(`posts/${postId}/comments/${id}`);
  if (!d) return { ok: true, gone: true };
  if ((await clearCollection(ctx, `posts/${postId}/comments/${id}/likes`)).more) return { ok: true, more: true };
  await ctx.db.write([{ del: `posts/${postId}/comments/${id}` }, { set: `posts/${postId}`, data: {}, add: { commentCount: -1 } }]);
  return { ok: true };
}

async function reports(ctx, body) {
  const status = body.status === "done" ? "done" : "open";
  const docs = await ctx.db.query("reports", { where: [["status", "==", status]], limit: 200 });
  const rows = docs.map((d) => ({ id: d.id, ...d.data, createdAt: when(d.data.createdAt), doneAt: when(d.data.doneAt) }));
  rows.sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
  // the reported post, so the panel can show it
  const ids = [...new Set(rows.map((r) => r.postId).filter((x) => typeof x === "string" && ID.test(x)))].slice(0, 60);
  const found = {};
  await Promise.all(ids.map(async (pid) => {
    const p = await ctx.db.get(`posts/${pid}`);
    found[pid] = p ? postRow(p) : null;
  }));
  // who sent them
  const by = [...new Set(rows.map((r) => r.by).filter((x) => typeof x === "string" && UIDRE.test(x) && !rows.find((r) => r.by === x && r.byUsername)))].slice(0, 60);
  const names = {};
  await Promise.all(by.map(async (uid) => {
    const u = await ctx.db.get(`users/${uid}`);
    if (u) names[uid] = str(u.data.username);
  }));
  for (const r of rows) if (!r.byUsername && names[r.by]) r.byUsername = names[r.by];
  return { ok: true, reports: rows, posts: found };
}

async function resolveReport(ctx, body) {
  const id = needId(body.id);
  const action = ["dismissed", "removed", "banned"].includes(body.action) ? body.action : "dismissed";
  await ctx.db.write([{ set: `reports/${id}`, data: { status: "done", action, doneAt: new Date(ctx.nowMs) } }]);
  return { ok: true };
}

// ----------------------------------------------------------- push to everybody

const PUSH_PAGE = 100;

async function broadcast(ctx, body) {
  const title = str(body.title).trim().slice(0, 60);
  const text = str(body.body).trim().slice(0, 240);
  if (!text) throw new AdminError("Write the message first.");
  const image = imageUrl(ctx, body.image);
  const page = await ctx.db.list("pushTokens", PUSH_PAGE, str(body.cursor));
  let sent = 0, failed = 0;
  const stale = [];
  const jobs = [];
  for (const d of page.docs) {
    if (d.data.off === true) continue;
    const tokens = Array.isArray(d.data.tokens) ? d.data.tokens.filter((t) => typeof t === "string").slice(-5) : [];
    for (const t of tokens) jobs.push({ uid: d.id, token: t, all: tokens });
  }
  for (let i = 0; i < jobs.length; i += 10) {
    await Promise.all(jobs.slice(i, i + 10).map(async (j) => {
      const r = await ctx.push(j.token, title || "InstantGram", text, { image });
      if (r === "ok") sent++;
      else { failed++; if (r === "stale") stale.push(j); }
    }));
  }
  // forget phones that no longer have the app
  const byUid = {};
  for (const s of stale) (byUid[s.uid] ||= { all: s.all, gone: [] }).gone.push(s.token);
  const writes = Object.entries(byUid).map(([uid, x]) => ({ set: `pushTokens/${uid}`, data: { tokens: x.all.filter((t) => !x.gone.includes(t)) } }));
  if (writes.length) { try { await ctx.db.write(writes); } catch { /* next time */ } }
  return { ok: true, sent, failed, cursor: page.next || null, more: Boolean(page.next) };
}

/** Sends one notification; "ok", "stale" (token is old) or "fail". */
export function fcmSender(sa, project, fetchFn = fetch) {
  return async (token, title, text, extra = {}) => {
    const res = await fetchFn(`https://fcm.googleapis.com/v1/projects/${project}/messages:send`, {
      method: "POST",
      headers: { authorization: `Bearer ${await googleToken(sa, fetchFn)}`, "content-type": "application/json" },
      body: JSON.stringify({ message: {
        token,
        notification: { title, body: text, ...(extra.image ? { image: extra.image } : {}) },
        data: extra.data || { type: "broadcast" },
        android: { priority: "HIGH", notification: { channel_id: "activity", icon: "ic_stat_instantgram", color: "#C6FF3D", ...(extra.image ? { image: extra.image } : {}) } },
      } }),
    });
    if (res.ok) return "ok";
    return res.status === 404 ? "stale" : "fail";
  };
}

// ------------------------------------------------------------ delete an account
// The same steps as tools/admin/wipe.py, cut into parts that each fit in one call.

export const STAGES = ["files", "posts", "activity", "stories", "views", "chats", "calls", "inbox", "follows", "profile", "auth"];

const STAGE_RUN = {
  // their files in the bucket
  async files(ctx, uid) {
    const r = await ctx.wipeFiles(uid);
    return { done: !r.more, n: r.deleted };
  },
  // their own posts with likes, views and comments
  async posts(ctx, uid) {
    const docs = await ctx.db.query("posts", { where: [["authorId", "==", uid]], limit: 10 });
    if (!docs.length) return { done: true, n: 0 };
    let n = 0;
    for (const d of docs) {
      const r = await deletePost(ctx, { id: d.id });
      if (r.more) return { done: false, n };
      n++;
      if (ctx.late()) break;
    }
    return { done: false, n };
  },
  // their likes, views and comments on other people's posts
  async activity(ctx, uid, cursor) {
    const page = await ctx.db.list("posts", 20, cursor || "");
    let n = 0;
    for (const p of page.docs) {
      if (p.data.authorId === uid) continue;
      const writes = [];
      if (await ctx.db.get(`${p.path}/likes/${uid}`)) writes.push({ del: `${p.path}/likes/${uid}` }, { set: p.path, data: {}, add: { likeCount: -1 } });
      if (await ctx.db.get(`${p.path}/views/${uid}`)) writes.push({ del: `${p.path}/views/${uid}` }, { set: p.path, data: {}, add: { viewCount: -1 } });
      const mine = await ctx.db.query("comments", { where: [["authorId", "==", uid]], limit: 100 }, p.path);
      for (const c of mine) {
        await clearCollection(ctx, `${c.path}/likes`);
        writes.push({ del: c.path });
      }
      if (mine.length) writes.push({ set: p.path, data: {}, add: { commentCount: -mine.length } });
      if (writes.length) { await ctx.db.write(writes); n += writes.length; }
    }
    return page.next ? { done: false, n, cursor: page.next } : { done: true, n };
  },
  // their moments
  async stories(ctx, uid) {
    let n = 0;
    for (const col of ["stories", "privateStories"]) {
      const docs = await ctx.db.query(col, { where: [["authorId", "==", uid]], limit: 20 });
      for (const d of docs) {
        const r = await deleteMoment(ctx, { col, id: d.id });
        if (r.more) return { done: false, n };
        n++;
      }
      if (docs.length) return { done: false, n };
    }
    return { done: true, n };
  },
  // their "viewed" line on other people's moments. cursor = "<col>|<pageToken>"
  async views(ctx, uid, cursor) {
    let [col, token] = (cursor || "stories|").split("|");
    if (col !== "privateStories") col = "stories";
    const page = await ctx.db.list(col, 50, token || "");
    const writes = [];
    for (const s of page.docs) {
      if (await ctx.db.get(`${s.path}/views/${uid}`)) writes.push({ del: `${s.path}/views/${uid}` });
    }
    if (writes.length) await ctx.db.write(writes);
    if (page.next) return { done: false, n: writes.length, cursor: `${col}|${page.next}` };
    if (col === "stories") return { done: false, n: writes.length, cursor: "privateStories|" };
    return { done: true, n: writes.length };
  },
  // their messages; a chat with nothing left goes, otherwise its preview is fixed
  async chats(ctx, uid, cursor) {
    const docs = await ctx.db.query("chats", { where: [["members", "array-contains", uid]], limit: 5, orderBy: [["__name__", "asc"]], after: cursor ? [cursor] : undefined });
    if (!docs.length) return { done: true, n: 0 };
    let n = 0;
    let last = cursor;
    for (const c of docs) {
      let token = "";
      const left = [];
      const del = [];
      do {
        const page = await ctx.db.list(`${c.path}/messages`, 300, token);
        for (const m of page.docs) (m.data.senderId === uid ? del : left).push(m);
        token = page.next;
      } while (token);
      if (!left.length) del.push({ path: c.path });
      await ctx.db.write(del.map((m) => ({ del: m.path })));
      n += del.length;
      if (left.length && c.data.lastSender === uid) {
        left.sort((a, b) => time(b.data.createdAt) - time(a.data.createdAt));
        await ctx.db.write([{ set: c.path, data: { lastText: str(left[0].data.text), lastSender: str(left[0].data.senderId) } }]);
      }
      last = c.path;
      if (ctx.late()) break;
    }
    return { done: false, n, cursor: last };
  },
  async calls(ctx, uid) {
    let n = 0;
    for (const f of ["callerId", "calleeId"]) {
      const docs = await ctx.db.query("calls", { where: [[f, "==", uid]], limit: 300 });
      if (docs.length) { await ctx.db.write(docs.map((d) => ({ del: d.path }))); n += docs.length; }
    }
    return { done: n === 0, n };
  },
  // notifications, push addresses, story-alert list
  async inbox(ctx, uid) {
    const r = await clearCollection(ctx, `notifications/${uid}/items`);
    if (r.more) return { done: false, n: r.n };
    await ctx.db.write([{ del: `notifications/${uid}` }, { del: `pushTokens/${uid}` }, { del: `storyAlerts/${uid}` }]);
    return { done: true, n: r.n + 3 };
  },
  // their side of follows and follow requests
  async follows(ctx, uid) {
    const back = { following: ["followers", "followersCount"], followers: ["following", "followingCount"], sent_requests: ["requests", ""], requests: ["sent_requests", ""] };
    let n = 0;
    for (const [mine, [theirs, counter]] of Object.entries(back)) {
      const page = await ctx.db.list(`users/${uid}/${mine}`, 100);
      const writes = [];
      for (const f of page.docs) {
        if (await ctx.db.get(`users/${f.id}/${theirs}/${uid}`)) {
          writes.push({ del: `users/${f.id}/${theirs}/${uid}` });
          if (counter) writes.push({ set: `users/${f.id}`, data: {}, add: { [counter]: -1 } });
        }
        writes.push({ del: f.path }); // my line goes too, so the next call moves on
      }
      if (writes.length) { await ctx.db.write(writes); n += writes.length; }
      if (page.docs.length) return { done: false, n };
    }
    return { done: true, n };
  },
  // the profile, its lists and the username
  async profile(ctx, uid) {
    let n = 0;
    for (const sub of USER_SUBCOLLECTIONS) {
      const r = await clearCollection(ctx, `users/${uid}/${sub}`);
      n += r.n;
      if (r.more) return { done: false, n };
    }
    const names = await ctx.db.query("usernames", { where: [["uid", "==", uid]], limit: 20 });
    await ctx.db.write([...names.map((d) => ({ del: d.path })), { del: `users/${uid}` }]);
    return { done: true, n: n + names.length + 1 };
  },
  async auth(ctx, uid) {
    await ctx.auth.remove(uid);
    return { done: true, n: 1 };
  },
};

const time = (v) => (v instanceof Date ? v.getTime() : 0);

async function deleteAccount(ctx, body) {
  const uid = needUid(body.uid);
  let blocked = "";
  if (body.blockEmail === true && !body.stage && !body.cursor) {
    // first call: remember the email before the account is gone
    let email = "";
    try { const l = await ctx.auth.lookup(uid); email = (l && l.email) || ""; } catch { /* from the profile */ }
    if (!email) { const d = await ctx.db.get(`users/${uid}`); email = d ? str(d.data.email) : ""; }
    if (email) {
      blocked = email.trim().toLowerCase();
      await ctx.db.write([{ put: `blockedEmails/${blocked}`, data: { uid, at: new Date(ctx.nowMs) } }]);
    }
  }
  let stage = STAGES.includes(body.stage) ? body.stage : STAGES[0];
  let cursor = typeof body.cursor === "string" ? body.cursor : "";
  let removed = 0;
  for (;;) {
    const r = await STAGE_RUN[stage](ctx, uid, cursor);
    removed += r.n || 0;
    if (r.done) {
      const i = STAGES.indexOf(stage);
      if (i === STAGES.length - 1) return { ok: true, done: true, stage, removed, ...(blocked ? { blocked } : {}) };
      stage = STAGES[i + 1];
      cursor = "";
    } else {
      cursor = r.cursor || "";
    }
    if (ctx.late()) return { ok: true, done: false, stage, cursor, removed, ...(blocked ? { blocked } : {}) };
  }
}


// ------------------------------------------------------------ v1.30 tools

const DAY = 86400_000;
const dayKey = (ms) => new Date(ms).toISOString().slice(0, 10);

/** Only pictures the panel uploaded (or any https link) go into notifications. */
function imageUrl(ctx, v) {
  const u = str(v).trim();
  if (!u) return "";
  if (!/^https:\/\/[^\s"'<>]{4,500}$/.test(u)) throw new AdminError("The picture link must start with https://");
  return u;
}

/** Sign-ups, uploads and active people per day, plus the top posts and creators. */
async function charts(ctx, body) {
  const days = Math.min(90, Math.max(7, Math.floor(Number(body.days) || 30)));
  const today = Date.parse(dayKey(ctx.nowMs));
  const since = new Date(today - (days - 1) * DAY);
  const keys = Array.from({ length: days }, (_, i) => dayKey(today - (days - 1 - i) * DAY));
  const zero = () => Object.fromEntries(keys.map((k) => [k, 0]));
  const signups = zero(), uploads = zero(), clips = zero(), active = zero();
  const [u, p, top, creators] = await Promise.all([
    ctx.db.query("users", { where: [["createdAt", ">=", since]], select: ["createdAt"], limit: 5000 }),
    ctx.db.query("posts", { where: [["createdAt", ">=", since]], select: ["createdAt", "type"], limit: 5000 }),
    ctx.db.query("posts", { orderBy: [["likeCount", "desc"]], limit: 10 }),
    ctx.db.query("users", { orderBy: [["followersCount", "desc"]], limit: 10 }),
  ]);
  for (const d of u) { const k = d.data.createdAt instanceof Date ? dayKey(d.data.createdAt.getTime()) : ""; if (k in signups) signups[k]++; }
  for (const d of p) {
    const k = d.data.createdAt instanceof Date ? dayKey(d.data.createdAt.getTime()) : "";
    if (!(k in uploads)) continue;
    uploads[k]++;
    if (d.data.type === "video" || d.data.type === "photoclip") clips[k]++;
  }
  await Promise.all(keys.map(async (k) => {
    try { const d = await ctx.db.get(`dailyStats/${k}`); if (d) active[k] = num(d.data.active); } catch { /* 0 */ }
  }));
  return {
    ok: true, days: keys,
    signups: keys.map((k) => signups[k]), uploads: keys.map((k) => uploads[k]),
    clips: keys.map((k) => clips[k]), active: keys.map((k) => active[k]),
    topPosts: top.map(postRow), topCreators: creators.map(userRow),
  };
}

async function verify(ctx, body) {
  const uid = needUid(body.uid);
  const on = body.on !== false;
  await ctx.db.write([{ set: `users/${uid}`, data: { verified: on } }]);
  return { ok: true, verified: on };
}

const randomId = (n = 20) => {
  const abc = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
  const b = crypto.getRandomValues(new Uint8Array(n));
  return Array.from(b, (x) => abc[x % abc.length]).join("");
};

/** A message or warning to one person: in their Notifications and as a push (with a picture). */
async function notifyUser(ctx, body) {
  const uid = needUid(body.uid);
  const warn = body.warn === true;
  const title = str(body.title).trim().slice(0, 60);
  const text = str(body.body).trim().slice(0, 500);
  if (!text) throw new AdminError("Write the message first.");
  const image = imageUrl(ctx, body.image);
  const id = randomId();
  await ctx.db.write([{ create: `notifications/${uid}/items/${id}`, data: {
    type: warn ? "warning" : "admin", actorId: "", actorName: "InstantGram", actorPhoto: "",
    postId: "", thumb: image, text, title, at: new Date(ctx.nowMs), read: false,
  } }]);
  if (warn) await ctx.db.write([{ set: `users/${uid}`, data: {}, add: { warnings: 1 } }]);
  let sent = 0;
  const reg = await ctx.db.get(`pushTokens/${uid}`);
  const tokens = reg && reg.data.off !== true && Array.isArray(reg.data.tokens) ? reg.data.tokens.filter((t) => typeof t === "string").slice(-5) : [];
  for (const t of tokens) {
    const r = await ctx.push(t, warn ? "\u26a0\ufe0f Warning from InstantGram" : (title || "InstantGram"), text.slice(0, 240), { image, data: { type: "activity", from: "", postId: "" } });
    if (r === "ok") sent++;
  }
  return { ok: true, id, sent, phones: tokens.length };
}

/** Gives the account a new random username (for a rude or stolen one). */
async function resetUsername(ctx, body) {
  const uid = needUid(body.uid);
  const d = await ctx.db.get(`users/${uid}`);
  if (!d) throw new AdminError("No such account.", 404);
  let name = "";
  for (let i = 0; i < 6 && !name; i++) {
    const n = "user_" + Array.from(crypto.getRandomValues(new Uint8Array(6)), (x) => (x % 36).toString(36)).join("");
    if (!(await ctx.db.get(`usernames/${n}`))) name = n;
  }
  if (!name) throw new AdminError("Try again.", 503);
  const old = await ctx.db.query("usernames", { where: [["uid", "==", uid]], limit: 20 });
  await ctx.db.write([
    { create: `usernames/${name}`, data: { uid } },
    ...old.map((o) => ({ del: o.path })),
    { set: `users/${uid}`, data: { username: name } },
  ]);
  // their posts show the new name too
  const posts = await ctx.db.query("posts", { where: [["authorId", "==", uid]], select: ["authorId"], limit: 300 });
  if (posts.length) await ctx.db.write(posts.map((x) => ({ set: x.path, data: { authorUsername: name } })));
  return { ok: true, username: name, old: str(d.data.username), posts: posts.length };
}

async function resetPhoto(ctx, body) {
  const uid = needUid(body.uid);
  const d = await ctx.db.get(`users/${uid}`);
  if (!d) throw new AdminError("No such account.", 404);
  const ref = str(d.data.photoUrl);
  await ctx.db.write([{ set: `users/${uid}`, data: { photoUrl: "" } }]);
  let files = 0;
  if (ref.startsWith("m:") && MEDIA_KEY.test(ref.slice(2))) files = await removeFiles(ctx, [ref.slice(2)]);
  const posts = await ctx.db.query("posts", { where: [["authorId", "==", uid]], select: ["authorId"], limit: 300 });
  if (posts.length) await ctx.db.write(posts.map((x) => ({ set: x.path, data: { authorPhotoUrl: "" } })));
  return { ok: true, files };
}

/** Phones signed in to the account (for push) and what they run. */
async function devices(ctx, body) {
  const uid = needUid(body.uid);
  const reg = await ctx.db.get(`pushTokens/${uid}`);
  if (!reg) return { ok: true, devices: [], phones: 0, off: false };
  const tokens = Array.isArray(reg.data.tokens) ? reg.data.tokens.length : 0;
  const info = reg.data.devices && typeof reg.data.devices === "object" ? reg.data.devices : {};
  const list = Object.entries(info).map(([id, v]) => ({
    id, os: str(v && v.os), osVersion: str(v && v.osVersion).slice(0, 120), app: str(v && v.app), at: when(v && v.at),
  }));
  list.sort((a, b) => String(b.at).localeCompare(String(a.at)));
  return { ok: true, devices: list, phones: tokens, off: reg.data.off === true, lastSeen: when(reg.data.at) };
}

/** Posts by "@username", or with words / #tags in the caption (the newest 400 are searched). */
async function searchPosts(ctx, body) {
  const q = str(body.q).trim();
  if (!q) throw new AdminError("Type something to search.");
  if (q.startsWith("@")) {
    const name = q.slice(1).toLowerCase();
    const names = await ctx.db.query("users", { where: [["username", "==", name]], limit: 1 });
    if (!names.length) return { ok: true, posts: [] };
    const docs = await ctx.db.query("posts", { where: [["authorId", "==", names[0].id]], orderBy: [["createdAt", "desc"]], limit: 60 });
    return { ok: true, posts: docs.map(postRow) };
  }
  const want = q.toLowerCase();
  const docs = await ctx.db.query("posts", { orderBy: [["createdAt", "desc"]], limit: 400 });
  return { ok: true, posts: docs.filter((d) => str(d.data.caption).toLowerCase().includes(want)).slice(0, 60).map(postRow) };
}

/** Only chats somebody reported may be read or cleaned. */
async function reportedChat(ctx, chatId) {
  const id = needId(chatId);
  const r = await ctx.db.query("reports", { where: [["chatId", "==", id]], limit: 1 });
  if (!r.length) throw new AdminError("Only reported chats can be opened.", 403);
  return id;
}

async function chat(ctx, body) {
  const id = await reportedChat(ctx, body.chatId);
  const docs = await ctx.db.query("messages", { orderBy: [["createdAt", "desc"]], limit: 150 }, `chats/${id}`);
  const rows = docs.map((d) => ({
    id: d.id, from: str(d.data.senderId), text: str(d.data.text).slice(0, 1000), type: str(d.data.type) || "text",
    media: str(d.data.mediaUrl) || str(d.data.imageUrl) || str(d.data.gifUrl), createdAt: when(d.data.createdAt),
  }));
  const members = id.split("_");
  const names = {};
  await Promise.all(members.map(async (m) => {
    if (!UIDRE.test(m)) return;
    const u = await ctx.db.get(`users/${m}`);
    names[m] = u ? str(u.data.username) : "(deleted)";
  }));
  return { ok: true, chatId: id, names, messages: rows.reverse() };
}

async function deleteMessage(ctx, body) {
  const id = await reportedChat(ctx, body.chatId);
  const mid = needId(body.id);
  await ctx.db.write([{ del: `chats/${id}/messages/${mid}` }]);
  return { ok: true };
}

/** A picture for notifications, stored with the app's media: {url}. */
async function uploadImage(ctx, body) {
  const b64 = str(body.data).replace(/^data:[^,]*,/, "");
  if (!b64) throw new AdminError("Pick a picture.");
  let bytes;
  try { bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0)); } catch { throw new AdminError("That picture could not be read."); }
  if (bytes.length > 3 * 1024 * 1024) throw new AdminError("The picture is bigger than 3 MB.");
  const kind = bytes[0] === 0xff && bytes[1] === 0xd8 ? ["jpg", "image/jpeg"]
    : bytes[0] === 0x89 && bytes[1] === 0x50 ? ["png", "image/png"]
      : bytes[8] === 0x57 && bytes[9] === 0x45 ? ["webp", "image/webp"] : null;
  if (!kind) throw new AdminError("Use a JPG, PNG or WebP picture.");
  if (!ctx.store || !ctx.store.put) throw new AdminError("Storage is not set up.", 503);
  const hex = Array.from(crypto.getRandomValues(new Uint8Array(16)), (x) => x.toString(16).padStart(2, "0")).join("");
  const key = `image/admin/${hex}.${kind[0]}`;
  await ctx.store.put(key, bytes, kind[1]);
  return { ok: true, key, url: `${str(ctx.publicBase).replace(/\/+$/, "")}/${key}` };
}

async function hidePost(ctx, body) {
  const id = needId(body.id);
  const on = body.on !== false;
  await ctx.db.write([{ set: `posts/${id}`, data: on ? { hidden: true } : { hidden: false, reportCount: 0 } }]);
  return { ok: true, hidden: on };
}

/** App settings: autoHide = hide posts after this many reports (0 = off). */
async function config(ctx, body) {
  if (body.set && typeof body.set === "object") {
    const n = Math.min(1000, Math.max(0, Math.floor(Number(body.set.autoHide) || 0)));
    await ctx.db.write([{ put: "config/app", data: { autoHide: n } }]);
  }
  const d = await ctx.db.get("config/app");
  return { ok: true, config: { autoHide: d ? num(d.data.autoHide) : 0 } };
}

async function blockedEmails(ctx, body) {
  if (body.remove) {
    const e = str(body.remove).trim().toLowerCase();
    if (!e || e.includes("/")) throw new AdminError("Bad email.");
    await ctx.db.write([{ del: `blockedEmails/${e}` }]);
  }
  if (body.add) {
    const e = str(body.add).trim().toLowerCase();
    if (!/^[^\s/@]+@[^\s/@]+\.[^\s/@]+$/.test(e)) throw new AdminError("Bad email.");
    await ctx.db.write([{ put: `blockedEmails/${e}`, data: { uid: "", at: new Date(ctx.nowMs) } }]);
  }
  const page = await ctx.db.list("blockedEmails", 300);
  return { ok: true, emails: page.docs.map((d) => ({ email: d.id, uid: str(d.data.uid), at: when(d.data.at) })) };
}


// ------------------------------------------------------------ v1.31 moderation

const SCAN_PAGE = 200;
const cleanList = (v) => (Array.isArray(v) ? [...new Set(v.filter((x) => typeof x === "string").map((x) => x.trim().toLowerCase()).filter((x) => x && x.length <= 60))].slice(0, 2000) : []);

/** Checks what was posted since the last scan with the word rules (also old or changed apps).
 *  Blocked words: the post is hidden at once. Anything found goes to the review queue. */
async function modScan(ctx) {
  const state = await ctx.db.get("config/modscan");
  const start = new Date(ctx.nowMs - 2 * DAY);
  const postsAt = state && state.data.postsAt instanceof Date ? state.data.postsAt : start;
  const usersAt = state && state.data.usersAt instanceof Date ? state.data.usersAt : start;
  const cfg = await ctx.db.get("config/moderation");
  const f = filterFor(cfg && cfg.data);
  let flagged = 0;
  const flag = async (id, item) => {
    try { await ctx.db.write([{ create: `modQueue/${id}`, data: { ...item, status: "open", at: new Date(ctx.nowMs) } }]); flagged++; } catch { /* already in the queue */ }
  };
  const posts = await ctx.db.query("posts", { where: [["createdAt", ">", postsAt]], orderBy: [["createdAt", "asc"]], limit: SCAN_PAGE });
  for (const d of posts) {
    const r = f.scan(str(d.data.caption));
    if (r.clean) continue;
    const words = [...r.phrases, ...r.hits.map((h) => h.word)].slice(0, 10);
    await flag(`post_${d.id}`, { kind: "post", postId: d.id, uid: str(d.data.authorId), author: str(d.data.authorUsername), text: str(d.data.caption).slice(0, 500), words, severity: r.blocked ? "blocked" : "mild" });
    if (r.blocked) await ctx.db.write([{ set: `posts/${d.id}`, data: { hidden: true } }]);
  }
  const users = await ctx.db.query("users", { where: [["createdAt", ">", usersAt]], orderBy: [["createdAt", "asc"]], limit: SCAN_PAGE });
  for (const d of users) {
    const name = str(d.data.username), full = str(d.data.fullName), bio = str(d.data.bio);
    const rn = f.scan(`${name.replace(/[._]/g, " ")} ${full}`);
    const whole = f.matchToken(name);
    const rb = f.scan(bio);
    if (rn.clean && !whole && (rb.clean || !rb.blocked)) continue;
    const words = [...rn.phrases, ...rn.hits.map((h) => h.word), ...(whole ? [whole[0]] : []), ...rb.phrases, ...rb.hits.map((h) => h.word)].slice(0, 10);
    await flag(`user_${d.id}`, { kind: "user", uid: d.id, author: name, text: `${full}${bio ? " · " + bio : ""}`.slice(0, 500), words, severity: "name" });
  }
  const last = (rows, f2, old) => (rows.length && rows[rows.length - 1].data[f2] instanceof Date ? rows[rows.length - 1].data[f2] : old);
  await ctx.db.write([{ put: "config/modscan", data: { postsAt: last(posts, "createdAt", postsAt), usersAt: last(users, "createdAt", usersAt), at: new Date(ctx.nowMs) } }]);
  return { ok: true, scanned: posts.length + users.length, flagged, more: posts.length === SCAN_PAGE || users.length === SCAN_PAGE };
}

async function modQueue(ctx, body) {
  const status = body.status === "done" ? "done" : "open";
  const docs = await ctx.db.query("modQueue", { where: [["status", "==", status]], limit: 200 });
  const rows = docs.map((d) => ({ id: d.id, ...d.data, at: when(d.data.at), doneAt: when(d.data.doneAt) }));
  rows.sort((a, b) => String(b.at).localeCompare(String(a.at)));
  const found = {};
  await Promise.all(rows.filter((r) => r.postId && ID.test(r.postId)).slice(0, 80).map(async (r) => {
    const p = await ctx.db.get(`posts/${r.postId}`);
    found[r.postId] = p ? postRow(p) : null;
  }));
  return { ok: true, items: rows, posts: found };
}

async function modResolve(ctx, body) {
  const id = needId(body.id);
  const action = ["approved", "removed", "warned", "hidden", "renamed"].includes(body.action) ? body.action : "approved";
  const d = await ctx.db.get(`modQueue/${id}`);
  if (!d) throw new AdminError("Already gone.", 404);
  const writes = [{ set: `modQueue/${id}`, data: { status: "done", action, doneAt: new Date(ctx.nowMs) } }];
  if (action === "approved" && d.data.kind === "post" && ID.test(str(d.data.postId))) writes.push({ set: `posts/${d.data.postId}`, data: { hidden: false } });
  await ctx.db.write(writes);
  return { ok: true };
}

/** The panel's word lists (added to the built-in ones) and words that are fine after all. */
async function modWords(ctx, body) {
  if (body.set && typeof body.set === "object") {
    await ctx.db.write([{ put: "config/moderation", data: { blocked: cleanList(body.set.blocked), mild: cleanList(body.set.mild), allow: cleanList(body.set.allow), at: new Date(ctx.nowMs) } }]);
  }
  const d = await ctx.db.get("config/moderation");
  const v = d ? d.data : {};
  return { ok: true, blocked: cleanList(v.blocked), mild: cleanList(v.mild), allow: cleanList(v.allow), defaults: { blocked: DEFAULT_WORDS.blocked.length, mild: DEFAULT_WORDS.mild.length } };
}

/** Tries a text against the current rules (panel: "Test a text"). */
async function modTest(ctx, body) {
  const cfg = await ctx.db.get("config/moderation");
  const r = filterFor(cfg && cfg.data).scan(str(body.text).slice(0, 2000));
  return { ok: true, blocked: r.blocked, clean: r.clean, words: [...r.phrases, ...r.hits.map((h) => `${h.word}${h.blocked ? " (blocked)" : ""}`)] };
}

// ------------------------------------------------------------------- dispatch

function needUid(v) {
  if (!UIDRE.test(String(v || ""))) throw new AdminError("Bad user id.");
  return String(v);
}
function needId(v) {
  if (!ID.test(String(v || ""))) throw new AdminError("Bad id.");
  return String(v);
}

export const PANEL_OPS = {
  stats, users, user, ban, posts, moments, deletePost, deleteMoment, comments, deleteComment,
  reports, resolveReport, broadcast, deleteAccount,
  charts, verify, notifyUser, resetUsername, resetPhoto, devices, searchPosts, chat, deleteMessage,
  uploadImage, hidePost, config, blockedEmails,
  modScan, modQueue, modResolve, modWords, modTest,
};

/** ctx = {db, auth, store, push, wipeFiles, nowMs, budgetMs, publicBase} */
export async function runPanelOp(body, ctx) {
  const fn = PANEL_OPS[body.op];
  if (!fn) throw new AdminError("Unknown op.");
  const start = Date.now();
  const full = { nowMs: Date.now(), budgetMs: 8000, ...ctx };
  full.late = () => Date.now() - start > full.budgetMs;
  return fn(full, body);
}
