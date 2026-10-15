// POST /api/activity-push  { to, id }   (v0.12)
// -> { sent: number, off?: bool }
// After the app saves an activity notification (users/{to}/notifications/{id})
// it calls this: the person gets a phone notification, also when the app
// is closed. Types: like, comment, reply, comment_like, follow, unfollow,
// repost, moment_like (v0.16). Only the person who made the notification can trigger it, and
// only for fresh ones (< 2 minutes). The person can switch each kind off
// in Settings -> Notifications (prefs/{uid}.pushOff).
import { requireUser } from '../lib/firebase-auth.js';
import { HttpError, postHandler } from '../lib/http.js';
import { getDoc, notSetUp, sendFcm, serviceAccount } from '../lib/google.js';
import { prefsOf, tokensOf } from './call-push.js';

const MAX_AGE_MS = 120_000;

/** Notification type -> switch in Settings -> Notifications. */
export const CATEGORY = {
  like: 'likes',
  moment_like: 'likes', // v0.16
  comment: 'comments',
  reply: 'comments',
  comment_like: 'comment_likes',
  follow: 'follows',
  follow_request: 'follows',
  unfollow: 'unfollows',
  repost: 'reposts',
  views: 'views',
};

function short(t, n = 100) {
  const s = String(t || '').replace(/\s+/g, ' ').trim();
  return s.length > n ? `${s.slice(0, n)}…` : s;
}

/** Text of the phone notification. */
export function textOf(n) {
  const who = n.fromUsername ? String(n.fromUsername) : 'Someone';
  const what = n.postType === 'clip' ? 'clip' : 'post';
  const t = short(n.text);
  switch (n.type) {
    case 'like':
      return `${who} liked your ${what}`;
    case 'moment_like':
      return `${who} liked your moment`;
    case 'comment':
      return t ? `${who} commented: ${t}` : `${who} commented on your ${what}`;
    case 'reply':
      return t ? `${who} replied to your comment: ${t}` : `${who} replied to your comment`;
    case 'comment_like':
      return t ? `${who} liked your comment: ${t}` : `${who} liked your comment`;
    case 'follow':
      return `${who} started following you`;
    case 'follow_request':
      return `${who} wants to follow you`;
    case 'unfollow':
      return `${who} unfollowed you`;
    case 'repost':
      return `${who} reposted your ${what}`;
    case 'views':
      return `🎉 Your ${what} reached ${Number(n.text || 0).toLocaleString('en-US')} views`;
    default:
      return `${who} sent you an update`;
  }
}

export function checkNotif(n, uid, now = Date.now()) {
  if (!n) throw new HttpError(404, 'Notification not found');
  if (n.fromUid !== uid) throw new HttpError(403, 'Not your notification');
  if (!CATEGORY[n.type] || n.type === 'views') throw new HttpError(409, 'No push for this notification');
  const created = Date.parse(n.createdAt || '');
  if (Number.isFinite(created) && now - created > MAX_AGE_MS) {
    throw new HttpError(409, 'Notification is too old');
  }
  return n;
}

export function pushOff(prefs, type) {
  const off = Array.isArray(prefs?.pushOff) ? prefs.pushOff : [];
  return off.includes(CATEGORY[type]);
}

export function buildMessages(n, tokens) {
  const body = textOf(n);
  return tokens.map((token) => ({
    token,
    data: {
      type: 'activity',
      ntype: String(n.type || ''),
      postId: String(n.postId || ''),
      fromUid: String(n.fromUid || ''),
    },
    android: {
      priority: 'HIGH',
      ttl: '86400s',
      notification: {
        channel_id: 'activity',
        icon: 'ic_stat_instantgram', // v0.13: InstantGram logo
        color: '#C6FF3D',
        // one notification per kind + post / person (newest replaces it)
        tag: `act_${n.type}_${n.postId || n.fromUid || ''}`.slice(0, 120),
        title: 'InstantGram',
        body,
      },
    },
  }));
}

/** Sends [n] to [to]'s phones (respects Settings -> Notifications). */
export async function pushTo(sa, to, n, fetchFn = fetch) {
  const prefs = await prefsOf(sa, to, fetchFn);
  if (pushOff(prefs, n.type)) return { sent: 0, off: true };
  const tokens = await tokensOf(sa, to, fetchFn);
  let sent = 0;
  for (const msg of buildMessages(n, tokens)) {
    if (await sendFcm(sa, msg, fetchFn)) sent++;
  }
  return { sent };
}

export async function handle(uid, body, { sa = serviceAccount(), fetchFn = fetch } = {}) {
  const to = typeof body.to === 'string' ? body.to : '';
  const id = typeof body.id === 'string' ? body.id : '';
  if (!/^[A-Za-z0-9]{6,64}$/.test(to) || !/^[A-Za-z0-9]{10,40}$/.test(id)) {
    throw new HttpError(400, 'Bad request');
  }
  if (to === uid) return { sent: 0 };
  if (!sa) throw notSetUp('Notifications');
  const n = checkNotif(await getDoc(sa, `users/${to}/notifications/${id}`, fetchFn), uid);
  let postType = '';
  if (n.postId && /^[A-Za-z0-9]{6,64}$/.test(String(n.postId))) {
    try {
      const p = await getDoc(sa, `posts/${n.postId}`, fetchFn);
      postType = String(p?.type || '');
    } catch {
      /* text without post type */
    }
  }
  return pushTo(sa, to, { ...n, postType }, fetchFn);
}

export default postHandler(async (req, body) => {
  const uid = await requireUser(req);
  return handle(uid, body);
});
