// v0.13: admin website helpers (login, small data shapes).
// The page is /admin (public/admin/index.html), the API is /api/admin.
// v0.14: login with ONE long password (Vercel setting ADMIN_PASSWORD, 16+
// letters). No email login. The server signs its own session token; a new
// password logs everybody out.
import { createHash, createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import { HttpError } from './http.js';

export const MIN_PASSWORD = 16;

/** How long a login lasts. */
export const SESSION_MS = 12 * 3600 * 1000;

/** The admin password from Vercel ('' = not set up / too short). */
export function adminPassword(raw = process.env.ADMIN_PASSWORD) {
  const p = String(raw || '').trim();
  return p.length >= MIN_PASSWORD ? p : '';
}

function notSetUpError(raw) {
  const p = String(raw || '').trim();
  return new HttpError(
    503,
    p
      ? `ADMIN_PASSWORD on Vercel is too short (use ${MIN_PASSWORD}+ letters), then Redeploy.`
      : 'Admin login is not set up: add ADMIN_PASSWORD (a long password, 16+ letters) on Vercel -> Settings -> Environment Variables, then Redeploy.',
  );
}

const sha = (s) => createHash('sha256').update(String(s)).digest();
const key = (pw) => createHmac('sha256', 'instantgram-admin-v14').update(pw).digest();
const sign = (pw, payload) => createHmac('sha256', key(pw)).update(payload).digest('base64url');

/** Same length compare that takes the same time for any text. */
export function samePassword(a, b) {
  return timingSafeEqual(sha(a), sha(b));
}

/** "<expires ms>.<random>.<signature>" */
export function makeToken(pw, now = Date.now()) {
  const payload = `${now + SESSION_MS}.${randomBytes(12).toString('base64url')}`;
  return `${payload}.${sign(pw, payload)}`;
}

/** true when [token] was made with [pw] and is not too old. */
export function checkToken(token, pw, now = Date.now()) {
  if (typeof token !== 'string' || !pw) return false;
  const parts = token.split('.');
  if (parts.length !== 3) return false;
  const exp = Number(parts[0]);
  if (!Number.isFinite(exp) || exp < now || exp > now + SESSION_MS + 60_000) return false;
  const want = Buffer.from(sign(pw, `${parts[0]}.${parts[1]}`));
  const got = Buffer.from(parts[2]);
  return want.length === got.length && timingSafeEqual(want, got);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Password -> session token. A wrong password waits a bit (slows guessing). */
export async function login(password, { raw = process.env.ADMIN_PASSWORD, now = Date.now(), wait = sleep } = {}) {
  const pw = adminPassword(raw);
  if (!pw) throw notSetUpError(raw);
  if (typeof password !== 'string' || !password) throw new HttpError(400, 'Type the admin password');
  if (password.length > 500 || !samePassword(password.trim(), pw)) {
    await wait(800);
    throw new HttpError(401, 'Wrong password');
  }
  return { token: makeToken(pw, now), expiresAt: new Date(now + SESSION_MS).toISOString() };
}

/** Header "Authorization: Bearer <token>" -> admin, or throws. */
export async function requireAdmin(req, { raw = process.env.ADMIN_PASSWORD, now = Date.now() } = {}) {
  const pw = adminPassword(raw);
  if (!pw) throw notSetUpError(raw);
  const header = req.headers?.authorization || '';
  const match = /^Bearer (.+)$/.exec(header);
  if (!match) throw new HttpError(401, 'Not logged in');
  if (!checkToken(match[1], pw, now)) throw new HttpError(401, 'Login expired. Please log in again.');
  return { uid: 'admin', email: 'admin' };
}

// ---------------- data helpers ----------------

const KEY_KINDS = ['post', 'clip', 'story', 'thumb', 'audio', 'comment', 'voice'];

/** All app file keys in a document that belong to [uid] (any depth). */
export function fileKeys(data, uid) {
  const out = new Set();
  if (!uid) return [];
  const walk = (v, depth) => {
    if (depth > 6 || v == null) return;
    if (typeof v === 'string') {
      if (!v.includes('..') && KEY_KINDS.some((k) => v.startsWith(`${k}/${uid}/`)) && v.length < 300) out.add(v);
      return;
    }
    if (Array.isArray(v)) return v.forEach((x) => walk(x, depth + 1));
    if (typeof v === 'object') Object.values(v).forEach((x) => walk(x, depth + 1));
  };
  walk(data, 0);
  return [...out];
}

export function str(v, n = 300) {
  const s = typeof v === 'string' ? v : v == null ? '' : String(v);
  return s.length > n ? `${s.slice(0, n)}…` : s;
}

export function num(v) {
  return typeof v === 'number' && Number.isFinite(v) ? v : 0;
}

/** Small user card for the website. */
export function userCard(id, d = {}) {
  return {
    uid: id,
    username: str(d.username, 40),
    name: str(d.name, 60),
    email: str(d.email, 120),
    photoUrl: str(d.photoUrl, 600),
    followers: num(d.followersCount),
    following: num(d.followingCount),
    posts: num(d.postsCount),
    country: str(d.country, 4),
    private: d.isPrivate === true,
    banned: d.banned === true,
    createdAt: d.createdAt || null,
  };
}

/** Small post / clip / moment card. */
export function postCard(id, d = {}, kind = 'post') {
  const first = Array.isArray(d.media) && d.media.length ? d.media[0] || {} : {};
  const isVideo = d.type === 'clip' || d.type === 'video' || first.type === 'video' || d.isVideo === true || /\.(mp4|mov|webm|3gp|mkv)(\?|$)/i.test(String(d.mediaUrl || first.url || ''));
  return {
    id,
    kind,
    type: kind === 'moment' ? (isVideo ? 'video' : 'photo') : str(d.type || 'photo', 10),
    authorId: str(d.authorId, 128),
    authorUsername: str(d.authorUsername, 40),
    caption: str(d.caption, 400),
    thumb: str(d.thumbUrl || first.thumbUrl || (isVideo ? '' : d.mediaUrl || first.url) || '', 600),
    mediaUrl: str(d.mediaUrl || first.url || '', 600),
    isVideo,
    count: Array.isArray(d.media) ? d.media.length : 1,
    likes: num(d.likesCount),
    comments: num(d.commentsCount),
    views: num(d.uniqueViews),
    createdAt: d.createdAt || null,
    expiresAt: d.expiresAt || null,
  };
}

/** Firestore REST filter helpers. */
export const F = {
  eq: (field, value) => ({ fieldFilter: { field: { fieldPath: field }, op: 'EQUAL', value } }),
  ge: (field, value) => ({ fieldFilter: { field: { fieldPath: field }, op: 'GREATER_THAN_OR_EQUAL', value } }),
  le: (field, value) => ({ fieldFilter: { field: { fieldPath: field }, op: 'LESS_THAN_OR_EQUAL', value } }),
  gt: (field, value) => ({ fieldFilter: { field: { fieldPath: field }, op: 'GREATER_THAN', value } }),
  and: (...filters) => ({ compositeFilter: { op: 'AND', filters } }),
  ts: (date) => ({ timestampValue: new Date(date).toISOString() }),
  s: (v) => ({ stringValue: String(v) }),
  b: (v) => ({ booleanValue: !!v }),
};

/** Text of a notice push. */
export function noticeMessages(tokens, title, text, image = '') {
  return tokens.map((token) => ({
    token,
    data: { type: 'notice' },
    android: {
      priority: 'HIGH',
      ttl: '604800s',
      notification: {
        channel_id: 'activity',
        icon: 'ic_stat_instantgram',
        color: '#C6FF3D',
        title: str(title || 'InstantGram', 80),
        body: str(text, 900),
        // v0.14: big picture in the notification
        ...(image ? { image } : {}),
      },
    },
  }));
}

/** Checks the notice text. */
export function checkNotice(body) {
  const title = str(body.title || 'InstantGram', 80).trim() || 'InstantGram';
  const text = typeof body.text === 'string' ? body.text.trim() : '';
  if (!text) throw new HttpError(400, 'Write the message');
  if (text.length > 900) throw new HttpError(400, 'Message is too long (max 900 letters)');
  return { title, text };
}

/** Runs [fn] for every item, [n] at a time. */
export async function pool(items, n, fn) {
  const out = [];
  let i = 0;
  const workers = Array.from({ length: Math.min(n, items.length) }, async () => {
    while (i < items.length) {
      const k = i++;
      out[k] = await fn(items[k], k);
    }
  });
  await Promise.all(workers);
  return out;
}
