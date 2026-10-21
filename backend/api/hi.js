// Hyper Intelligence (v0.18)
// POST /api/hi { action: 'check', kind: 'post' | 'moment' | 'comment', id,
//                postId? (comments), frames?: ['data:image/jpeg;base64,...'] }
//   -> { state: 'ok' | 'review' | 'hidden' | 'unchecked', reasons, sensitive }
//   The app calls it right after sharing. Only the owner can ask, and only
//   once (a decided item just returns its state). frames = 3 pictures of
//   each video (25 / 50 / 75 %), made on the phone.
// GET /api/hi?job=sweep  (Vercel cron, once a day): checks what is left.
// v0.19: POST /api/hi { action: 'translate', text, to } -> { text, from, to }
//   "See translation" for captions, comments and bios (any signed-in user).
// v0.20: POST /api/hi { action: 'report', reportId } -> counts a report
//   (3 points = blurred, 6 = hidden, child safety = hidden at once).
//   The daily job also updates the trending list (config/trending).
// Music update: POST /api/hi { action: 'songInfo' } -> { enabled, left, perDay, fullCost }
//   POST /api/hi { action: 'song', prompt, full?, instrumental?, title? }
//   -> the new AI song (Google Lyria via OpenRouter or Gemini). Daily limit per person + for the app.
// Epidemic Sound: POST /api/hi { action: 'esHome' | 'esSearch' | 'esCollection' |
//   'esPreview' | 'esUse' | 'esTracks' } (see lib/epidemic.js, key EPIDEMIC_API_KEY).
import { requireUser } from '../lib/firebase-auth.js';
import { HttpError, env, postHandler, send } from '../lib/http.js';
import { getDoc, notSetUp, serviceAccount } from '../lib/google.js';
import { KINDS, checkItem, decided, pathOf, sweep } from '../lib/hi.js';
import { allowTranslate, translate } from '../lib/translate.js';
import { handleReport, updateTrending } from '../lib/safety.js';
import { FULL_COST, makeSong, quotaOf } from '../lib/music.js';
import { putFile } from '../lib/tigris.js';
import { ES_ACTIONS, handleEs } from '../lib/epidemic.js';

const ID = /^[A-Za-z0-9_-]{6,64}$/;

export async function handle(uid, body, { sa = serviceAccount(), fetchFn = fetch, key = env('OPENAI_API_KEY'), now = Date.now(), geminiKey = env('GEMINI_API_KEY'), openrouterKey = env('OPENROUTER_API_KEY'), esKey = env('EPIDEMIC_API_KEY'), save = putFile } = {}) {
  if (ES_ACTIONS.includes(body.action)) {
    if (body.action === 'esUse' && !sa) throw notSetUp('Songs');
    return handleEs(sa, uid, body, { key: esKey, fetchFn, save, now });
  }
  if (body.action === 'songInfo') {
    if (!sa) throw notSetUp('AI songs');
    const { left, perDay } = await quotaOf(sa, uid, { now, fetchFn });
    const on = !!(geminiKey || openrouterKey);
    return { enabled: on, left: on ? left : 0, perDay, fullCost: FULL_COST };
  }
  if (body.action === 'song') {
    if (!sa) throw notSetUp('AI songs');
    return makeSong(sa, uid, body, { save, fetchFn, key: geminiKey, openrouterKey, openaiKey: key, now });
  }
  if (body.action === 'translate') {
    if (!allowTranslate(uid, now)) throw new HttpError(429, 'Too many translations, try again in a few minutes');
    return translate(body, { fetchFn });
  }
  if (body.action === 'report') {
    if (!sa) throw notSetUp('Reports');
    return handleReport(sa, uid, body.reportId, { fetchFn, now });
  }
  if (body.action !== 'check') throw new HttpError(400, 'Bad action');
  const kind = KINDS.includes(body.kind) ? body.kind : '';
  const id = typeof body.id === 'string' ? body.id : '';
  const postId = typeof body.postId === 'string' ? body.postId : '';
  if (!kind || !ID.test(id) || (kind === 'comment' && !ID.test(postId))) throw new HttpError(400, 'Bad request');
  if (!sa) throw notSetUp('Hyper Intelligence');
  const doc = await getDoc(sa, pathOf(kind, id, postId), fetchFn);
  if (!doc) throw new HttpError(404, 'Not found (maybe deleted)');
  if (doc.authorId !== uid) throw new HttpError(403, 'Not yours');
  if (decided(kind, doc)) {
    return kind === 'comment'
      ? { state: doc.hidden ? 'hidden' : doc.sensitive ? 'review' : 'ok', sensitive: doc.sensitive === true, reasons: doc.modReasons || [] }
      : { state: doc.modState, sensitive: doc.sensitive === true, reasons: doc.modReasons || [] };
  }
  return checkItem(sa, { kind, id, postId, doc, frames: body.frames, source: 'app', now }, { fetchFn, key });
}

/** Cron: with CRON_SECRET set, Vercel sends it; without, only Vercel's cron agent. */
export function cronAllowed(req, secret = env('CRON_SECRET')) {
  const auth = String(req.headers?.authorization || '');
  if (secret) return auth === `Bearer ${secret}`;
  return /vercel-cron/i.test(String(req.headers?.['user-agent'] || ''));
}

const post = postHandler(async (req, body) => {
  const uid = await requireUser(req);
  return handle(uid, body);
});

export default async function handler(req, res) {
  if (req.method === 'GET') {
    if (!cronAllowed(req)) return send(res, 403, { error: 'Only the daily job' });
    const sa = serviceAccount();
    if (!sa) return send(res, 500, { error: 'FIREBASE_SERVICE_ACCOUNT missing' });
    try {
      const checked = await sweep(sa, { limit: 20 });
      const trending = await updateTrending(sa).catch((e) => ({ error: String(e?.message || e) }));
      return send(res, 200, { ...checked, trending });
    } catch (e) {
      console.error(e);
      return send(res, 500, { error: 'Sweep failed' });
    }
  }
  return post(req, res);
}
