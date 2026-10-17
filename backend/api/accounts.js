// POST /api/accounts   (v0.0.2: many accounts with ONE email + password)
//   { action: 'list' }                    -> { accounts: [{uid, username, name, photoUrl}], owner }
//   { action: 'create', username, name }  -> { uid, token }
//   { action: 'switch', uid }             -> { token }
//
// You log in once (email + password) and pick which account to use.
// The extra accounts have no password of their own: this server checks
// that you are logged in to an account of the same group and gives a
// one-time sign-in token (Firebase "custom token", made with the service
// account key). Groups are kept in accountFamilies/{ownerUid} and
// accountLinks/{uid}; only this server can read them (no app access).
import { importPKCS8, SignJWT } from 'jose';
import { randomInt } from 'node:crypto';
import { requireUser } from '../lib/firebase-auth.js';
import { HttpError, postHandler } from '../lib/http.js';
import { commitWrites, getDoc, getDocMeta, isPreconditionError, notSetUp, serviceAccount } from '../lib/google.js';

/** Max accounts on one login (the main one included). */
export const FAMILY_MAX = 5;
export const USERNAME_RE = /^[a-z0-9._]{3,30}$/;
const UID_RE = /^[A-Za-z0-9]{6,64}$/;
const ABC = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

/** A new random user id (28 letters / digits, like Firebase). */
export function newUid() {
  let s = '';
  for (let i = 0; i < 28; i++) s += ABC[randomInt(ABC.length)];
  return s;
}

/** Firebase custom token for [uid] (valid 1 hour, used at once by the app). */
export async function customToken(sa, uid, now = Math.floor(Date.now() / 1000)) {
  const key = await importPKCS8(sa.private_key, 'RS256');
  return new SignJWT({ uid })
    .setProtectedHeader({ alg: 'RS256', typ: 'JWT' })
    .setIssuer(sa.client_email)
    .setSubject(sa.client_email)
    .setAudience('https://identitytoolkit.googleapis.com/google.identity.identitytoolkit.v1.IdentityToolkit')
    .setIssuedAt(now)
    .setExpirationTime(now + 3600)
    .sign(key);
}

export function cleanName(v, fallback) {
  const s = String(v ?? '').replace(/\s+/g, ' ').trim().slice(0, 60);
  return s || fallback;
}

/** Owner of [uid]'s group (itself when it has no group). */
async function ownerOf(sa, uid, fetchFn) {
  const link = await getDoc(sa, `accountLinks/${uid}`, fetchFn);
  const o = link && typeof link.owner === 'string' ? link.owner : '';
  return UID_RE.test(o) ? o : uid;
}

/** { owner, members, updateTime } (members always has the owner first). */
export async function familyOf(sa, uid, fetchFn = fetch) {
  const owner = await ownerOf(sa, uid, fetchFn);
  const meta = await getDocMeta(sa, `accountFamilies/${owner}`, fetchFn);
  const list = Array.isArray(meta?.data?.members) ? meta.data.members.filter((m) => typeof m === 'string' && UID_RE.test(m)) : [];
  const members = [owner, ...list.filter((m) => m !== owner)];
  // someone pointing at a group that doesn't list them: only themselves
  if (!members.includes(uid)) return { owner: uid, members: [uid], updateTime: null, exists: false };
  return { owner, members, updateTime: meta?.updateTime || null, exists: !!meta };
}

export function profileCard(uid, d) {
  return {
    uid,
    username: String(d?.username || ''),
    name: String(d?.name || ''),
    photoUrl: String(d?.photoUrl || ''),
  };
}

export async function list(sa, uid, fetchFn = fetch) {
  const fam = await familyOf(sa, uid, fetchFn);
  const docs = await Promise.all(fam.members.map((m) => getDoc(sa, `users/${m}`, fetchFn)));
  const accounts = [];
  fam.members.forEach((m, i) => {
    if (docs[i]) accounts.push(profileCard(m, docs[i]));
  });
  return { owner: fam.owner, accounts };
}

