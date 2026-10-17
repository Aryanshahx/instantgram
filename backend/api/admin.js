// POST /api/admin  { action, ... }   (v0.13: the admin website at /admin)
// v0.14: login = one long password (Vercel ADMIN_PASSWORD, 16+ letters).
// Needs FIREBASE_SERVICE_ACCOUNT.
import {
  F,
  checkNotice,
  fileKeys,
  login,
  noticeMessages,
  pool,
  postCard,
  requireAdmin,
  str,
  userCard,
} from '../lib/admin.js';
import { HttpError, postHandler } from '../lib/http.js';
import {
  addDoc,
  authDelete,
  authLookup,
  authSetDisabled,
  commitWrites,
  countQuery,
  getDoc,
  listPage,
  patchDoc,
  notSetUp,
  runQuery,
  sendFcm,
  serviceAccount,
} from '../lib/google.js';
import { createMusicUpload, deleteKeys, ensureCors, publicUrl, putFile, putNoticeImage } from '../lib/tigris.js';
import { SOURCES as MUSIC_SOURCES, decodeAudio, libraryFields, musicFileKey } from '../lib/music.js';
import { tokensOf } from './call-push.js';
import { VERSION } from '../lib/version.js';
import {
  DEFAULT_LIMITS,
  GROUP_LABEL,
  KINDS as HI_KINDS,
  checkItem,
  cleanLimits,
  loadLimits,
  pathOf,
  sweep,
  targetFields,
} from '../lib/hi.js';
import {
  CYBERCRIME_URL,
  REPORT_LABEL,
  addStrike,
  clearStrikes,
  closeReports,
  strikeInfo,
  updateTrending,
} from '../lib/safety.js';

const ID = /^[A-Za-z0-9_-]{1,128}$/;
const PAGE = 30;

function id(v, what = 'id') {
  if (typeof v !== 'string' || !ID.test(v)) throw new HttpError(400, `Bad ${what}`);
  return v;
}

const DAY = 86_400_000;

function order(field, dir = 'DESCENDING') {
  return [{ field: { fieldPath: field }, direction: dir }];
}

/** Cursor = the createdAt of the last item (ISO text). */
function startAfter(cursor) {
  if (!cursor) return {};
  const t = Date.parse(cursor);
  if (!Number.isFinite(t)) throw new HttpError(400, 'Bad cursor');
  return { startAt: { values: [F.ts(t)], before: false } };
}

function nextCursor(rows, n) {
  if (rows.length < n) return '';
  const last = rows[rows.length - 1].data.createdAt;
  return typeof last === 'string' ? last : '';
}

async function safeCount(sa, coll, where, opts, fetchFn) {
  try {
    return await countQuery(sa, coll, where, opts, fetchFn);
  } catch (e) {
    console.warn('count', coll, e?.message || e);
    return null;
  }
}

async function verifiedSet(sa, fetchFn) {
  const d = await getDoc(sa, 'config/verified', fetchFn).catch(() => null);
  return new Set(Array.isArray(d?.uids) ? d.uids.filter((x) => typeof x === 'string') : []);
}

// ---------------------------------------------------------------- v0.14

const USER_FILTERS = ['new', 'followers', 'verified', 'banned', 'private', 'online', 'country'];
const REPORT_KINDS = ['post', 'clip', 'comment', 'user'];

function reportCard(r) {
  return {
    id: r.id,
    kind: str(r.data.kind, 10),
    reason: str(r.data.reason, 80),
    message: str(r.data.message, 2000),
    targetId: str(r.data.targetId, 128),
    postId: str(r.data.postId, 128),
    targetUid: str(r.data.targetUid, 128),
    reporterUid: str(r.data.reporterUid, 128),
    reporterUsername: str(r.data.reporterUsername, 40),
    createdAt: r.data.createdAt || null,
  };
}

/** Users by a filter. Pages with [offset] (simple, no extra indexes). */
async function userFilter(filter, { sa, fetchFn, body, verified, card }) {
  const offset = Math.max(0, Math.min(5000, Math.floor(Number(body.offset) || 0)));
  const byIds = async (ids) => {
    const docs = await pool(ids, 8, async (uid) => {
      const d = await getDoc(sa, `users/${uid}`, fetchFn).catch(() => null);
      return d ? { id: uid, data: d } : null;
    });
    return docs.filter(Boolean);
  };
  if (filter === 'verified') {
    const ids = [...verified].slice(offset, offset + PAGE);
    return { users: (await byIds(ids)).map(card), offset: ids.length === PAGE ? offset + PAGE : 0 };
  }
  if (filter === 'online') {
    const rows = await runQuery(sa, { from: [{ collectionId: 'presence' }], where: F.eq('online', F.b(true)), limit: 100 }, '', fetchFn);
    const ids = rows.filter((r) => r.data.hidden !== true).map((r) => r.id).slice(offset, offset + PAGE);
    return { users: (await byIds(ids)).map(card), offset: ids.length === PAGE ? offset + PAGE : 0 };
  }
  const q = { from: [{ collectionId: 'users' }], limit: PAGE, offset };
  if (filter === 'followers') q.orderBy = order('followersCount');
  if (filter === 'banned') q.where = F.eq('banned', F.b(true));
  if (filter === 'private') q.where = F.eq('isPrivate', F.b(true));
  if (filter === 'country') {
    const c = typeof body.country === 'string' ? body.country.trim().toUpperCase() : '';
    if (!/^[A-Z]{2}$/.test(c)) throw new HttpError(400, 'Country: 2 letters, like IN');
    q.where = F.eq('country', F.s(c));
  }
  const rows = await runQuery(sa, q, '', fetchFn);
  return { users: rows.map(card), offset: rows.length === PAGE ? offset + PAGE : 0 };
}

