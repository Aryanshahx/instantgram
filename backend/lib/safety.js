// v0.20 Hyper Intelligence, part 2: smarter reports, strikes, trending.
//
// Reports: the app saves reports/{id} and then calls /api/hi
//   { action: 'report', reportId }. Each person counts once per item:
//   accounts older than 7 days count 1, newer ones 0.5.
//   3 points -> blurred + Review list, 6 points -> hidden until the admin
//   checks it. "Child safety" -> hidden at once (1 report).
// Strikes (strikes/{uid}): last 90 days only. 1 = warning,
//   2 = no posting for 7 days, 3 = the admin is asked to ban.
// Trending (config/trending): best posts / clips of the last 48 hours.
import { HttpError } from './http.js';
import { addDoc, commitWrites, getDoc, runQuery } from './google.js';
import { modId, pathOf, targetFields } from './hi.js';

export const DAY = 86_400_000;
export const BLUR_AT = 3;
export const HIDE_AT = 6;
export const STRIKE_DAYS = 90;
export const BLOCK_DAYS = 7;
export const CYBERCRIME_URL = 'https://cybercrime.gov.in';

/** Extra reason labels (next to the OpenAI groups). */
export const REPORT_LABEL = { reported: 'Reported by people', child: 'Child safety (reported)' };

const ID = /^[A-Za-z0-9_-]{1,128}$/;
const s = (v, n = 200) => (typeof v === 'string' ? v.slice(0, n) : '');

function ms(v) {
  if (v instanceof Date) return v.getTime();
  if (typeof v === 'number') return v;
  const t = Date.parse(String(v || ''));
  return Number.isFinite(t) ? t : 0;
}

export function isChildReason(reason) {
  return /child/i.test(String(reason || ''));
}

/** 1 for accounts older than 7 days, else 0.5. */
export function reportWeight(user, now) {
  const at = ms(user?.createdAt);
  return at > 0 && now - at >= 7 * DAY ? 1 : 0.5;
}

/** Points -> new state (never lower than [current]). */
export function stateFor(score, child, current) {
  const rank = { ok: 0, pending: 0, unchecked: 0, blurred: 1, review: 1, hidden: 2 };
  let want = 'ok';
  if (child || score >= HIDE_AT) want = 'hidden';
  else if (score >= BLUR_AT) want = 'review';
  const cur = Object.hasOwn(rank, current) ? current : 'ok';
  return rank[want] > rank[cur] ? want : cur;
}

/** Comment fields -> one state word. */
function commentState(d) {
  if (d.hidden === true) return 'hidden';
  return d.sensitive === true ? 'review' : 'ok';
}

/**
 * One report -> counted on its item.
 * -> { counted, score, reports, state }
 */
export async function handleReport(sa, uid, reportId, { fetchFn = fetch, now = Date.now() } = {}) {
  if (typeof reportId !== 'string' || !ID.test(reportId)) throw new HttpError(400, 'Bad report');
  const r = await getDoc(sa, `reports/${reportId}`, fetchFn);
  if (!r) throw new HttpError(404, 'Report not found');
  if (r.reporterUid !== uid) throw new HttpError(403, 'Not your report');
  if (!['post', 'clip', 'comment'].includes(r.kind)) return { counted: false };
  const kind = r.kind === 'comment' ? 'comment' : 'post';
  const targetId = s(r.targetId, 128);
  const postId = kind === 'comment' ? s(r.postId, 128) : '';
  if (!ID.test(targetId) || (kind === 'comment' && !ID.test(postId))) return { counted: false };
  const path = pathOf(kind, targetId, postId);
  const d = await getDoc(sa, path, fetchFn);
  if (!d) return { counted: false, gone: true };
  if (d.authorId === uid) return { counted: false };
  const mid = modId(kind, targetId, postId);
  const tally = (await getDoc(sa, `reportTally/${mid}`, fetchFn)) || {};
  const by = tally.by && typeof tally.by === 'object' ? { ...tally.by } : {};
  const child = tally.child === true || isChildReason(r.reason);
  const already = Object.hasOwn(by, uid);
  if (!already) {
    const user = await getDoc(sa, `users/${uid}`, fetchFn).catch(() => null);
    by[uid] = reportWeight(user, now);
  }
  const score = Object.values(by).reduce((a, b) => a + (Number(b) || 0), 0);
  const reports = Object.keys(by).length;
  const reasons = { ...(tally.reasons && typeof tally.reasons === 'object' ? tally.reasons : {}) };
  const why = s(r.reason, 80) || 'Other';
  if (!already) reasons[why] = (Number(reasons[why]) || 0) + 1;
  const current = kind === 'comment' ? commentState(d) : s(d.modState, 12) || 'ok';
  const state = stateFor(score, child, current);
  const writes = [{ update: `reportTally/${mid}`, fields: { by, score, reports, reasons, child, kind, updatedAt: new Date(now) } }];
  if (state !== current || (state !== 'ok' && !already)) {
    const tags = child ? ['child', 'reported'] : ['reported'];
    const old = Array.isArray(d.modReasons) ? d.modReasons.filter((x) => typeof x === 'string') : [];
    const all = [...new Set([...tags, ...old])];
    if (state !== current) writes.push({ update: path, fields: targetFields(kind, state, all, now), mustExist: true });
    if (state !== 'ok') {
      writes.push({
        update: `moderation/${mid}`,
        fields: {
          kind: kind === 'post' ? (d.type === 'clip' ? 'clip' : 'post') : 'comment',
          targetId,
          postId,
          authorId: s(d.authorId, 128),
          authorUsername: s(d.authorUsername, 40),
          text: s(d.text ?? d.caption, 400),
          preview: previewOf(d),
          state,
          reasons: all,
          reports,
          reportScore: score,
          reportReasons: reasons,
          urgent: child || state === 'hidden',
          open: true,
          source: 'reports',
          at: new Date(now),
          error: '',
        },
      });
    }
  }
  try {
    await commitWrites(sa, writes, fetchFn);
  } catch (e) {
    console.warn('report save', e?.message || e);
  }
  return { counted: !already, score, reports, state };
}

