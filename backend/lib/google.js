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

/**
 * v0.12: checks FIREBASE_SERVICE_ACCOUNT and says what is wrong.
 * -> { sa, problem }  (sa = null when it can't be used)
 */
export function checkServiceAccount(raw = process.env.FIREBASE_SERVICE_ACCOUNT) {
  let text = (raw || '').trim();
  if (!text) {
    return { sa: null, problem: 'FIREBASE_SERVICE_ACCOUNT is not set on Vercel (or Vercel was not redeployed after adding it)' };
  }
  // pasted with quotes around it: "{...}" or '{...}'
  if ((text.startsWith("'") && text.endsWith("'")) || (text.startsWith('"') && text.endsWith('"'))) {
    try {
      const inner = text.startsWith('"') ? JSON.parse(text) : text.slice(1, -1);
      if (typeof inner === 'string') text = inner.trim();
    } catch {
      text = text.slice(1, -1).trim();
    }
  }
  if (!text.startsWith('{')) {
    try {
      const decoded = Buffer.from(text, 'base64').toString('utf8').trim();
      if (decoded.startsWith('{')) text = decoded;
    } catch {
      /* not base64 */
    }
  }
  if (!text.startsWith('{')) {
    return { sa: null, problem: 'FIREBASE_SERVICE_ACCOUNT is not the key file: paste the WHOLE .json file, starting with {' };
  }
  let j;
  try {
    j = JSON.parse(text);
  } catch {
    return { sa: null, problem: 'FIREBASE_SERVICE_ACCOUNT is not complete JSON: copy the whole .json file again (from { to })' };
  }
  const missing = ['client_email', 'private_key', 'project_id'].filter((k) => !j[k]);
  if (missing.length) {
    return { sa: null, problem: `FIREBASE_SERVICE_ACCOUNT has no ${missing.join(', ')}: use Firebase -> Project settings -> Service accounts -> Generate new private key` };
  }
  // pasted keys sometimes have "\\n" instead of new lines
  j.private_key = String(j.private_key).replace(/\\n/g, '\n');
  return { sa: j, problem: null };
}

/** The service account, or null when not set / broken. */
export function serviceAccount(raw = process.env.FIREBASE_SERVICE_ACCOUNT) {
  return checkServiceAccount(raw).sa;
}

/** 503 error with the exact reason (shown in the app). */
export function notSetUp(what, raw = process.env.FIREBASE_SERVICE_ACCOUNT) {
  const { problem } = checkServiceAccount(raw);
  return new HttpError(503, `${what} is not set up: ${problem || 'FIREBASE_SERVICE_ACCOUNT problem'}`);
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

/** Plain JS -> Firestore REST value. */
export function toValue(v) {
  if (v === null || v === undefined) return { nullValue: null };
  if (v instanceof Date) return { timestampValue: v.toISOString() };
  if (typeof v === 'boolean') return { booleanValue: v };
  if (typeof v === 'number') return Number.isInteger(v) ? { integerValue: String(v) } : { doubleValue: v };
  if (typeof v === 'string') return { stringValue: v };
  if (Array.isArray(v)) return { arrayValue: { values: v.map(toValue) } };
  if (typeof v === 'object') return { mapValue: { fields: toFields(v) } };
  return { nullValue: null };
}

export function toFields(o) {
  const out = {};
  for (const [k, v] of Object.entries(o || {})) out[k] = toValue(v);
  return out;
}

function docUrl(sa, path) {
  return `https://firestore.googleapis.com/v1/projects/${sa.project_id}/databases/(default)/documents/${path}`;
}

/** v0.12: document + its updateTime (for safe updates), or null. */
export async function getDocMeta(sa, path, fetchFn = fetch) {
  const token = await accessToken(sa, fetchFn);
  const r = await fetchFn(docUrl(sa, path), { headers: { Authorization: `Bearer ${token}` } });
  if (r.status === 404) return null;
  const j = await r.json().catch(() => ({}));
  if (!r.ok) {
    console.error('firestore get', path, r.status, j);
    throw new HttpError(500, 'Could not read the database');
  }
  return { data: fromFields(j.fields), updateTime: j.updateTime || null };
}

/**
 * v0.12: changes only [fields] of a document. With [updateTime] it only
 * works if nobody changed the document in between (returns false then).
 */
export async function patchDoc(sa, path, fields, { updateTime = null } = {}, fetchFn = fetch) {
  const token = await accessToken(sa, fetchFn);
  const q = new URLSearchParams();
  for (const k of Object.keys(fields)) q.append('updateMask.fieldPaths', k);
  if (updateTime) q.append('currentDocument.updateTime', updateTime);
  const r = await fetchFn(`${docUrl(sa, path)}?${q.toString()}`, {
    method: 'PATCH',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ fields: toFields(fields) }),
  });
  if (r.ok) return true;
  const j = await r.json().catch(() => ({}));
  if (r.status === 400 || r.status === 409 || r.status === 412) {
    console.warn('firestore patch skipped', path, r.status, j?.error?.status || '');
    return false;
  }
  console.error('firestore patch', path, r.status, j);
  throw new HttpError(500, 'Could not write the database');
}

/** v0.12: adds a document with a new id to a collection. Returns the id. */
export async function addDoc(sa, collectionPath, fields, fetchFn = fetch) {
  const token = await accessToken(sa, fetchFn);
  const r = await fetchFn(docUrl(sa, collectionPath), {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ fields: toFields(fields) }),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) {
    console.error('firestore add', collectionPath, r.status, j);
    throw new HttpError(500, 'Could not write the database');
  }
  return String(j.name || '').split('/').pop();
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
