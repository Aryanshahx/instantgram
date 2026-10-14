// POST /api/view-milestone  { postId }   (v0.12)
// -> { milestone: number }   (0 = nothing new)
// The app calls this after a view when a post may have passed 100, 500,
// 1K, 5K, 10K ... views. The server checks the real number, saves the
// milestone on the post (only once, even if many people call at the same
// time), adds "Your clip reached 1,000 views" to the author's
// notifications and sends it to their phone.
import { requireUser } from '../lib/firebase-auth.js';
import { HttpError, postHandler } from '../lib/http.js';
import { addDoc, getDocMeta, notSetUp, patchDoc, serviceAccount } from '../lib/google.js';
import { pushTo } from './activity-push.js';

export const MILESTONES = [100, 500, 1000, 5000, 10000, 50000, 100000, 500000, 1000000, 5000000, 10000000];

/** Highest milestone reached by [views] (0 = none). */
export function milestoneFor(views) {
  let m = 0;
  for (const x of MILESTONES) if (views >= x) m = x;
  return m;
}

/** Cover image of a post (same as Post.coverUrl in the app). */
export function thumbOf(p) {
  if (p.thumbUrl) return String(p.thumbUrl);
  for (const m of Array.isArray(p.media) ? p.media : []) {
    const c = m?.type === 'video' ? m.thumbUrl : m?.url;
    if (c) return String(c);
  }
  return p.type === 'photo' ? String(p.mediaUrl || '') : '';
}

export async function handle(uid, body, { sa = serviceAccount(), fetchFn = fetch, now = () => new Date() } = {}) {
  const postId = typeof body.postId === 'string' ? body.postId : '';
  if (!/^[A-Za-z0-9]{6,64}$/.test(postId)) throw new HttpError(400, 'Bad request');
  if (!sa) throw notSetUp('Notifications');
  const doc = await getDocMeta(sa, `posts/${postId}`, fetchFn);
  if (!doc) throw new HttpError(404, 'Post not found');
  const p = doc.data;
  // one view per account ('viewsCount' was wrong in old versions)
  const views = Number(p.uniqueViews) || 0;
  const m = milestoneFor(views);
  const before = Number(p.viewsMilestone) || 0;
  if (m <= before) return { milestone: 0 };
  // only the first caller wins (the post must not have changed meanwhile)
  const won = await patchDoc(sa, `posts/${postId}`, { viewsMilestone: m }, { updateTime: doc.updateTime }, fetchFn);
  if (!won) return { milestone: 0 };
  const author = String(p.authorId || '');
  if (!/^[A-Za-z0-9]{6,64}$/.test(author)) return { milestone: m };
  const n = {
    type: 'views',
    fromUid: '',
    fromUsername: '',
    fromPhotoUrl: '',
    postId,
    postThumb: thumbOf(p),
    text: String(m),
    read: false,
    createdAt: now(),
  };
  await addDoc(sa, `users/${author}/notifications`, n, fetchFn);
  await pushTo(sa, author, { ...n, postType: String(p.type || '') }, fetchFn);
  return { milestone: m };
}

export default postHandler(async (req, body) => {
  const uid = await requireUser(req);
  return handle(uid, body);
});
