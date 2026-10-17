// Music (InstantGram 0.0.1 music update)
// - Library: songs the admin uploads (free, legal tracks). music/{id}
//   source 'library'. The app lists them in the editor's music sheet.
// - AI songs: Google Lyria (Gemini API, paid: $0.04 per 30 s clip,
//   $0.08 per full song). A daily limit per person + a daily total for
//   the whole app keep the bill small. source 'ai'.
// - "Original audio": music a person added from the phone; others can
//   use it too (the app writes these, see firestore.rules). source 'original'.
import { randomUUID } from 'node:crypto';
import { HttpError, env } from './http.js';
import { getDoc, getDocMeta, patchDoc } from './google.js';
import { decide, groupScores, moderate } from './hi.js';

export const SOURCES = ['library', 'ai', 'original'];

/** Songs per person per day (a full song counts 2). Vercel: SONGS_PER_DAY. */
export const SONGS_PER_DAY = 3;
/** All people together per day (protects the Google bill). SONGS_DAY_CAP. */
export const SONGS_DAY_CAP = 100;
export const FULL_COST = 2;

export const CLIP_MODEL = 'lyria-3-clip-preview';
export const SONG_MODEL = 'lyria-3.5';

const MB = 1024 * 1024;
export const MAX_SONG_BYTES = 20 * MB;

function intEnv(name, d) {
  const n = Number.parseInt(env(name), 10);
  return Number.isFinite(n) && n >= 0 ? n : d;
}

export function limits() {
  return {
    perDay: intEnv('SONGS_PER_DAY', SONGS_PER_DAY),
    cap: intEnv('SONGS_DAY_CAP', SONGS_DAY_CAP),
  };
}

/** India's date ("2026-10-17"): the limit starts again at midnight IST. */
export function today(now = Date.now()) {
  return new Date(now + 5.5 * 3600 * 1000).toISOString().slice(0, 10);
}

/** Text from the app: trimmed, one line breaks kept, max [n] letters. */
export function clean(v, n) {
  const s = typeof v === 'string' ? v.replace(/\r/g, '').replace(/[ \t]+/g, ' ').trim() : '';
  return s.length > n ? s.slice(0, n) : s;
}

