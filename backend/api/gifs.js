// POST /api/gifs  { q?: string, offset?: number }   (v0.8, comments)
// -> { gifs: [{ id, url, preview, width, height }], next, poweredBy }
// GIF search through GIPHY. Needs the Vercel setting GIPHY_API_KEY
// (free key from https://developers.giphy.com). The key stays on the server.
import { requireUser } from '../lib/firebase-auth.js';
import { env, HttpError, postHandler } from '../lib/http.js';

const LIMIT = 24;

export function toGif(g) {
  const im = (g && g.images) || {};
  const main = im.fixed_width || im.downsized || im.original || {};
  const small = im.fixed_width_small || im.preview_gif || main;
  const url = main.webp || main.url;
  if (!url) return null;
  return {
    id: String(g.id || ''),
    url,
    preview: small.webp || small.url || url,
    width: Number(main.width) || 200,
    height: Number(main.height) || 200,
  };
}

export default postHandler(async (req, body) => {
  await requireUser(req);
  const key = env('GIPHY_API_KEY');
  if (!key) throw new HttpError(503, 'GIF search is not set up yet (GIPHY_API_KEY missing)');
  const q = typeof body.q === 'string' ? body.q.trim().slice(0, 50) : '';
  const offset = Math.max(0, Math.min(4900, Number(body.offset) || 0));
  const params = new URLSearchParams({
    api_key: key,
    limit: String(LIMIT),
    offset: String(offset),
    rating: 'pg-13',
    bundle: 'messaging_non_clips',
  });
  if (q) params.set('q', q);
  const url = `https://api.giphy.com/v1/gifs/${q ? 'search' : 'trending'}?${params}`;
  const r = await fetch(url);
  if (!r.ok) {
    console.error('giphy', r.status, await r.text().catch(() => ''));
    throw new HttpError(502, 'GIF search failed, try again');
  }
  const data = await r.json();
  const gifs = (data.data || []).map(toGif).filter(Boolean);
  const total = (data.pagination && data.pagination.total_count) || 0;
  const next = offset + LIMIT < total ? offset + LIMIT : null;
  return { gifs, next, poweredBy: 'GIPHY' };
});