function previewOf(d) {
  if (typeof d.thumbUrl === 'string' && d.thumbUrl) return d.thumbUrl;
  for (const m of Array.isArray(d.media) ? d.media : []) {
    const c = m?.type === 'video' ? m.thumbUrl : m?.url;
    if (typeof c === 'string' && c.startsWith('https://')) return c;
  }
  for (const k of ['mediaUrl', 'imageUrl', 'gifUrl']) {
    if (typeof d[k] === 'string' && d[k].startsWith('https://') && !/\.(mp4|mov|m3u8)(\?|$)/i.test(d[k])) return d[k];
  }
  return '';
}

/** After the admin decided: reporters get "Thank you", the count starts again. */
export async function closeReports(sa, mid, { fetchFn = fetch, now = Date.now() } = {}) {
  const t = await getDoc(sa, `reportTally/${mid}`, fetchFn).catch(() => null);
  if (!t) return { told: 0 };
  const uids = Object.keys(t.by && typeof t.by === 'object' ? t.by : {}).filter((u) => ID.test(u)).slice(0, 100);
  let told = 0;
  for (const u of uids) {
    try {
      await addDoc(sa, `users/${u}/notifications`, {
        type: 'notice',
        fromUid: '',
        fromUsername: 'InstantGram',
        fromPhotoUrl: '',
        postId: '',
        postThumb: '',
        text: 'We reviewed your report. Thank you for helping keep InstantGram safe.',
        read: false,
        createdAt: new Date(now),
      }, fetchFn);
      told++;
    } catch (e) {
      console.warn('report thanks', e?.message || e);
    }
  }
  await commitWrites(sa, [{ delete: `reportTally/${mid}` }], fetchFn).catch(() => {});
  return { told };
}

// ------------------------------------------------------------ strikes

/** Strike times still counting (last 90 days). Old docs: count + lastAt. */
export function activeStrikes(doc, now) {
  if (!doc) return [];
  let list = Array.isArray(doc.at) ? doc.at.map(ms).filter((t) => t > 0) : [];
  if (!list.length && Number(doc.count) > 0) {
    const last = ms(doc.lastAt) || now;
    list = Array.from({ length: Number(doc.count) }, () => last);
  }
  return list.filter((t) => now - t < STRIKE_DAYS * DAY).sort((a, b) => a - b);
}

export function strikeText(n, reason, until) {
  const why = reason ? ` (${reason})` : '';
  if (n <= 1) return `Warning: something you shared broke our rules${why} and was removed. More strikes can stop you from posting or close your account.`;
  if (n === 2) return `Second strike${why}: you can't share posts, clips or moments until ${new Date(until).toISOString().slice(0, 10)}.`;
  return `Third strike${why}: your account may be closed.`;
}

/**
 * +1 strike. -> { strikes, blockUntil (ms, 0 = none), askBan }
 */