/** Song name from the idea: first words, max 40 letters. */
export function titleFrom(prompt) {
  const one = clean(prompt, 400).split('\n')[0].replace(/[[\]{}<>"]/g, '').trim();
  if (!one) return 'AI song';
  let t = one.length > 40 ? `${one.slice(0, 40).replace(/\s+\S*$/, '')}…` : one;
  t = t.charAt(0).toUpperCase() + t.slice(1);
  return t;
}

// ---------------------------------------------------------------- limits

/** Adds [cost] to a counter doc for [day]. false = would go over [max]. */
async function bump(sa, path, cost, max, day, fetchFn) {
  for (let i = 0; i < 4; i++) {
    const meta = await getDocMeta(sa, path, fetchFn);
    const d = meta?.data || {};
    const used = d.day === day ? Number(d.n) || 0 : 0;
    const next = Math.max(0, used + cost);
    if (cost > 0 && next > max) return false;
    const ok = await patchDoc(sa, path, { day, n: next }, { updateTime: meta?.updateTime || null }, fetchFn);
    if (ok) return true;
  }
  throw new HttpError(503, 'Busy, please try again');
}

/** -> { left, perDay } for today. */
export async function quotaOf(sa, uid, { now = Date.now(), fetchFn = fetch } = {}) {
  const { perDay } = limits();
  const d = await getDoc(sa, `songQuota/${uid}`, fetchFn);
  const used = d && d.day === today(now) ? Number(d.n) || 0 : 0;
  return { left: Math.max(0, perDay - used), perDay };
}

/** Takes [cost] from the person's and the app's limit (or throws 429). */
export async function takeQuota(sa, uid, cost, { now = Date.now(), fetchFn = fetch } = {}) {
  const { perDay, cap } = limits();
  const day = today(now);
  if (!(await bump(sa, `songQuota/${uid}`, cost, perDay, day, fetchFn))) {
    throw new HttpError(429, cost > 1
      ? `A full song needs ${cost} of your ${perDay} songs a day. Try a 30 second song or come back tomorrow.`
      : `You made ${perDay} songs today. Come back tomorrow!`);
  }
  if (!(await bump(sa, 'songQuota/_all', cost, cap, day, fetchFn))) {
    await bump(sa, `songQuota/${uid}`, -cost, perDay, day, fetchFn).catch(() => {});
    throw new HttpError(429, 'Too many songs are being made today. Please try again tomorrow.');
  }
  return () => Promise.all([
    bump(sa, `songQuota/${uid}`, -cost, perDay, day, fetchFn),
    bump(sa, 'songQuota/_all', -cost, cap, day, fetchFn),
  ]).catch(() => {});
}

// ---------------------------------------------------------------- Lyria

/** Interactions API answer -> { audio: base64, mime, text }. */
export function readLyria(j) {
  const steps = Array.isArray(j?.steps) ? j.steps : Array.isArray(j?.outputs) ? [{ content: j.outputs }] : [];
  let audio = '';
  let mime = '';
  const texts = [];
  for (const st of steps) {
    const content = Array.isArray(st?.content) ? st.content : st ? [st] : [];
    for (const c of content) {
      if (c?.type === 'audio' && typeof c.data === 'string' && c.data) {
        audio = c.data;
        mime = typeof c.mime_type === 'string' ? c.mime_type : '';
      } else if (c?.type === 'text' && typeof c.text === 'string') {
        texts.push(c.text);
      }
    }
  }
  if (!audio && typeof j?.output_audio?.data === 'string') audio = j.output_audio.data;
  return { audio, mime, text: texts.join('\n').trim() };
}

/** Asks Google Lyria for a song. -> { bytes: Buffer, ext, lyrics, model } */
export async function callLyria({ prompt, full, instrumental }, { key = env('GEMINI_API_KEY'), fetchFn = fetch, timeoutMs = 240_000 } = {}) {
  if (!key) throw new HttpError(503, 'AI songs are not set up yet (GEMINI_API_KEY)');
  const model = full ? env('LYRIA_SONG_MODEL') || SONG_MODEL : env('LYRIA_CLIP_MODEL') || CLIP_MODEL;
  const input = instrumental ? `${prompt}\n\nInstrumental only, no vocals, no singing.` : prompt;
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), timeoutMs);
  let r;
  try {
    r = await fetchFn('https://generativelanguage.googleapis.com/v1beta/interactions', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-goog-api-key': key },
      body: JSON.stringify({ model, input, store: false }),
      signal: ac.signal,
    });
  } catch (e) {
    throw new HttpError(504, ac.signal.aborted ? 'The song took too long. Please try again.' : `Google not reachable (${e?.message || e})`);
  } finally {
    clearTimeout(timer);
  }
  const j = await r.json().catch(() => ({}));
  if (!r.ok) {
    const msg = String(j?.error?.message || '');
    console.warn('lyria', r.status, msg);
    if (r.status === 400 && /safety|block|policy|artist|copyright|lyrics/i.test(msg)) {
      throw new HttpError(400, "Google didn't allow this song idea (no real singers or song lyrics). Try other words.");
    }
    if (r.status === 401 || r.status === 403) throw new HttpError(503, 'GEMINI_API_KEY is wrong or has no billing');
    if (r.status === 429) throw new HttpError(429, 'Too many songs right now. Try again in a minute.');
    if (r.status === 404) throw new HttpError(503, `Lyria model "${model}" not found (check LYRIA models in Vercel)`);
    throw new HttpError(502, `Google error ${r.status}`);
  }
  const { audio, mime, text } = readLyria(j);
  if (!audio) throw new HttpError(400, "Google didn't make a song for this idea. Try other words.");
  const bytes = Buffer.from(audio, 'base64');
  if (bytes.length < 1000) throw new HttpError(502, 'The song came back empty. Please try again.');
  if (bytes.length > MAX_SONG_BYTES) throw new HttpError(502, 'The song is too big');
  const ext = /wav/.test(mime) ? 'wav' : 'mp3';
  return { bytes, ext, lyrics: clean(text, 4000), model };
}

/** Song ideas: Hyper Intelligence says no to harmful text. */
export async function checkIdea(prompt, { key = env('OPENAI_API_KEY'), fetchFn = fetch } = {}) {
  if (!key) return true; // Lyria has its own safety filter too
  try {
    const answers = await moderate({ text: prompt }, { key, fetchFn });
    return decide(groupScores(answers)).state === 'ok';
  } catch (e) {
    console.warn('song idea check skipped', e?.message || e);
    return true;
  }
}

export const IDEA_MIN = 3;
export const IDEA_MAX = 600;

/**
 * Makes an AI song for [uid]: checks, limit, Lyria, saves the file and
 * music/{id}. -> the new track (for the app).
 * [save](key, bytes, contentType) stores the file (Tigris).
 */
