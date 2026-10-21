// Epidemic Sound (music for posts, clips and moments).
// The API key (EPIDEMIC_API_KEY) stays here on the server; the app asks
// through POST /api/hi { action: 'es...' }.
//   esHome        -> { tracks (most popular), collections (playlists) }
//   esSearch      -> { tracks } for a word ("happy", "lofi", "workout", ...)
//   esCollection  -> { tracks } of one playlist
//   esPreview     -> { url } short-lived HLS link to listen before using
//   esUse         -> the song saved in our storage (music/es_<id>) so posts
//                    keep playing; downloaded only ONCE for the whole app
//   esTracks      -> { tracks } by id (saved songs)
// Lists are kept in memory for max 30 minutes (Epidemic allows 60).
import { createHash } from 'node:crypto';
import { HttpError, env } from './http.js';
import { getDoc, patchDoc } from './google.js';

export const ES_BASE = 'https://partner-content-api.epidemicsound.com';
export const MB = 1024 * 1024;
export const MAX_ES_BYTES = 20 * MB;
const UUID = /^[0-9a-fA-F-]{8,64}$/;
const CACHE_MS = 30 * 60 * 1000;
const cache = new Map();
/** New downloads per person per hour (saved songs don't count). */
export const NEW_PER_HOUR = 20;
const fresh = new Map();

export function _resetEsCache() {
  cache.clear();
  fresh.clear();
}

function allowNew(uid, now) {
  const list = (fresh.get(uid) || []).filter((t) => now - t < 3600_000);
  if (list.length >= NEW_PER_HOUR) return false;
  list.push(now);
  fresh.set(uid, list);
  if (fresh.size > 5000) fresh.delete(fresh.keys().next().value);
  return true;
}

/** Epidemic wants a stable, anonymous id per user. */
export function esUserId(uid) {
  return createHash('sha256').update(`ig:${uid}`).digest('hex').slice(0, 32);
}

export function esIdOf(v) {
  const s = typeof v === 'string' ? v.trim().replace(/^es_/, '') : '';
  return UUID.test(s) ? s : '';
}

/** One Epidemic track -> what the app shows. */
export function trackOut(t) {
  if (!t || typeof t !== 'object' || !esIdOf(t.id)) return null;
  const img = t.images && typeof t.images === 'object' ? t.images : {};
  const artists = Array.isArray(t.mainArtists) ? t.mainArtists.filter((a) => typeof a === 'string') : [];
  return {
    id: `es_${t.id}`,
    esId: t.id,
    source: 'epidemic',
    title: String(t.title || 'Song').slice(0, 120),
    artist: artists.join(', ').slice(0, 80),
    durationMs: Math.max(0, Math.round(Number(t.length) || 0) * 1000),
    cover: String(img.M || img.S || img.default || img.L || ''),
    explicit: t.isExplicit === true,
    bpm: Number.isFinite(t.bpm) ? t.bpm : 0,
    mood: Array.isArray(t.moods) && t.moods[0]?.name ? String(t.moods[0].name) : '',
  };
}

/** Tracks the app can use (premium "preview only" songs left out). */
export function tracksOut(list) {
  return (Array.isArray(list) ? list : [])
    .filter((t) => t && t.isPreviewOnly !== true)
    .map(trackOut)
    .filter(Boolean);
}