export async function create(sa, uid, body, { fetchFn = fetch, now = new Date(), makeUid = newUid } = {}) {
  const username = String(body.username || '').trim().toLowerCase();
  if (!USERNAME_RE.test(username)) throw new HttpError(400, 'Username: 3-30 chars, only letters, numbers, . and _');
  const [me, priv, fam, taken] = await Promise.all([
    getDoc(sa, `users/${uid}`, fetchFn),
    getDoc(sa, `users/${uid}/private/info`, fetchFn),
    familyOf(sa, uid, fetchFn),
    getDoc(sa, `usernames/${username}`, fetchFn),
  ]);
  if (!me) throw new HttpError(404, 'Your profile was not found');
  if (me.banned === true) throw new HttpError(403, 'This account is blocked');
  if (taken) throw new HttpError(409, 'That username is taken.');
  if (fam.members.length >= FAMILY_MAX) {
    throw new HttpError(409, `You can have up to ${FAMILY_MAX} accounts with one login.`);
  }
  const id = makeUid();
  const email = String(me.email || '');
  const profile = {
    uid: id,
    name: cleanName(body.name, username),
    username,
    email,
    bio: '',
    website: '',
    photoUrl: '',
    coverUrl: '',
    postsCount: 0,
    followersCount: 0,
    followingCount: 0,
    isPrivate: false,
    createdAt: now,
  };
  if (typeof me.language === 'string' && me.language) profile.language = me.language.slice(0, 8);
  if (typeof me.country === 'string' && me.country) profile.country = me.country.slice(0, 3);
  const writes = [
    { update: `usernames/${username}`, fields: { uid: id, email }, mustNotExist: true },
    { update: `users/${id}`, fields: profile, mustNotExist: true },
    {
      update: `accountFamilies/${fam.owner}`,
      fields: { members: [...fam.members, id], email, updatedAt: now },
      ...(fam.updateTime ? { updateTime: fam.updateTime } : { mustNotExist: true }),
    },
    { update: `accountLinks/${id}`, fields: { owner: fam.owner } },
  ];
  if (!fam.exists) writes.push({ update: `accountLinks/${fam.owner}`, fields: { owner: fam.owner } });
  if (priv && typeof priv.birthDate === 'string') {
    writes.push({ update: `users/${id}/private/info`, fields: { birthDate: priv.birthDate, updatedAt: now } });
  }
  try {
    await commitWrites(sa, writes, fetchFn);
  } catch (e) {
    if (isPreconditionError(e)) throw new HttpError(409, 'That username was just taken, or your accounts changed. Try again.');
    throw e;
  }
  return { uid: id, token: await customToken(sa, id) };
}

export async function switchTo(sa, uid, body, fetchFn = fetch) {
  const target = String(body.uid || '');
  if (!UID_RE.test(target)) throw new HttpError(400, 'Bad request');
  if (target === uid) return { token: await customToken(sa, uid) };
  const fam = await familyOf(sa, uid, fetchFn);
  if (!fam.members.includes(target)) throw new HttpError(403, 'That account is not linked to this login');
  const user = await getDoc(sa, `users/${target}`, fetchFn);
  if (!user) throw new HttpError(404, 'That account was deleted');
  return { token: await customToken(sa, target) };
}

export async function handle(uid, body, { sa = serviceAccount(), fetchFn = fetch } = {}) {
  if (!sa) throw notSetUp('Accounts');
  switch (body.action) {
    case 'list':
      return list(sa, uid, fetchFn);
    case 'create':
      return create(sa, uid, body, { fetchFn });
    case 'switch':
      return switchTo(sa, uid, body, fetchFn);
    default:
      throw new HttpError(400, 'Unknown action');
  }
}

export default postHandler(async (req, body) => {
  const uid = await requireUser(req);
  return handle(uid, body);
});