export async function makeSong(sa, uid, body, { save, fetchFn = fetch, key = env('GEMINI_API_KEY'), openaiKey = env('OPENAI_API_KEY'), now = Date.now() } = {}) {
  const prompt = clean(body?.prompt, IDEA_MAX);
  if (prompt.length < IDEA_MIN) throw new HttpError(400, 'Write what the song should be like');
  const full = body?.full === true;
  const instrumental = body?.instrumental === true;
  if (!key) throw new HttpError(503, 'AI songs are not set up yet (GEMINI_API_KEY)');
  if (!(await checkIdea(prompt, { key: openaiKey, fetchFn }))) {
    throw new HttpError(400, 'This song idea is not allowed. Try other words.');
  }
  const cost = full ? FULL_COST : 1;
  const refund = await takeQuota(sa, uid, cost, { now, fetchFn });
  let song;
  try {
    song = await callLyria({ prompt, full, instrumental }, { key, fetchFn });
  } catch (e) {
    await refund();
    throw e;
  }
  const rand = randomUUID().replace(/-/g, '').slice(0, 16);
  const fileKey = `audio/${uid}/ai-${now}-${rand}.${song.ext}`;
  let url;
  try {
    ({ url } = await save(fileKey, song.bytes, song.ext === 'wav' ? 'audio/wav' : 'audio/mpeg'));
  } catch (e) {
    await refund();
    throw e;
  }
  const me = await getDoc(sa, `users/${uid}`, fetchFn).catch(() => null);
  const username = typeof me?.username === 'string' ? me.username : '';
  const id = `ai_${rand}`;
  const track = {
    source: 'ai',
    ownerUid: uid,
    title: clean(body?.title, 60) || titleFrom(prompt),
    artist: username ? `@${username}` : 'AI',
    url,
    key: fileKey,
    durationMs: full ? 0 : 30000,
    lyrics: instrumental ? '' : song.lyrics,
    prompt,
    instrumental,
    uses: 0,
    hidden: false,
    createdAt: new Date(now),
  };
  await patchDoc(sa, `music/${id}`, track, {}, fetchFn);
  const { left, perDay } = await quotaOf(sa, uid, { now, fetchFn }).catch(() => ({ left: 0, perDay: limits().perDay }));
  return { id, ...track, createdAt: new Date(now).toISOString(), left, perDay };
}

// ---------------------------------------------------------------- library

export const MOODS = ['happy', 'sad', 'love', 'party', 'chill', 'epic', 'funny', 'devotional', 'workout', 'other'];
export const AUDIO_TYPES = { 'audio/mpeg': 'mp3', 'audio/mp4': 'm4a', 'audio/x-m4a': 'm4a', 'audio/aac': 'aac', 'audio/wav': 'wav', 'audio/x-wav': 'wav', 'audio/ogg': 'ogg' };

/** Admin form -> library fields (throws 400 on bad input). */
export function libraryFields(body) {
  const title = clean(body?.title, 80);
  if (!title) throw new HttpError(400, 'Song name missing');
  const artist = clean(body?.artist, 80);
  const mood = MOODS.includes(body?.mood) ? body.mood : 'other';
  const ms = Number(body?.durationMs);
  const durationMs = Number.isFinite(ms) && ms > 0 && ms < 3 * 3600 * 1000 ? Math.round(ms) : 0;
  return { title, artist, mood, durationMs };
}

/** "data:audio/mpeg;base64,..." -> { bytes, type, ext } (max 3.2 MB). */
export function decodeAudio(dataUrl) {
  const m = /^data:(audio\/[a-z0-9.+-]+);base64,([A-Za-z0-9+/=]+)$/.exec(typeof dataUrl === 'string' ? dataUrl : '');
  if (!m) throw new HttpError(400, 'Send an MP3 / M4A / WAV / OGG file');
  const ext = AUDIO_TYPES[m[1]];
  if (!ext) throw new HttpError(400, `File type not allowed: ${m[1]}`);
  const bytes = Buffer.from(m[2], 'base64');
  if (bytes.length < 1000) throw new HttpError(400, 'File is empty');
  if (bytes.length > 3.2 * MB) throw new HttpError(413, 'Too big for a direct upload (max 3 MB)');
  return { bytes, type: m[1], ext };
}

/** music/lib/... (library) or audio/<uid>/ai-... (AI) files may be deleted. */
export function musicFileKey(d) {
  const k = typeof d?.key === 'string' ? d.key : '';
  if (!k || k.includes('..')) return '';
  if (d.source === 'library' && k.startsWith('music/lib/')) return k;
  if (d.source === 'ai' && typeof d.ownerUid === 'string' && k.startsWith(`audio/${d.ownerUid}/ai-`)) return k;
  return ''; // original audio belongs to its post
}