async function esFetch(path, { key, fetchFn, uid, raw = false }) {
  if (!key) throw new HttpError(503, 'Songs are not set up yet (EPIDEMIC_API_KEY)');
  let r;
  try {
    r = await fetchFn(`${ES_BASE}${path}`, {
      headers: {
        Accept: 'application/json',
        Authorization: `Bearer ${key}`,
        ...(uid ? { 'x-partner-user-id': esUserId(uid) } : {}),
      },
    });
  } catch (e) {
    throw new HttpError(502, `Epidemic Sound not reachable (${e?.message || e})`);
  }
  if (!r.ok) {
    let msg = '';
    try {
      const j = await r.json();
      msg = [j?.key, ...(Array.isArray(j?.messages) ? j.messages : [])].filter(Boolean).join(': ');
    } catch { /* no JSON */ }
    console.warn('epidemic', r.status, path.split('?')[0], msg);
    if (r.status === 401) throw new HttpError(503, 'EPIDEMIC_API_KEY is wrong');
    if (r.status === 403) throw new HttpError(403, "This song can't be used here. Pick another one.");
    if (r.status === 404) throw new HttpError(404, 'Song not found');
    if (r.status === 429) throw new HttpError(429, 'Too many songs right now. Try again in a minute.');
    throw new HttpError(502, `Epidemic Sound error ${r.status}`);
  }
  return raw ? r : r.json();
}

async function cached(name, make, now) {
  const hit = cache.get(name);
  if (hit && now - hit.at < CACHE_MS) return hit.value;
  const value = await make();
  cache.set(name, { at: now, value });
  if (cache.size > 300) cache.delete(cache.keys().next().value);
  return value;
}

const clampInt = (v, lo, hi, d) => {
  const n = Math.floor(Number(v));
  return Number.isFinite(n) ? Math.min(hi, Math.max(lo, n)) : d;
};

const COL_ID = /^[A-Za-z0-9_-]{1,80}$/;
/** Playlists read for the home list (free-tier ones come first). */
export const HOME_COLLECTIONS = 8;

/**
 * v0.0.1 fix: "Popularity" search gives mostly premium (preview-only)
 * songs, so the list was EMPTY. Now the home list = songs from the
 * playlists (free ones first) + the usable popular songs, no duplicates.
 */
export async function esHome(uid, { key, fetchFn, now = Date.now() }) {
  const hit = cache.get('home');
  if (hit && now - hit.at < CACHE_MS) return hit.value;
  const o = { key, fetchFn, uid };
  const [top, cols] = await Promise.all([
    esFetch('/v0/tracks/search?sort=Popularity&order=desc&limit=60', o).catch((e) => ({ error: e })),
    esFetch('/v0/collections?excludeField=tracks&limit=30', o).catch((e) => ({ error: e })),
  ]);
  // both failed: show the real reason (key wrong, not set, ...)
  if (top?.error && cols?.error) throw top.error;
  const all = (Array.isArray(cols?.collections) ? cols.collections : [])
    .filter((c) => c && typeof c.id === 'string' && COL_ID.test(c.id) && c.name);
  const lists = await Promise.all(
    all.slice(0, HOME_COLLECTIONS).map((c) =>
      esFetch(`/v0/collections/${c.id}?limit=100`, o)
        .then((j) => tracksOut(j?.tracks))
        .catch(() => [])),
  );
  const seen = new Set();
  const tracks = [];
  const add = (list) => {
    for (const t of list) {
      if (seen.has(t.id)) continue;
      seen.add(t.id);
      tracks.push(t);
    }
  };
  // a mix: popular usable songs first, then songs from each playlist in turn
  add(tracksOut(top?.tracks));
  const longest = Math.max(0, ...lists.map((l) => l.length));
  for (let i = 0; i < longest; i++) add(lists.map((l) => l[i]).filter(Boolean));
  const usable = new Set(all.slice(0, HOME_COLLECTIONS).filter((_, i) => lists[i].length > 0).map((c) => c.id));
  const shown = all.filter((c, i) => usable.has(c.id) || i >= HOME_COLLECTIONS);
  const collections = (usable.size ? shown : all)
    .map((c) => ({ id: c.id, name: String(c.name).slice(0, 60), cover: String(c.images?.S || c.images?.default || '') }));
  const value = { tracks: tracks.slice(0, 300), collections };
  // an empty answer is not kept (next open tries again)
  if (value.tracks.length) {
    cache.set('home', { at: now, value });
    if (cache.size > 300) cache.delete(cache.keys().next().value);
  }
  return value;
}

