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
  // v0.13: admin website (block accounts)
  'https://www.googleapis.com/auth/identitytoolkit',
  'https://www.googleapis.com/auth/cloud-platform',
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

// ---------------- v0.13: admin website helpers ----------------

function dbRoot(sa) {
  return `https://firestore.googleapis.com/v1/projects/${sa.project_id}/databases/(default)/documents`;
}

async function gfetch(sa, url, init, what, fetchFn) {
  const token = await accessToken(sa, fetchFn);
  const r = await fetchFn(url, {
    ...init,
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', ...(init?.headers || {}) },
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) {
    console.error(what, r.status, j?.error?.message || j);
    const msg = String(j?.error?.message || '');
    // missing index: Google sends a link to create it
    const link = /https:\/\/console\.firebase\.google\.com\S+/.exec(msg);
    const err = new HttpError(r.status === 404 ? 404 : 500, link ? `Needs a database index. Open: ${link[0]}` : `Google: ${what} failed (${r.status}) ${msg}`.trim());
    // v0.0.2: lets callers spot a failed precondition (already exists / changed)
    err.googleStatus = r.status;
    err.googleCode = String(j?.error?.status || '');
    throw err;
  }
  return j;
}

/** Document id from a REST "name". */
/** v0.0.2: true when a write failed because a document already existed
 *  or changed meanwhile (commitWrites preconditions). */
export function isPreconditionError(e) {
  const code = String(e?.googleCode || '');
  return e?.googleStatus === 409 || code === 'FAILED_PRECONDITION' || code === 'ALREADY_EXISTS' || code === 'ABORTED';
}

export function idOf(name) {
  return String(name || '').split('/').pop();
}

/**
 * Runs a structured query. [parent] = '' (root) or e.g. 'posts/abc'.
 * -> [{ id, path, data, createTime }]
 */
export async function runQuery(sa, structuredQuery, parent = '', fetchFn = fetch) {
  const url = `${dbRoot(sa)}${parent ? `/${parent}` : ''}:runQuery`;
  const j = await gfetch(sa, url, { method: 'POST', body: JSON.stringify({ structuredQuery }) }, 'query', fetchFn);
  return (Array.isArray(j) ? j : [])
    .filter((x) => x.document)
    .map((x) => ({
      id: idOf(x.document.name),
      path: String(x.document.name).split('/documents/')[1] || '',
      data: fromFields(x.document.fields),
      createTime: x.document.createTime || null,
    }));
}

/** Counts documents (cheap: 1 read per 1000). [where] optional. */
export async function countQuery(sa, collectionId, where = null, { allDescendants = false } = {}, fetchFn = fetch) {
  const structuredQuery = { from: [{ collectionId, allDescendants }] };
  if (where) structuredQuery.where = where;
  const j = await gfetch(
    sa,
    `${dbRoot(sa)}:runAggregationQuery`,
    { method: 'POST', body: JSON.stringify({ structuredAggregationQuery: { structuredQuery, aggregations: [{ alias: 'n', count: {} }] } }) },
    'count',
    fetchFn,
  );
  const row = (Array.isArray(j) ? j : []).find((x) => x.result);
  return Number(row?.result?.aggregateFields?.n?.integerValue || 0);
}

/** Several writes at once (max 500), all or nothing. Write = { delete: path } |
 *  { update: path, fields, mask?: [..], mustExist?, mustNotExist?, updateTime? } |
 *  { transform: path, transforms: [...] } */
export async function commitWrites(sa, writes, fetchFn = fetch) {
  if (!writes.length) return;
  const name = (p) => `projects/${sa.project_id}/databases/(default)/documents/${p}`;
  const body = {
    writes: writes.map((w) => {
      if (w.delete) return { delete: name(w.delete) };
      if (w.transform) return { transform: { document: name(w.transform), fieldTransforms: w.transforms } };
      return {
        update: { name: name(w.update), fields: toFields(w.fields) },
        updateMask: { fieldPaths: w.mask || Object.keys(w.fields) },
        ...(w.mustExist ? { currentDocument: { exists: true } } : {}),
        // v0.0.2: create only / unchanged since read
        ...(w.mustNotExist ? { currentDocument: { exists: false } } : {}),
        ...(w.updateTime ? { currentDocument: { updateTime: w.updateTime } } : {}),
      };
    }),
  };
  await gfetch(sa, `${dbRoot(sa)}:commit`, { method: 'POST', body: JSON.stringify(body) }, 'write', fetchFn);
}

/** One page of a collection -> { docs: [{id, data}], next } */
export async function listPage(sa, collection, { pageSize = 100, pageToken = '', fields = [] } = {}, fetchFn = fetch) {
  const q = new URLSearchParams({ pageSize: String(pageSize) });
  if (pageToken) q.set('pageToken', pageToken);
  for (const f of fields) q.append('mask.fieldPaths', f);
  const j = await gfetch(sa, `${dbRoot(sa)}/${collection}?${q}`, { method: 'GET' }, 'list', fetchFn);
  return {
    docs: (j.documents || []).map((d) => ({ id: idOf(d.name), data: fromFields(d.fields) })),
    next: j.nextPageToken || '',
  };
}

/** Firebase Auth (admin): one account, or null. */
export async function authLookup(sa, uid, fetchFn = fetch) {
  const j = await gfetch(
    sa,
    `https://identitytoolkit.googleapis.com/v1/projects/${sa.project_id}/accounts:lookup`,
    { method: 'POST', body: JSON.stringify({ localId: [uid] }) },
    'auth lookup',
    fetchFn,
  );
  return (j.users || [])[0] || null;
}

/** Firebase Auth (admin): block / unblock login. Blocking also logs the
 *  account out everywhere (old tokens stop working). */
export async function authSetDisabled(sa, uid, disabled, fetchFn = fetch) {
  const body = { localId: uid, disableUser: !!disabled };
  if (disabled) body.validSince = String(Math.floor(Date.now() / 1000));
  await gfetch(
    sa,
    `https://identitytoolkit.googleapis.com/v1/projects/${sa.project_id}/accounts:update`,
    { method: 'POST', body: JSON.stringify(body) },
    'auth update',
    fetchFn,
  );
}

/** v0.14 Firebase Auth (admin): delete an account (gone = fine). */
export async function authDelete(sa, uid, fetchFn = fetch) {
  try {
    await gfetch(
      sa,
      `https://identitytoolkit.googleapis.com/v1/projects/${sa.project_id}/accounts:delete`,
      { method: 'POST', body: JSON.stringify({ localId: uid }) },
      'auth delete',
      fetchFn,
    );
    return true;
  } catch (e) {
    if (/USER_NOT_FOUND/.test(String(e?.message))) return false;
    throw e;
  }
}

/** v0.0.1 Firebase Auth (admin): the account with this email, or null. */
export async function authLookupEmail(sa, email, fetchFn = fetch) {
  const j = await gfetch(
    sa,
    `https://identitytoolkit.googleapis.com/v1/projects/${sa.project_id}/accounts:lookup`,
    { method: 'POST', body: JSON.stringify({ email: [email] }) },
    'auth lookup',
    fetchFn,
  );
  return (j.users || [])[0] || null;
}

/** v0.0.1 Firebase Auth (admin): mark the email as checked (sign up code). */
export async function authSetEmailVerified(sa, uid, fetchFn = fetch) {
  await gfetch(
    sa,
    `https://identitytoolkit.googleapis.com/v1/projects/${sa.project_id}/accounts:update`,
    { method: 'POST', body: JSON.stringify({ localId: uid, emailVerified: true }) },
    'auth update',
    fetchFn,
  );
}

/** Tests. */
export function _resetTokenCache() {
  cached = null;
}
