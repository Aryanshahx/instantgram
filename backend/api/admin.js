// POST /api/admin  { action, ... }   (v0.13: the admin website at /admin)
// Login: only ADMIN emails (techlabs.hyper@gmail.com + Vercel ADMIN_EMAILS),
// with a verified email. Needs FIREBASE_SERVICE_ACCOUNT (+ FIREBASE_API_KEY
// if the key from the app does not work for servers).
import {
  F,
  checkNotice,
  fileKeys,
  login,
  noticeMessages,
  pool,
  postCard,
  refresh,
  requireAdmin,
  sendVerifyEmail,
  str,
  userCard,
} from '../lib/admin.js';
import { HttpError, postHandler } from '../lib/http.js';
import {
  addDoc,
  authLookup,
  authSetDisabled,
  commitWrites,
  countQuery,
  getDoc,
  listPage,
  notSetUp,
  runQuery,
  sendFcm,
  serviceAccount,
} from '../lib/google.js';
import { deleteKeys } from '../lib/tigris.js';
import { tokensOf } from './call-push.js';

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

// ---------------------------------------------------------------- actions

export const actions = {
  async stats({ sa, fetchFn, now }) {
    const c = (coll, where, opts) => safeCount(sa, coll, where, opts, fetchFn);
    const [users, users24h, users7d, posts, clips, moments, chats, online, active24h, banned, reports, phones] =
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
    rows = await runQuery(
      sa,
      { from: [{ collectionId: 'users' }], orderBy: order('createdAt'), limit: PAGE, ...startAfter(body.cursor) },
      '',
      fetchFn,
    );
    return {
      users: rows.map((r) => ({ ...userCard(r.id, r.data), verified: verified.has(r.id) })),
      cursor: nextCursor(rows, PAGE),
    };
  },

  async user({ sa, fetchFn, body }) {
    const uid = id(body.uid, 'user');
    const d = await getDoc(sa, `users/${uid}`, fetchFn);
    if (!d) throw new HttpError(404, 'User not found');
    const [auth, posts, reports, presence, push, verified] = await Promise.all([
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
    ]);
    return {
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
    const keys = fileKeys(d, d.authorId);
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
    const rows = await runQuery(
      sa,
      { from: [{ collectionId: 'reports' }], orderBy: order('createdAt'), limit: PAGE, ...startAfter(body.cursor) },
      '',
      fetchFn,
    );
    return {
      reports: rows.map((r) => ({
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
      })),
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

  /** One person: notification in the app + phone push. Everyone: phone
   *  push, 150 phones per call (the page calls again with [page]). */
  async notice({ sa, fetchFn, body, now }) {
    const { title, text } = checkNotice(body);
    const send = (tokens) => pool(noticeMessages(tokens, title, text), 10, (m) => sendFcm(sa, m, fetchFn));
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
      { type: 'notice', fromUid: '', fromUsername: 'InstantGram', fromPhotoUrl: '', postId: '', postThumb: '', text: title === 'InstantGram' ? text : `${title}: ${text}`, read: false, createdAt: new Date(now) },
      fetchFn,
    );
    const ok = await send(await tokensOf(sa, uid, fetchFn));
    return { people: 1, sent: ok.filter(Boolean).length, failed: ok.filter((x) => !x).length, id: nid, done: true };
  },
};

export async function handle(req, body, { sa = serviceAccount(), fetchFn = fetch, verify, admins, now = Date.now(), deleteFiles = deleteKeys } = {}) {
  const action = typeof body.action === 'string' ? body.action : '';
  // no login needed for these three
  if (action === 'login') return login(body.email, body.password, { fetchFn, admins });
  if (action === 'refresh') return refresh(body.refreshToken, { fetchFn, admins });
  if (action === 'sendVerify') return sendVerifyEmail(body.idToken, { fetchFn });
  const admin = await requireAdmin(req, { verify, admins });
  if (action === 'me') return { email: admin.email, ready: !!sa };
  const fn = Object.hasOwn(actions, action) ? actions[action] : null;
  if (!fn) throw new HttpError(400, 'Unknown action');
  if (!sa) throw notSetUp('The admin website');
  return fn({ sa, fetchFn, body, admin, now, deleteFiles });
}

export default postHandler((req, body) => handle(req, body));
