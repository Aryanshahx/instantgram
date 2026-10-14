// Google APIs with the Firebase service account (v0.10), without the
// Admin SDK: Firestore REST (read push tokens / the call) and FCM v1
// (make the phone ring).
//
// Vercel setting FIREBASE_SERVICE_ACCOUNT = the whole JSON file from
// Firebase console -> Project settings -> Service accounts ->
// "Generate new private key" (paste it as it is; base64 also works).
import { importPKCS8, SignJWT } from 'jose';
import { HttpError } from './http.js';

const SCOPES = [
  'https://www.googleapis.com/auth/firebase.messaging',
  'https://www.googleapis.com/auth/datastore',
].join(' ');

/** The service account, or null when not set / broken. */
export function serviceAccount(raw = process.env.FIREBASE_SERVICE_ACCOUNT) {
  let text = (raw || '').trim();
  if (!text) return null;
  if (!text.startsWith('{')) {
    try {
      text = Buffer.from(text, 'base64').toString('utf8').trim();
    } catch {
      return null;
    }
  }
  try {
    const j = JSON.parse(text);
    if (!j.client_email || !j.private_key || !j.project_id) return null;
    // pasted keys sometimes have "\\n" instead of new lines
    j.private_key = String(j.private_key).replace(/\\n/g, '\n');
    return j;
  } catch {
    return null;
  }
}

let cached = null; // { token, exp, email }

/** OAuth access token for the service account (cached ~55 min). */
export async function accessToken(sa, fetchFn = fetch) {
  const now = Math.floor(Date.now() / 1000);
  if (cached && cached.email === sa.client_email && cached.exp - 300 > now) {
    return cached.token;
  }
  const key = await importPKCS8(sa.private_key, 'RS256');
  const assertion = await new SignJWT({ scope: SCOPES })
    .setProtectedHeader({ alg: 'RS256', typ: 'JWT' })
    .setIssuer(sa.client_email)
    .setSubject(sa.client_email)
    .setAudience('https://oauth2.googleapis.com/token')
    .setIssuedAt(now)
    .setExpirationTime(now + 3600)
    .sign(key);
  const r = await fetchFn('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion,
    }).toString(),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || !j.access_token) {
    console.error('google token', r.status, j);
    throw new HttpError(500, 'Service account key not accepted by Google');
  }
  cached = { token: j.access_token, exp: now + (Number(j.expires_in) || 3600), email: sa.client_email };
  return j.access_token;
}

/** Firestore REST value -> plain JS. */
export function fromValue(v) {
  if (!v || typeof v !== 'object') return null;
  if ('stringValue' in v) return v.stringValue;
  if ('booleanValue' in v) return v.booleanValue;
  if ('integerValue' in v) return Number(v.integerValue);
  if ('doubleValue' in v) return v.doubleValue;
  if ('timestampValue' in v) return v.timestampValue;
  if ('nullValue' in v) return null;
  if ('arrayValue' in v) return (v.arrayValue.values || []).map(fromValue);
  if ('mapValue' in v) return fromFields(v.mapValue.fields || {});
  return null;
}

export function fromFields(fields) {
  const out = {};
  for (const [k, v] of Object.entries(fields || {})) out[k] = fromValue(v);
  return out;
}

/** Reads one document ("calls/abc"), or null when it doesn't exist. */
export async function getDoc(sa, path, fetchFn = fetch) {
  const token = await accessToken(sa, fetchFn);
  const url = `https://firestore.googleapis.com/v1/projects/${sa.project_id}/databases/(default)/documents/${path}`;
  const r = await fetchFn(url, { headers: { Authorization: `Bearer ${token}` } });
  if (r.status === 404) return null;
  const j = await r.json().catch(() => ({}));
  if (!r.ok) {
    console.error('firestore get', path, r.status, j);
    throw new HttpError(500, 'Could not read the database');
  }
  return fromFields(j.fields);
}

/** Sends one FCM v1 message. Returns true when Google accepted it. */
export async function sendFcm(sa, message, fetchFn = fetch) {
  const token = await accessToken(sa, fetchFn);
  const r = await fetchFn(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ message }),
  });
  if (!r.ok) {
    const j = await r.json().catch(() => ({}));
    // UNREGISTERED = old phone / app removed: not an error for us
    console.warn('fcm', r.status, j?.error?.status || '', j?.error?.message || '');
  }
  return r.ok;
}

/** Tests. */
export function _resetTokenCache() {
  cached = null;
}
