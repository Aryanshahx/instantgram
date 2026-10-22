// "Original audio" for posts made BEFORE the app saved it (v0.0.1).
// POST /api/hi { action: 'origAudio', postId } -> the song page music/o_<postId>
//   Someone taps "Original audio" under a name: the page is made from the
//   video's own sound (the video file itself is played as the song), and
//   the post is linked to it. New posts get it while uploading (the app
//   cuts the sound out), so this is only for older videos.
import { HttpError } from './http.js';
import { getDoc, patchDoc } from './google.js';

const ID = /^[A-Za-z0-9_-]{1,64}$/;

const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? Math.max(0, Math.round(v)) : 0);

/** The first video of a post (or null): { url, key, durationMs, edits }. */
export function firstVideo(post) {
  const list = Array.isArray(post?.media) && post.media.length
    ? post.media
    : post?.type === 'clip' && typeof post.mediaUrl === 'string'
      ? [{
          type: 'video',
          url: post.mediaUrl,
          key: post.mediaKey || '',
          durationMs: post.durationMs,
          // old clips keep their edits on the post itself
          edits: { muteAudio: post.muteAudio, trimStartMs: post.trimStartMs, trimEndMs: post.trimEndMs },
        }]
      : [];
  const v = list.find((m) => m && m.type === 'video');
  if (!v || typeof v.url !== 'string' || !v.url.startsWith('https://')) return null;
  return { url: v.url, key: typeof v.key === 'string' ? v.key : '', durationMs: num(v.durationMs), edits: v.edits && typeof v.edits === 'object' ? v.edits : {} };
}

const out = (id, doc) => ({
  id,
  ...doc,
  createdAt: doc.createdAt instanceof Date ? doc.createdAt.toISOString() : doc.createdAt,
});

export async function origAudio(sa, uid, body, { fetchFn = fetch, now = Date.now() } = {}) {
  const postId = typeof body?.postId === 'string' ? body.postId : '';
  if (!ID.test(postId)) throw new HttpError(400, 'Bad post');
  const id = `o_${postId}`;
  const have = await getDoc(sa, `music/${id}`, fetchFn);
  if (have) {
    if (have.hidden === true) throw new HttpError(403, 'This audio was removed');
    return out(id, have);
  }
  const post = await getDoc(sa, `posts/${postId}`, fetchFn);
  if (!post) throw new HttpError(404, 'Post not found (maybe deleted)');
  if (post.modState === 'hidden') throw new HttpError(403, 'This post is hidden');
  if (typeof post.audioUrl === 'string' && post.audioUrl) throw new HttpError(409, 'This post uses a song');
  if (typeof post.musicId === 'string' && post.musicId && post.musicId !== id) {
    throw new HttpError(409, 'This post uses a song');
  }
  const v = firstVideo(post);
  if (!v) throw new HttpError(409, 'No video sound in this post');
  if (v.edits.muteAudio === true) throw new HttpError(409, 'The sound of this video is off');
  const start = num(v.edits.trimStartMs);
  const end = num(v.edits.trimEndMs);
  const full = end > start ? end : v.durationMs;
  const track = {
    source: 'original',
    ownerUid: typeof post.authorId === 'string' ? post.authorId : '',
    title: 'Original audio',
    artist: `@${String(post.authorUsername || '').slice(0, 60)}`,
    url: v.url,
    key: v.key,
    durationMs: Math.max(0, full - start),
    startMs: start,
    fromVideo: true,
    uses: 0,
    hidden: false,
    createdAt: new Date(now),
    lastPost: postId,
  };
  if (!(await patchDoc(sa, `music/${id}`, track, {}, fetchFn))) {
    throw new HttpError(500, 'Could not make the audio page');
  }
  // the post now shows the page (and is listed on it)
  if (post.musicId !== id) await patchDoc(sa, `posts/${postId}`, { musicId: id }, {}, fetchFn);
  return out(id, track);
}