/** Words in a song (for searching the home songs when search finds nothing). */
const words = (t) => `${t.title} ${t.artist} ${t.mood}`.toLowerCase();

export async function esSearch(uid, body, { key, fetchFn, now = Date.now() }) {
  const term = typeof body?.term === 'string' ? body.term.trim().slice(0, 200) : '';
  if (!term) return { tracks: [] };
  const offset = clampInt(body?.offset, 0, 500, 0);
  const q = new URLSearchParams({ term, sort: 'Relevance', order: 'desc', limit: '60', offset: String(offset) });
  return cached(`s:${term.toLowerCase()}:${offset}`, async () => {
    const j = await esFetch(`/v0/tracks/search?${q}`, { key, fetchFn, uid });
    const found = tracksOut(j?.tracks);
    if (found.length || offset > 0) return { tracks: found };
    // v0.0.1: only premium songs matched -> look in the usable home songs
    let home;
    try {
      home = await esHome(uid, { key, fetchFn, now });
    } catch {
      return { tracks: [] };
    }
    const parts = term.toLowerCase().split(/\s+/).filter(Boolean);
    return { tracks: home.tracks.filter((t) => parts.every((p) => words(t).includes(p))).slice(0, 60) };
  }, now);
}

/** v0.0.1 /api/health?songs=1: why the song list could be empty. */
export async function esDiagnose({ key = env('EPIDEMIC_API_KEY'), fetchFn = fetch } = {}) {
  if (!key) return { ok: false, reason: 'EPIDEMIC_API_KEY is not set in Vercel' };
  const out = { ok: false };
  try {
    const top = await esFetch('/v0/tracks/search?sort=Popularity&order=desc&limit=60', { key, fetchFn });
    const list = Array.isArray(top?.tracks) ? top.tracks : [];
    out.popular = list.length;
    out.popularUsable = tracksOut(list).length;
  } catch (e) {
    out.popularError = e?.message || String(e);
  }
  try {
    const h = await esHome('health', { key, fetchFn, now: Date.now() });
    out.homeSongs = h.tracks.length;
    out.playlists = h.collections.length;
    out.ok = h.tracks.length > 0;
  } catch (e) {
    out.homeError = e?.message || String(e);
  }
  return out;
}

export async function esCollection(uid, body, { key, fetchFn, now = Date.now() }) {
  const id = typeof body?.id === 'string' && /^[A-Za-z0-9_-]{1,80}$/.test(body.id) ? body.id : '';
  if (!id) throw new HttpError(400, 'Bad playlist');
  const offset = clampInt(body?.offset, 0, 1000, 0);
  return cached(`c:${id}:${offset}`, async () => {
    const j = await esFetch(`/v0/collections/${id}?limit=60&offset=${offset}`, { key, fetchFn, uid });
    return { name: String(j?.name || ''), tracks: tracksOut(j?.tracks) };
  }, now);
}

export async function esPreview(uid, body, { key, fetchFn }) {
  const id = esIdOf(body?.id);
  if (!id) throw new HttpError(400, 'Bad song');
  const j = await esFetch(`/v0/tracks/${id}/stream`, { key, fetchFn, uid });
  if (typeof j?.url !== 'string' || !j.url.startsWith('https://')) throw new HttpError(502, 'No preview');
  return { url: j.url, expires: j.expires || '' };
}

export async function esTracks(uid, body, { key, fetchFn }) {
  const ids = (Array.isArray(body?.ids) ? body.ids : []).map(esIdOf).filter(Boolean).slice(0, 50);
  if (!ids.length) return { tracks: [] };
  const q = new URLSearchParams();
  for (const id of ids) q.append('trackId', id);
  const j = await esFetch(`/v0/tracks/metadata?${q}`, { key, fetchFn, uid });
  const list = Array.isArray(j) ? j : Array.isArray(j?.tracks) ? j.tracks : [];
  return { tracks: list.map(trackOut).filter(Boolean) };
}

