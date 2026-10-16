// Hyper Intelligence (v0.18)
// POST /api/hi { action: 'check', kind: 'post' | 'moment' | 'comment', id,
//                postId? (comments), frames?: ['data:image/jpeg;base64,...'] }
//   -> { state: 'ok' | 'review' | 'hidden' | 'unchecked', reasons, sensitive }
//   The app calls it right after sharing. Only the owner can ask, and only
//   once (a decided item just returns its state). frames = 3 pictures of
//   each video (25 / 50 / 75 %), made on the phone.
// GET /api/hi?job=sweep  (Vercel cron, once a day): checks what is left.
import { requireUser } from '../lib/firebase-auth.js';
import { HttpError, env, postHandler, send } from '../lib/http.js';
import { getDoc, notSetUp, serviceAccount } from '../lib/google.js';
import { KINDS, checkItem, decided, pathOf, sweep } from '../lib/hi.js';

const ID = /^[A-Za-z0-9_-]{6,64}$/;

export async function handle(uid, body, { sa = serviceAccount(), fetchFn = fetch, key = env('OPENAI_API_KEY'), now = Date.now() } = {}) {
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
      return send(res, 200, await sweep(sa, { limit: 20 }));
    } catch (e) {
      console.error(e);
      return send(res, 500, { error: 'Sweep failed' });
    }
  }
  return post(req, res);
}