export async function addStrike(sa, uid, { reason = '', fetchFn = fetch, now = Date.now(), notify = true } = {}) {
  if (!ID.test(String(uid || ''))) throw new HttpError(400, 'Bad user');
  const prev = await getDoc(sa, `strikes/${uid}`, fetchFn).catch(() => null);
  const list = [...activeStrikes(prev, now), now];
  const n = list.length;
  const oldBlock = ms(prev?.blockUntil);
  const blockUntil = n >= 2 ? Math.max(oldBlock, now + BLOCK_DAYS * DAY) : oldBlock > now ? oldBlock : 0;
  await commitWrites(sa, [{
    update: `strikes/${uid}`,
    fields: {
      at: list.map((t) => new Date(t)),
      count: n,
      lastAt: new Date(now),
      lastReason: s(reason, 80),
      blockUntil: blockUntil ? new Date(blockUntil) : null,
    },
  }], fetchFn);
  if (notify) {
    await addDoc(sa, `users/${uid}/notifications`, {
      type: 'notice',
      fromUid: '',
      fromUsername: 'InstantGram',
      fromPhotoUrl: '',
      postId: '',
      postThumb: '',
      text: strikeText(n, reason, blockUntil),
      read: false,
      createdAt: new Date(now),
    }, fetchFn).catch((e) => console.warn('strike notice', e?.message || e));
  }
  return { strikes: n, blockUntil, askBan: n >= 3 };
}

/** Admin: remove all strikes (and the posting block). */
export async function clearStrikes(sa, uid, { fetchFn = fetch } = {}) {
  if (!ID.test(String(uid || ''))) throw new HttpError(400, 'Bad user');
  await commitWrites(sa, [{ delete: `strikes/${uid}` }], fetchFn);
  return { strikes: 0 };
}

export function strikeInfo(doc, now) {
  const list = activeStrikes(doc, now);
  const until = ms(doc?.blockUntil);
  return { strikes: list.length, blockUntil: until > now ? until : 0, lastReason: s(doc?.lastReason, 80) };
}

// ------------------------------------------------------------ trending

/** Points for trending: people doing things, newer is better. */
export function trendScore(p, now) {
  const likes = Number(p.likesCount) || 0;
  const comments = Number(p.commentsCount) || 0;
  const shares = Number(p.sharesCount) || 0;
  const saves = Math.max(0, Number(p.savesCount) || 0);
  const reposts = Number(p.repostsCount) || 0;
  const views = Number(p.uniqueViews) || 0;
  const raw = likes + 2 * comments + 3 * shares + 3 * saves + 2 * reposts + 0.2 * views;
  const hours = Math.max(0, (now - ms(p.createdAt)) / 3_600_000);
  return raw * Math.pow(0.5, hours / 24);
}

/** Can it be in trending? (public, not hidden, not profile-only) */
export function trendable(p) {
  if (['hidden', 'review'].includes(p.modState) || p.sensitive === true) return false;
  if (p.audience && p.audience !== 'everyone') return false;
  return p.profileOnly !== true;
}

/** Posts of the last 48 h -> config/trending { ids, clipIds, at }. */
export async function updateTrending(sa, { fetchFn = fetch, now = Date.now(), limit = 100 } = {}) {
  const rows = await runQuery(sa, {
    from: [{ collectionId: 'posts' }],
    where: { fieldFilter: { field: { fieldPath: 'createdAt' }, op: 'GREATER_THAN_OR_EQUAL', value: { timestampValue: new Date(now - 2 * DAY).toISOString() } } },
    orderBy: [{ field: { fieldPath: 'createdAt' }, direction: 'DESCENDING' }],
    limit: 500,
  }, '', fetchFn);
  const best = rows
    .filter((r) => trendable(r.data))
    .map((r) => ({ id: r.id, clip: r.data.type === 'clip', score: trendScore(r.data, now) }))
    .filter((x) => x.score > 0)
    .sort((a, b) => b.score - a.score)
    .slice(0, limit);
  const fields = { ids: best.map((x) => x.id), clipIds: best.filter((x) => x.clip).map((x) => x.id), at: new Date(now), scanned: rows.length };
  await commitWrites(sa, [{ update: 'config/trending', fields }], fetchFn);
  return { trending: best.length, clips: fields.clipIds.length, scanned: rows.length };
}

/** Only when the list is older than [maxAgeMs] (view milestones call this). */
export async function refreshTrendingIfOld(sa, { fetchFn = fetch, now = Date.now(), maxAgeMs = 30 * 60_000 } = {}) {
  const t = await getDoc(sa, 'config/trending', fetchFn).catch(() => null);
  if (t && now - ms(t.at) < maxAgeMs) return { skipped: true };
  return updateTrending(sa, { fetchFn, now });
}