/** Best 30 s part of the song (ms), 0 when unknown. */
async function highlightStart(id, { key, fetchFn, uid }) {
  try {
    const j = await esFetch(`/v0/tracks/${id}/highlights?duration=30`, { key, fetchFn, uid });
    const h = Array.isArray(j?.highlights) ? j.highlights[0] : null;
    return Number.isFinite(h?.from) && h.from > 0 ? Math.round(h.from) : 0;
  } catch {
    return 0;
  }
}

/**
 * The user picked a song: make sure it is in our storage (music/es_<id>).
 * Downloaded once for the whole app; later users get the saved copy.
 */
export async function esUse(sa, uid, body, { key, fetchFn, save, now = Date.now() }) {
  const id = esIdOf(body?.id);
  if (!id) throw new HttpError(400, 'Bad song');
  const docId = `es_${id}`;
  const have = await getDoc(sa, `music/${docId}`, fetchFn);
  if (have && typeof have.url === 'string' && have.url) {
    if (have.hidden === true) throw new HttpError(403, 'This song was removed');
    return { id: docId, ...have, createdAt: have.createdAt instanceof Date ? have.createdAt.toISOString() : have.createdAt };
  }
  if (!key) throw new HttpError(503, 'Songs are not set up yet (EPIDEMIC_API_KEY)');
  if (!allowNew(uid, now)) throw new HttpError(429, 'You picked many new songs. Try again in an hour.');
  const meta = await esFetch(`/v0/tracks/metadata?trackId=${id}`, { key, fetchFn, uid });
  const t = trackOut(Array.isArray(meta) ? meta[0] : Array.isArray(meta?.tracks) ? meta.tracks[0] : meta);
  if (!t) throw new HttpError(404, 'Song not found');
  const dl = await esFetch(`/v0/tracks/${id}/download?format=mp3&quality=normal`, { key, fetchFn, uid });
  if (typeof dl?.url !== 'string' || !dl.url.startsWith('https://')) throw new HttpError(502, 'No download link');
  let bytes;
  try {
    const r = await fetchFn(dl.url);
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    bytes = Buffer.from(await r.arrayBuffer());
  } catch (e) {
    throw new HttpError(502, `Could not download the song (${e?.message || e})`);
  }
  if (bytes.length < 1000) throw new HttpError(502, 'The song file is empty');
  if (bytes.length > MAX_ES_BYTES) throw new HttpError(413, 'The song file is too big');
  const fileKey = `music/es/${id}.mp3`;
  const { url } = await save(fileKey, bytes, 'audio/mpeg');
  const startMs = await highlightStart(id, { key, fetchFn, uid });
  const track = {
    source: 'epidemic',
    ownerUid: '',
    esId: id,
    title: t.title,
    artist: t.artist,
    cover: t.cover,
    mood: t.mood,
    url,
    key: fileKey,
    durationMs: t.durationMs,
    startMs,
    uses: 0,
    hidden: false,
    createdAt: new Date(now),
  };
  await patchDoc(sa, `music/${docId}`, track, {}, fetchFn);
  return { id: docId, ...track, createdAt: new Date(now).toISOString() };
}

export const ES_ACTIONS = ['esHome', 'esSearch', 'esCollection', 'esPreview', 'esUse', 'esTracks'];

/** POST /api/hi { action: 'es...' } */
export async function handleEs(sa, uid, body, { key = env('EPIDEMIC_API_KEY'), fetchFn = fetch, save, now = Date.now() } = {}) {
  const o = { key, fetchFn, now };
  if (!key) throw new HttpError(503, 'Songs are not set up yet (EPIDEMIC_API_KEY)');
  switch (body.action) {
    case 'esHome': return esHome(uid, o);
    case 'esSearch': return esSearch(uid, body, o);
    case 'esCollection': return esCollection(uid, body, o);
    case 'esPreview': return esPreview(uid, body, o);
    case 'esTracks': return esTracks(uid, body, o);
    case 'esUse': return esUse(sa, uid, body, { ...o, save });
    default: throw new HttpError(400, 'Bad action');
  }
}
