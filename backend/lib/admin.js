// v0.13: admin website helpers (login, who is admin, small data shapes).
// The page is /admin (public/admin/index.html), the API is /api/admin.
import { createRemoteJWKSet, decodeJwt, jwtVerify } from 'jose';
import { HttpError, env, requireEnv } from './http.js';
import { FIREBASE_WEB_KEY } from './web-key.js';

/** Only these emails can use the admin website. */
export const DEFAULT_ADMINS = ['techlabs.hyper@gmail.com'];

export function adminEmails(raw = process.env.ADMIN_EMAILS) {
  const extra = String(raw || '')
    .split(/[,\s;]+/)
    .map((s) => s.trim().toLowerCase())
    .filter((s) => s.includes('@'));
  return [...new Set([...DEFAULT_ADMINS, ...extra])];
}

export function isAdminEmail(email, raw) {
  return typeof email === 'string' && adminEmails(raw).includes(email.trim().toLowerCase());
}

/** Firebase Web API key: Vercel setting, or the one taken from the app. */
export function webKey() {
  const k = env('FIREBASE_API_KEY') || env('FIREBASE_WEB_API_KEY') || FIREBASE_WEB_KEY || '';
  if (!k) {
    throw new HttpError(
      503,
      'Admin login is not set up: add FIREBASE_API_KEY on Vercel (Firebase console -> Project settings -> General -> Web API Key), then Redeploy.',
    );
  }
  return k;
}

/** Google's sign-in errors -> simple words. */
export function loginError(status, j) {
  const m = String(j?.error?.message || '');
  if (/INVALID_LOGIN_CREDENTIALS|INVALID_PASSWORD|EMAIL_NOT_FOUND|INVALID_EMAIL/.test(m)) {
    return new HttpError(401, 'Wrong email or password. Use the same password as in the InstantGram app.');
  }
  if (/USER_DISABLED/.test(m)) return new HttpError(403, 'This account is blocked.');
  if (/TOO_MANY_ATTEMPTS/.test(m)) return new HttpError(429, 'Too many tries. Wait a few minutes.');
  if (/API key not valid|API_KEY_INVALID/.test(m)) {
    return new HttpError(503, 'FIREBASE_API_KEY is wrong. Copy the Web API Key from Firebase console -> Project settings -> General.');
  }
  if (status === 403 || /blocked|PERMISSION_DENIED|API_KEY_/.test(m)) {
    return new HttpError(
      503,
      'Google blocked this API key for servers. Add FIREBASE_API_KEY on Vercel = Web API Key (Firebase console -> Project settings -> General), then Redeploy.',
    );
  }
  return new HttpError(502, `Login failed: ${m || status}`);
}

async function postJson(url, body, fetchFn, form = false) {
  const r = await fetchFn(url, {
    method: 'POST',
    headers: { 'Content-Type': form ? 'application/x-www-form-urlencoded' : 'application/json' },
    body: form ? new URLSearchParams(body).toString() : JSON.stringify(body),
  });
  const j = await r.json().catch(() => ({}));
  return { r, j };
}

function session(idToken, refreshToken, expiresIn) {
  const claims = decodeJwt(idToken);
  return {
    idToken,
    refreshToken,
    expiresIn: Number(expiresIn) || 3600,
    email: String(claims.email || ''),
    emailVerified: claims.email_verified === true,
  };
}

/** Email + password -> tokens (only admin emails). */
export async function login(email, password, { fetchFn = fetch, admins } = {}) {
  if (typeof email !== 'string' || typeof password !== 'string' || !email || !password) {
    throw new HttpError(400, 'Type your email and password');
  }
  // check first: this page never tests passwords of normal users
  if (!isAdminEmail(email, admins)) throw new HttpError(403, 'This email is not an admin.');
  const { r, j } = await postJson(
    `https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${encodeURIComponent(webKey())}`,
    { email: email.trim(), password, returnSecureToken: true },
    fetchFn,
  );
  if (!r.ok || !j.idToken) throw loginError(r.status, j);
  return session(j.idToken, j.refreshToken, j.expiresIn);
}

/** New token before the old one ends (1 hour). */
export async function refresh(refreshToken, { fetchFn = fetch, admins } = {}) {
  if (typeof refreshToken !== 'string' || refreshToken.length < 20) throw new HttpError(400, 'Bad request');
  const { r, j } = await postJson(
    `https://securetoken.googleapis.com/v1/token?key=${encodeURIComponent(webKey())}`,
    { grant_type: 'refresh_token', refresh_token: refreshToken },
    fetchFn,
    true,
  );
  if (!r.ok || !j.id_token) throw new HttpError(401, 'Login expired. Please log in again.');
  const s = session(j.id_token, j.refresh_token, j.expires_in);
  if (!isAdminEmail(s.email, admins)) throw new HttpError(403, 'This email is not an admin.');
  return s;
}

/** Sends the "verify your email" mail (needed once). */
export async function sendVerifyEmail(idToken, { fetchFn = fetch } = {}) {
  if (typeof idToken !== 'string' || idToken.length < 20) throw new HttpError(400, 'Bad request');
  const { r, j } = await postJson(
    `https://identitytoolkit.googleapis.com/v1/accounts:sendOobCode?key=${encodeURIComponent(webKey())}`,
    { requestType: 'VERIFY_EMAIL', idToken },
    fetchFn,
  );
  if (!r.ok) throw loginError(r.status, j);
  return { sent: true };
}

const JWKS = createRemoteJWKSet(
  new URL('https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com'),
);

/** Checks the token claims: admin email + verified email. */
export function checkAdminClaims(payload, admins) {
  if (!payload || !payload.sub) throw new HttpError(401, 'Login expired. Please log in again.');
  if (!isAdminEmail(payload.email, admins)) throw new HttpError(403, 'This email is not an admin.');
  if (payload.email_verified !== true) {
    throw new HttpError(403, 'Verify your email first (log in again and press "Send verification email").');
  }
  return { uid: payload.sub, email: String(payload.email).toLowerCase() };
}

/** Header "Authorization: Bearer <token>" -> { uid, email } or throws. */
export async function requireAdmin(req, { verify, admins } = {}) {
  const header = req.headers?.authorization || '';
  const match = /^Bearer (.+)$/.exec(header);
  if (!match) throw new HttpError(401, 'Not logged in');
  let payload;
  try {
    if (verify) {
      payload = await verify(match[1]);
    } else {
      const projectId = requireEnv('FIREBASE_PROJECT_ID');
      ({ payload } = await jwtVerify(match[1], JWKS, {
        issuer: `https://securetoken.google.com/${projectId}`,
        audience: projectId,
        algorithms: ['RS256'],
      }));
    }
  } catch (e) {
    if (e instanceof HttpError) throw e;
    throw new HttpError(401, 'Login expired. Please log in again.');
  }
  return checkAdminClaims(payload, admins);
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
export function noticeMessages(tokens, title, text) {
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

export function _decode(t) {
  return decodeJwt(t);
}