/** Only pictures we saved for notices. */
function noticeImageUrl(v) {
  if (v === undefined || v === null || v === '') return '';
  const base = publicUrl('notice/');
  if (typeof v !== 'string' || !v.startsWith(base) || v.length > 400 || /\.\.|[\s"'<>]/.test(v)) {
    throw new HttpError(400, 'Bad picture');
  }
  return v;
}

/** "data:image/jpeg;base64,..." -> bytes (max 1.5 MB). */
export function decodeJpeg(dataUrl) {
  const m = /^data:image\/jpeg;base64,([A-Za-z0-9+/=]+)$/.exec(typeof dataUrl === 'string' ? dataUrl : '');
  if (!m) throw new HttpError(400, 'Send the picture as JPEG');
  const bytes = Buffer.from(m[1], 'base64');
  if (bytes.length < 100 || bytes[0] !== 0xff || bytes[1] !== 0xd8) throw new HttpError(400, 'Not a JPEG picture');
  if (bytes.length > 1.5 * 1024 * 1024) throw new HttpError(413, 'Picture too big (max 1.5 MB)');
  return bytes;
}

/** Delete-account steps, in order. Every call does a part of one step. */
export const DELETE_STEPS = ['posts', 'moments', 'followers', 'following', 'lists', 'account'];
const SUBS = ['notifications', 'requests', 'blocked', 'private', 'saved', 'reposts'];

async function deleteUserStep(step, uid, { sa, fetchFn, deleteFiles }) {
  const commitAll = async (writes) => {
    for (let i = 0; i < writes.length; i += 450) await commitWrites(sa, writes.slice(i, i + 450), fetchFn);
  };
  if (step === 'posts') {
    const rows = await runQuery(sa, { from: [{ collectionId: 'posts' }], where: F.eq('authorId', F.s(uid)), limit: 15 }, '', fetchFn);
    let files = 0;
    for (const r of rows) {
      const comments = await runQuery(sa, { from: [{ collectionId: 'comments' }], limit: 300 }, `posts/${r.id}`, fetchFn).catch(() => []);
      const keys = fileKeys(r.data, uid);
      for (const c of comments) keys.push(...fileKeys(c.data, c.data.authorId));
      await commitAll([...comments.map((c) => ({ delete: `posts/${r.id}/comments/${c.id}` })), { delete: `posts/${r.id}` }]);
      files += await deleteFiles(keys);
    }
    return { n: rows.length, files, more: rows.length === 15 };
  }
  if (step === 'moments') {
    const rows = await runQuery(sa, { from: [{ collectionId: 'stories' }], where: F.eq('authorId', F.s(uid)), limit: 100 }, '', fetchFn);
    await commitAll(rows.map((r) => ({ delete: `stories/${r.id}` })));
    const files = await deleteFiles(rows.flatMap((r) => fileKeys(r.data, uid)));
    return { n: rows.length, files, more: rows.length === 100 };
  }
  if (step === 'followers' || step === 'following') {
    // the other person's list and counter change too
    const rows = await runQuery(sa, { from: [{ collectionId: step }], limit: 200 }, `users/${uid}`, fetchFn);
    const other = step === 'followers' ? 'following' : 'followers';
    const counter = step === 'followers' ? 'followingCount' : 'followersCount';
    const writes = [];
    for (const r of rows) {
      if (!ID.test(r.id)) continue;
      writes.push({ delete: `users/${r.id}/${other}/${uid}` });
      writes.push({ transform: `users/${r.id}`, transforms: [{ fieldPath: counter, increment: { integerValue: '-1' } }] });
    }
    writes.push(...rows.map((r) => ({ delete: `users/${uid}/${step}/${r.id}` })));
    // a transform on a deleted user would create an empty document: skip those
    const alive = new Set();
    await pool([...new Set(rows.map((r) => r.id).filter((x) => ID.test(x)))], 8, async (o) => {
      if (await getDoc(sa, `users/${o}`, fetchFn).catch(() => null)) alive.add(o);
    });
    await commitAll(writes.filter((w) => !w.transform || alive.has(w.transform.split('/')[1])));
    return { n: rows.length, more: rows.length === 200 };
  }
  if (step === 'lists') {
    let n = 0;
    for (const sub of SUBS) {
      const rows = await runQuery(sa, { from: [{ collectionId: sub }], limit: 300 }, `users/${uid}`, fetchFn).catch(() => []);
      await commitAll(rows.map((r) => ({ delete: `users/${uid}/${sub}/${r.id}` })));
      n += rows.length;
      if (rows.length === 300) return { n, more: true };
    }
    // music update: their AI songs + "original audio" entries
    const songs = await runQuery(sa, { from: [{ collectionId: 'music' }], where: F.eq('ownerUid', F.s(uid)), limit: 100 }, '', fetchFn).catch(() => []);
    if (songs.length) {
      await deleteFiles(songs.map((r) => musicFileKey(r.data)).filter(Boolean));
      await commitAll(songs.filter((r) => ID.test(r.id)).map((r) => ({ delete: `music/${r.id}` })));
      n += songs.length;
      if (songs.length === 100) return { n, more: true };
    }
    return { n, more: false };
  }
  // account: profile, name, phone tokens, settings, online status, login
  const d = await getDoc(sa, `users/${uid}`, fetchFn).catch(() => null);
  const writes = [
    { delete: `pushTokens/${uid}` },
    { delete: `prefs/${uid}` },
    { delete: `presence/${uid}` },
    { delete: `users/${uid}` },
    { transform: 'config/verified', transforms: [{ fieldPath: 'uids', removeAllFromArray: { values: [F.s(uid)] } }] },
  ];
  const name = typeof d?.username === 'string' ? d.username.toLowerCase() : '';
  if (name && ID.test(name)) writes.push({ delete: `usernames/${name}` });
  // v0.0.2: accounts with one login (see api/accounts.js)
  const link = await getDoc(sa, `accountLinks/${uid}`, fetchFn).catch(() => null);
  const owner = typeof link?.owner === 'string' && ID.test(link.owner) ? link.owner : '';
  let keepLogin = false;
  if (owner && owner !== uid) {
    // a linked account: leave the group
    writes.push({ delete: `accountLinks/${uid}` });
    writes.push({
      transform: `accountFamilies/${owner}`,
      transforms: [{ fieldPath: 'members', removeAllFromArray: { values: [F.s(uid)] } }],
    });
  } else if (owner === uid) {
    // the login's own account: other accounts still log in with it
    const fam = await getDoc(sa, `accountFamilies/${uid}`, fetchFn).catch(() => null);
    const others = Array.isArray(fam?.members) ? fam.members.filter((m) => typeof m === 'string' && m !== uid && ID.test(m)) : [];
    const alive = [];
    await pool(others, 5, async (o) => {
      if (await getDoc(sa, `users/${o}`, fetchFn).catch(() => null)) alive.push(o);
    });
    keepLogin = alive.length > 0;
    if (!keepLogin) writes.push({ delete: `accountLinks/${uid}` }, { delete: `accountFamilies/${uid}` });
  }
  await commitAll(writes);
  // profile picture + banner (chat files stay: the other person keeps the chat)
  const own = [d?.photoKey, d?.coverKey].filter(
    (k) => typeof k === 'string' && !k.includes('..') && (k.startsWith(`avatar/${uid}/`) || k.startsWith(`cover/${uid}/`)),
  );
  const files = await deleteFiles([...fileKeys(d || {}, uid), ...own]);
  // kept when other accounts use this email + password (v0.0.2)
  const login = keepLogin ? 'kept' : await authDelete(sa, uid, fetchFn);
  return { n: 1, files, login, more: false };
}

// ---------------------------------------------------------------- actions

export const actions = {
  async stats({ sa, fetchFn, now }) {
    const c = (coll, where, opts) => safeCount(sa, coll, where, opts, fetchFn);
    const [users, users24h, users7d, posts, clips, moments, chats, online, active24h, banned, reports, phones, review] =
      await Promise.all([
        c('users'),
        c('users', F.ge('createdAt', F.ts(now - DAY))),
        c('users', F.ge('createdAt', F.ts(now - 7 * DAY))),
        c('posts'),
        c('posts', F.eq('type', F.s('clip'))),
        c('stories', F.gt('expiresAt', F.ts(now))),
        c('chats'),
        c('presence', F.eq('online', F.b(true))),
        c('presence', F.ge('lastActive', F.ts(now - DAY))),
        c('users', F.eq('banned', F.b(true))),
        c('reports'),
        c('pushTokens'),
        // v0.18: Hyper Intelligence list
        c('moderation', F.eq('open', F.b(true))),
      ]);
    const verified = (await verifiedSet(sa, fetchFn)).size;
    return {
      users,
      users24h,
      users7d,
      posts,
      clips,
      photos: posts != null && clips != null ? posts - clips : null,
      moments,
      chats,
      online,
      active24h,
      banned,
      verified,
      reports,
      phones,
      review,
      version: VERSION,
      at: new Date(now).toISOString(),
    };
  },

  async users({ sa, fetchFn, body }) {
    const q = typeof body.q === 'string' ? body.q.trim().toLowerCase().replace(/^@/, '') : '';
    const verified = await verifiedSet(sa, fetchFn);
    let rows;
    if (q) {
      const found = new Map();
      if (q.includes('@')) {
        for (const r of await runQuery(sa, { from: [{ collectionId: 'users' }], where: F.eq('email', F.s(q)), limit: 10 }, '', fetchFn)) found.set(r.id, r);
      } else {
        const byName = await runQuery(
          sa,
          {
            from: [{ collectionId: 'users' }],
            where: F.and(F.ge('username', F.s(q)), F.le('username', F.s(`${q}\uf8ff`))),
            orderBy: order('username', 'ASCENDING'),
            limit: PAGE,
          },
          '',
          fetchFn,
        );
        for (const r of byName) found.set(r.id, r);
        if (ID.test(body.q.trim()) && body.q.trim().length >= 20) {
          const d = await getDoc(sa, `users/${body.q.trim()}`, fetchFn);
          if (d) found.set(body.q.trim(), { id: body.q.trim(), data: d });
        }
      }
      rows = [...found.values()];
      return { users: rows.map((r) => ({ ...userCard(r.id, r.data), verified: verified.has(r.id) })), cursor: '' };
    }
    const card = (r) => ({ ...userCard(r.id, r.data), verified: verified.has(r.id) });
    const filter = USER_FILTERS.includes(body.filter) ? body.filter : 'new';
    if (filter !== 'new') return userFilter(filter, { sa, fetchFn, body, verified, card });
    rows = await runQuery(
      sa,
      { from: [{ collectionId: 'users' }], orderBy: order('createdAt'), limit: PAGE, ...startAfter(body.cursor) },
      '',
      fetchFn,
    );
    return { users: rows.map(card), cursor: nextCursor(rows, PAGE) };
  },

  async user({ sa, fetchFn, body, now }) {
    const uid = id(body.uid, 'user');
    const d = await getDoc(sa, `users/${uid}`, fetchFn);
    if (!d) throw new HttpError(404, 'User not found');
    const [auth, posts, reports, presence, push, verified, strikes] = await Promise.all([
      authLookup(sa, uid, fetchFn).catch((e) => ({ error: e.message })),
      runQuery(
        sa,
        { from: [{ collectionId: 'posts' }], where: F.eq('authorId', F.s(uid)), orderBy: order('createdAt'), limit: 30 },
        '',
        fetchFn,
      ).catch(() => []),
      runQuery(sa, { from: [{ collectionId: 'reports' }], where: F.eq('targetUid', F.s(uid)), limit: 20 }, '', fetchFn).catch(() => []),
      getDoc(sa, `presence/${uid}`, fetchFn).catch(() => null),
      getDoc(sa, `pushTokens/${uid}`, fetchFn).catch(() => null),
      verifiedSet(sa, fetchFn),
      getDoc(sa, `strikes/${uid}`, fetchFn).catch(() => null),
    ]);
    return {
      // v0.20: strikes in the last 90 days + posting block
      strikes: strikeInfo(strikes, now),
      user: {
        ...userCard(uid, d),
        bio: str(d.bio, 400),
        language: str(d.language, 8),
        verified: verified.has(uid),
      },
      auth: auth && !auth.error
        ? {
            disabled: auth.disabled === true,
            emailVerified: auth.emailVerified === true,
            createdAt: auth.createdAt ? new Date(Number(auth.createdAt)).toISOString() : null,
            lastLoginAt: auth.lastLoginAt ? new Date(Number(auth.lastLoginAt)).toISOString() : null,
          }
        : { error: auth?.error || 'not found' },
      lastActive: presence?.lastActive || null,
      online: presence?.online === true && presence?.hidden !== true,
      phones: Array.isArray(push?.tokens) ? push.tokens.length : 0,
      posts: posts.map((r) => postCard(r.id, r.data)),
      reports: reports.map((r) => ({ id: r.id, ...r.data })),
    };
  },

  async posts({ sa, fetchFn, body }) {
    const type = ['all', 'clip', 'photo', 'moment'].includes(body.type) ? body.type : 'all';
    if (type === 'moment') {
      const rows = await runQuery(
        sa,
        { from: [{ collectionId: 'stories' }], orderBy: order('createdAt'), limit: PAGE, ...startAfter(body.cursor) },
        '',
        fetchFn,
      );
      return { posts: rows.map((r) => postCard(r.id, r.data, 'moment')), cursor: nextCursor(rows, PAGE) };
    }
    const q = { from: [{ collectionId: 'posts' }], orderBy: order('createdAt'), limit: PAGE, ...startAfter(body.cursor) };
    if (type !== 'all') q.where = F.eq('type', F.s(type));
    const rows = await runQuery(sa, q, '', fetchFn);
    return { posts: rows.map((r) => postCard(r.id, r.data)), cursor: nextCursor(rows, PAGE) };
  },

  async post({ sa, fetchFn, body }) {
    const pid = id(body.id, 'post');
    const moment = body.kind === 'moment';
    const d = await getDoc(sa, `${moment ? 'stories' : 'posts'}/${pid}`, fetchFn);
    if (!d) throw new HttpError(404, 'Not found (maybe deleted)');
    const comments = moment
      ? []
      : await runQuery(sa, { from: [{ collectionId: 'comments' }], orderBy: order('createdAt'), limit: 100 }, `posts/${pid}`, fetchFn).catch(() => []);
    const media = Array.isArray(d.media) && d.media.length
      ? d.media.map((m) => ({ url: str(m?.url, 600), thumb: str(m?.thumbUrl, 600), video: m?.type === 'video' }))
      : [{ url: str(d.mediaUrl, 600), thumb: str(d.thumbUrl, 600), video: d.type === 'clip' || d.type === 'video' }];
    return {
      post: { ...postCard(pid, d, moment ? 'moment' : 'post'), media },
      comments: comments.map((r) => ({
        id: r.id,
        authorId: str(r.data.authorId, 128),
        authorUsername: str(r.data.authorUsername, 40),
        text: str(r.data.text, 600),
        imageUrl: str(r.data.imageUrl || r.data.gifUrl || '', 600),
        likes: Number(r.data.likesCount) || 0,
        createdAt: r.data.createdAt || null,
      })),
    };
  },

  async deletePost({ sa, fetchFn, body, deleteFiles }) {
    const pid = id(body.id, 'post');
    if (body.kind === 'moment') {
      const d = await getDoc(sa, `stories/${pid}`, fetchFn);
      if (!d) return { deleted: false };
      await commitWrites(sa, [{ delete: `stories/${pid}` }], fetchFn);
      const files = await deleteFiles(fileKeys(d, d.authorId));
      return { deleted: true, files };
    }
    const d = await getDoc(sa, `posts/${pid}`, fetchFn);
    if (!d) return { deleted: false };
    // comments first (max 300 here; more are left hidden without the post)
    const comments = await runQuery(sa, { from: [{ collectionId: 'comments' }], limit: 300 }, `posts/${pid}`, fetchFn).catch(() => []);
    // music update: other posts may use this post's song ("use this audio")
    const shared = String(d.musicId || '').startsWith('o_') ? d.audioKey : null;
    const keys = fileKeys(d, d.authorId).filter((k) => k !== shared);
    for (const c of comments) keys.push(...fileKeys(c.data, c.data.authorId));
    const writes = comments.map((c) => ({ delete: `posts/${pid}/comments/${c.id}` }));
    writes.push({ delete: `posts/${pid}` });
    if (typeof d.authorId === 'string' && ID.test(d.authorId)) {
      writes.push({
        transform: `users/${d.authorId}`,
        transforms: [{ fieldPath: 'postsCount', increment: { integerValue: '-1' } }],
      });
    }
    for (let i = 0; i < writes.length; i += 450) await commitWrites(sa, writes.slice(i, i + 450), fetchFn);
    const files = await deleteFiles(keys);
    return { deleted: true, comments: comments.length, files };
  },

  async deleteComment({ sa, fetchFn, body, deleteFiles }) {
    const pid = id(body.postId, 'post');
    const cid = id(body.id, 'comment');
    const c = await getDoc(sa, `posts/${pid}/comments/${cid}`, fetchFn);
    if (!c) return { deleted: false };
    const writes = [
      { delete: `posts/${pid}/comments/${cid}` },
      { transform: `posts/${pid}`, transforms: [{ fieldPath: 'commentsCount', increment: { integerValue: '-1' } }] },
    ];
    await commitWrites(sa, writes, fetchFn);
    const files = await deleteFiles(fileKeys(c, c.authorId));
    return { deleted: true, files };
  },

  async reports({ sa, fetchFn, body }) {
    // v0.14: filter by type / reason (looks at the newest 200, no index)
    const kind = REPORT_KINDS.includes(body.kind) ? body.kind : '';
    const reason = typeof body.reason === 'string' ? body.reason.trim().toLowerCase().slice(0, 80) : '';
    if (kind || reason) {
      const all = await runQuery(sa, { from: [{ collectionId: 'reports' }], orderBy: order('createdAt'), limit: 200 }, '', fetchFn);
      const hits = all.filter(
        (r) => (!kind || r.data.kind === kind) && (!reason || String(r.data.reason || '').toLowerCase().includes(reason)),
      );
      return { reports: hits.slice(0, 100).map(reportCard), cursor: '', scanned: all.length, total: hits.length };
    }
    const rows = await runQuery(
      sa,
      { from: [{ collectionId: 'reports' }], orderBy: order('createdAt'), limit: PAGE, ...startAfter(body.cursor) },
      '',
      fetchFn,
    );
    return {
      reports: rows.map(reportCard),
      cursor: nextCursor(rows, PAGE),
    };
  },

  async resolveReport({ sa, fetchFn, body }) {
    await commitWrites(sa, [{ delete: `reports/${id(body.id, 'report')}` }], fetchFn);
    return { done: true };
  },

  async ban({ sa, fetchFn, body, admin }) {
    const uid = id(body.uid, 'user');
    if (uid === admin.uid) throw new HttpError(400, "You can't block yourself");
    const on = body.on === true;
    const d = await getDoc(sa, `users/${uid}`, fetchFn);
    if (!d) throw new HttpError(404, 'User not found');
    await authSetDisabled(sa, uid, on, fetchFn);
    await commitWrites(
      sa,
      [{ update: `users/${uid}`, fields: { banned: on, bannedAt: on ? new Date() : null }, mustExist: true }],
      fetchFn,
    );
    return { uid, banned: on };
  },

  async verify({ sa, fetchFn, body }) {
    const uid = id(body.uid, 'user');
    const on = body.on === true;
    const value = { arrayValue: { values: [{ stringValue: uid }] } };
    await commitWrites(
      sa,
      [
        {
          transform: 'config/verified',
          transforms: [on ? { fieldPath: 'uids', appendMissingElements: value.arrayValue } : { fieldPath: 'uids', removeAllFromArray: value.arrayValue }],
        },
      ],
      fetchFn,
    );
    return { uid, verified: on };
  },

  /** v0.14: a picture for a notice (sent once, then used by every page). */
  async noticeImage({ body, saveImage }) {
    const bytes = decodeJpeg(body.image);
    const { url } = await saveImage(bytes);
    return { url };
  },

  // ---------------- music (library, AI songs, original audio) ----------------

  /** Songs of one kind, newest first. */
  async musicList({ sa, fetchFn, body }) {
    const source = MUSIC_SOURCES.includes(body.source) ? body.source : 'library';
    const rows = await runQuery(sa, { from: [{ collectionId: 'music' }], where: F.eq('source', F.s(source)), limit: 300 }, '', fetchFn);
    const items = rows
      .map((r) => ({
        id: r.id,
        source,
        title: str(r.data.title, 80),
        artist: str(r.data.artist, 80),
        mood: str(r.data.mood, 20),
        url: typeof r.data.url === 'string' ? r.data.url : '',
        durationMs: Number(r.data.durationMs) || 0,
        uses: Number(r.data.uses) || 0,
        hidden: r.data.hidden === true,
        ownerUid: typeof r.data.ownerUid === 'string' ? r.data.ownerUid : '',
        prompt: str(r.data.prompt, 300),
        createdAt: r.data.createdAt || null,
      }))
      .sort((a, b) => String(b.createdAt || '').localeCompare(String(a.createdAt || '')));
    return { items };
  },

  /** Big files: the page uploads straight to the bucket with this link. */
  async musicUploadUrl({ body, makeMusicUpload, setCors }) {
    const cors = await setCors();
    const up = await makeMusicUpload({ contentType: body.contentType, size: body.size });
    return { ...up, cors };
  },

  /** Adds a library song: [file] (data url, small files) or [key] from musicUploadUrl. */
  async musicAdd({ sa, fetchFn, body, now, saveFile }) {
    const f = libraryFields(body);
    let key;
    let url;
    if (body.file) {
      const { bytes, type, ext } = decodeAudio(body.file);
      key = `music/lib/${now}-${Math.random().toString(36).slice(2, 10)}.${ext}`;
      ({ url } = await saveFile(key, bytes, type));
    } else {
      key = typeof body.key === 'string' ? body.key : '';
      if (!/^music\/lib\/[A-Za-z0-9._-]{5,120}$/.test(key)) throw new HttpError(400, 'Upload the file first');
      url = publicUrl(key);
    }
    const mid = `lib_${now.toString(36)}${Math.random().toString(36).slice(2, 8)}`;
    await patchDoc(sa, `music/${mid}`, {
      source: 'library', ownerUid: '', ...f, url, key, uses: 0, hidden: false, createdAt: new Date(now),
    }, {}, fetchFn);
    return { id: mid, url };
  },

  /** Rename / hide / show a song. */
  async musicEdit({ sa, fetchFn, body }) {
    const mid = id(body.id, 'song');
    const d = await getDoc(sa, `music/${mid}`, fetchFn);
    if (!d) throw new HttpError(404, 'Song not found');
    const fields = {};
    if (typeof body.hidden === 'boolean') fields.hidden = body.hidden;
    if (d.source === 'library' && body.title !== undefined) {
      Object.assign(fields, libraryFields({ ...d, ...body }));
    }
    if (!Object.keys(fields).length) throw new HttpError(400, 'Nothing to change');
    await patchDoc(sa, `music/${mid}`, fields, {}, fetchFn);
    return { ok: true };
  },

  /** Deletes a song for ever (posts using it become silent). Hide keeps them. */
  async musicDelete({ sa, fetchFn, body, deleteFiles }) {
    const mid = id(body.id, 'song');
    if (body.confirm !== 'DELETE') throw new HttpError(400, 'Type DELETE to confirm');
    const d = await getDoc(sa, `music/${mid}`, fetchFn);
    if (!d) throw new HttpError(404, 'Song not found');
    const k = musicFileKey(d);
    const files = k ? await deleteFiles([k]) : 0;
    await commitWrites(sa, [{ delete: `music/${mid}` }], fetchFn);
    return { ok: true, files };
  },

  /** v0.14: deletes an account step by step. The page calls again with
   *  the returned [step] until [done]. */
  async deleteUser({ sa, fetchFn, body, deleteFiles }) {
    const uid = id(body.uid, 'user');
    if (body.confirm !== 'DELETE') throw new HttpError(400, 'Type DELETE to confirm');
    let step = DELETE_STEPS.includes(body.step) ? body.step : DELETE_STEPS[0];
    if (step === DELETE_STEPS[0] && !(await getDoc(sa, `users/${uid}`, fetchFn))) {
      throw new HttpError(404, 'User not found');
    }
    const r = await deleteUserStep(step, uid, { sa, fetchFn, deleteFiles });
    if (!r.more) {
      const i = DELETE_STEPS.indexOf(step);
      step = i + 1 < DELETE_STEPS.length ? DELETE_STEPS[i + 1] : '';
    }
    return { ...r, step, done: step === '' };
  },

  /** One person: notification in the app + phone push. Everyone: phone
   *  push, 150 phones per call (the page calls again with [page]). */
  async notice({ sa, fetchFn, body, now }) {
    const { title, text } = checkNotice(body);
    const image = noticeImageUrl(body.imageUrl);
    const send = (tokens) => pool(noticeMessages(tokens, title, text, image), 10, (m) => sendFcm(sa, m, fetchFn));
    if (body.to === 'all') {
      const page = await listPage(sa, 'pushTokens', { pageSize: 150, pageToken: typeof body.page === 'string' ? body.page : '', fields: ['tokens'] }, fetchFn);
      const tokens = [];
      for (const d of page.docs) {
        const list = (Array.isArray(d.data.tokens) ? d.data.tokens : []).filter((t) => typeof t === 'string' && t.length > 20).slice(-5);
        tokens.push(...list);
      }
      const ok = await send(tokens);
      return { people: page.docs.length, sent: ok.filter(Boolean).length, failed: ok.filter((x) => !x).length, page: page.next, done: !page.next };
    }
    const uid = id(body.to, 'user');
    const nid = await addDoc(
      sa,
      `users/${uid}/notifications`,
      { type: 'notice', fromUid: '', fromUsername: 'InstantGram', fromPhotoUrl: '', postId: '', postThumb: image, text: title === 'InstantGram' ? text : `${title}: ${text}`, read: false, createdAt: new Date(now) },
      fetchFn,
    );
    const ok = await send(await tokensOf(sa, uid, fetchFn));
    return { people: 1, sent: ok.filter(Boolean).length, failed: ok.filter((x) => !x).length, id: nid, done: true };
  },
};

// ------------------------------------------- v0.18: Hyper Intelligence

const HI_STATES = ['review', 'hidden', 'unchecked'];
export const HI_DECISIONS = ['approve', 'blur', 'delete', 'strike', 'ban', 'child'];
const ALL_LABELS = { ...GROUP_LABEL, ...REPORT_LABEL };

function hiCard(r) {
  const d = r.data;
  return {
    id: r.id,
    kind: str(d.kind, 10),
    targetId: str(d.targetId, 128),
    postId: str(d.postId, 128),
    authorId: str(d.authorId, 128),
    authorUsername: str(d.authorUsername, 40),
    state: str(d.state, 12),
    reasons: Array.isArray(d.reasons) ? d.reasons.filter((x) => typeof x === 'string') : [],
    scores: d.scores && typeof d.scores === 'object' ? d.scores : {},
    urgent: d.urgent === true,
    text: str(d.text, 400),
    preview: str(d.preview, 600),
    images: Number(d.images) || 0,
    error: str(d.error, 300),
    source: str(d.source, 10),
    at: d.at || null,
    // v0.20: reports from people
    reports: Number(d.reports) || 0,
    reportScore: Number(d.reportScore) || 0,
    reportReasons: d.reportReasons && typeof d.reportReasons === 'object' ? d.reportReasons : {},
  };
}

/** moderation doc -> what it points to */
function hiTarget(m) {
  const kind = m.kind === 'clip' ? 'post' : m.kind;
  if (!HI_KINDS.includes(kind)) throw new HttpError(400, 'Bad item');
  const targetId = id(m.targetId, 'item');
  const postId = kind === 'comment' ? id(m.postId, 'post') : '';
  return { kind, targetId, postId };
}

Object.assign(actions, {
  // newest 200 open items, filters: state, kind, reason
  async hiList({ sa, fetchFn, body }) {
    const state = HI_STATES.includes(body.state) ? body.state : '';
    const kind = ['post', 'clip', 'moment', 'comment'].includes(body.kind) ? body.kind : '';
    const reason = Object.hasOwn(ALL_LABELS, body.reason) ? body.reason : '';
    const rows = await runQuery(sa, { from: [{ collectionId: 'moderation' }], where: F.eq('open', F.b(true)), limit: 200 }, '', fetchFn);
    const all = rows.map(hiCard).sort((a, b) => (b.urgent - a.urgent) || String(b.at || '').localeCompare(String(a.at || '')));
    const hits = all.filter((x) => (!state || x.state === state) && (!kind || x.kind === kind) && (!reason || x.reasons.includes(reason)));
    const count = (st) => all.filter((x) => x.state === st).length;
    return {
      items: hits.slice(0, 100),
      total: hits.length,
      counts: { all: all.length, review: count('review'), hidden: count('hidden'), unchecked: count('unchecked'), urgent: all.filter((x) => x.urgent).length },
      labels: ALL_LABELS,
      openai: !!process.env.OPENAI_API_KEY,
    };
  },

  // approve = show normally, blur = stays blurred for good,
  // delete, strike = delete + 1 strike, ban = delete + block the account
  async hiDecide({ sa, fetchFn, body, admin, now, deleteFiles, saveImage }) {
    const mid = id(body.id, 'item');
    const decision = HI_DECISIONS.includes(body.decision) ? body.decision : '';
    if (!decision) throw new HttpError(400, 'Bad decision');
    const m = await getDoc(sa, `moderation/${mid}`, fetchFn);
    if (!m) throw new HttpError(404, 'Already done');
    const { kind, targetId, postId } = hiTarget(m);
    const done = { open: false, decision, decidedAt: new Date(now) };
    const out = { id: mid, decision, authorId: str(m.authorId, 128), authorUsername: str(m.authorUsername, 40) };
    if (decision === 'approve' || decision === 'blur') {
      const st = decision === 'approve' ? 'ok' : 'blurred';
      const fields = targetFields(kind, st, decision === 'approve' ? [] : Array.isArray(m.reasons) ? m.reasons : [], now);
      try {
        await commitWrites(sa, [{ update: pathOf(kind, targetId, postId), fields, mustExist: true }], fetchFn);
      } catch {
        out.gone = true; // deleted in the meantime
      }
      await commitWrites(sa, [{ update: `moderation/${mid}`, fields: done }], fetchFn);
      out.thanked = (await closeReports(sa, mid, { fetchFn, now })).told;
      return out;
    }
    const ctx = { sa, fetchFn, admin, now, deleteFiles, saveImage };
    out.deleted = kind === 'comment'
      ? (await actions.deleteComment({ ...ctx, body: { postId, id: targetId } })).deleted
      : (await actions.deletePost({ ...ctx, body: { id: targetId, kind: kind === 'moment' ? 'moment' : 'post' } })).deleted;
    const uid = m.authorId;
    if (decision === 'strike' && typeof uid === 'string' && ID.test(uid)) {
      // v0.20: 1 = warning, 2 = no posting for 7 days, 3 = the page asks to ban
      const reason = ALL_LABELS[(m.reasons || [])[0]] || '';
      const r = await addStrike(sa, uid, { reason, fetchFn, now });
      out.strikes = r.strikes;
      out.blockUntil = r.blockUntil;
      out.askBan = r.askBan;
    }
    // v0.20: child safety = delete + ban + report to cybercrime.gov.in
    if (decision === 'child') out.cybercrime = CYBERCRIME_URL;
    if ((decision === 'ban' || decision === 'child') && typeof uid === 'string' && ID.test(uid)) {
      try {
        await actions.ban({ ...ctx, body: { uid, on: true } });
        out.banned = true;
      } catch (e) {
        out.banned = false;
        out.banError = String(e?.message || e);
      }
    }
    await commitWrites(sa, [{ update: `moderation/${mid}`, fields: done }], fetchFn);
    out.thanked = (await closeReports(sa, mid, { fetchFn, now })).told;
    return out;
  },

  // v0.20: strikes from the Users page
  async strike({ sa, fetchFn, body, now }) {
    const uid = id(body.uid, 'user');
    if (!(await getDoc(sa, `users/${uid}`, fetchFn))) throw new HttpError(404, 'User not found');
    return addStrike(sa, uid, { reason: str(body.reason, 80), fetchFn, now });
  },

  async clearStrikes({ sa, fetchFn, body }) {
    return clearStrikes(sa, id(body.uid, 'user'), { fetchFn });
  },

  // v0.20: Child safety from a report / post: delete + ban the owner.
  // The page then opens cybercrime.gov.in (and the email template).
  async childSafety({ sa, fetchFn, body, admin, now, deleteFiles, saveImage }) {
    const ctx = { sa, fetchFn, admin, now, deleteFiles, saveImage };
    const out = { cybercrime: CYBERCRIME_URL, deleted: false, banned: false };
    let uid = typeof body.uid === 'string' && ID.test(body.uid) ? body.uid : '';
    if (body.kind === 'comment') {
      const pid = id(body.postId, 'post');
      const cid = id(body.id, 'comment');
      const c = await getDoc(sa, `posts/${pid}/comments/${cid}`, fetchFn);
      if (c && !uid) uid = str(c.authorId, 128);
      out.deleted = (await actions.deleteComment({ ...ctx, body: { postId: pid, id: cid } })).deleted;
    } else if (body.id) {
      const pid = id(body.id, 'post');
      const coll = body.kind === 'moment' ? 'stories' : 'posts';
      const d = await getDoc(sa, `${coll}/${pid}`, fetchFn);
      if (d && !uid) uid = str(d.authorId, 128);
      out.deleted = (await actions.deletePost({ ...ctx, body: { id: pid, kind: body.kind === 'moment' ? 'moment' : 'post' } })).deleted;
    }
    if (uid && ID.test(uid) && uid !== admin.uid) {
      try {
        await actions.ban({ ...ctx, body: { uid, on: true } });
        out.banned = true;
      } catch (e) {
        out.banError = String(e?.message || e);
      }
    }
    out.uid = uid;
    return out;
  },

  // v0.20: trending list now (also daily + on view milestones)
  async trending({ sa, fetchFn, now }) {
    return updateTrending(sa, { fetchFn, now });
  },

  // check one item again now
  async hiRecheck({ sa, fetchFn, body, now }) {
    const mid = id(body.id, 'item');
    const m = await getDoc(sa, `moderation/${mid}`, fetchFn);
    if (!m) throw new HttpError(404, 'Already done');
    const t = hiTarget(m);
    const d = await getDoc(sa, pathOf(t.kind, t.targetId, t.postId), fetchFn);
    if (!d) {
      await commitWrites(sa, [{ update: `moderation/${mid}`, fields: { open: false, decision: 'gone', decidedAt: new Date(now) } }], fetchFn);
      return { state: 'gone' };
    }
    const r = await checkItem(sa, { kind: t.kind, id: t.targetId, postId: t.postId, doc: { ...d, modState: 'unchecked' }, source: 'admin', now }, { fetchFn });
    if (r.state === 'ok') await commitWrites(sa, [{ update: `moderation/${mid}`, fields: { open: false, state: 'ok', decision: 'ok', decidedAt: new Date(now) } }], fetchFn);
    return r;
  },

  // runs when the admin website opens + "Check now"
  async hiSweep({ sa, fetchFn, now }) {
    return sweep(sa, { limit: 12, now, fetchFn });
  },

  // limits: get, or save { limits: { sexual: { blur, hide }, ... } }
  async hiConfig({ sa, fetchFn, body, now }) {
    if (body.limits && typeof body.limits === 'object') {
      const limits = cleanLimits(body.limits);
      await commitWrites(sa, [{ update: 'config/moderation', fields: { limits, updatedAt: new Date(now) } }], fetchFn);
      return { limits, defaults: DEFAULT_LIMITS, labels: GROUP_LABEL, saved: true };
    }
    return { limits: await loadLimits(sa, fetchFn), defaults: DEFAULT_LIMITS, labels: GROUP_LABEL };
  },
});

export async function handle(
  req,
  body,
  { sa = serviceAccount(), fetchFn = fetch, password = process.env.ADMIN_PASSWORD, wait, now = Date.now(), deleteFiles = deleteKeys, saveImage = putNoticeImage, saveFile = putFile, makeMusicUpload = createMusicUpload, setCors = ensureCors } = {},
) {
  const action = typeof body.action === 'string' ? body.action : '';
  // the only action without a login
  // (login time = the real clock; [now] is only for data)
  if (action === 'login') return login(body.password, { raw: password, wait });
  const admin = await requireAdmin(req, { raw: password });
  if (action === 'me') return { ready: !!sa };
  const fn = Object.hasOwn(actions, action) ? actions[action] : null;
  if (!fn) throw new HttpError(400, 'Unknown action');
  if (!sa) throw notSetUp('The admin website');
  return fn({ sa, fetchFn, body, admin, now, deleteFiles, saveImage, saveFile, makeMusicUpload, setCors });
}

export default postHandler((req, body) => handle(req, body));
