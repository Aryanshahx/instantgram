// Hyper Intelligence (v0.18): InstantGram's safety system.
// Checks posts, clips, moments and comments with OpenAI moderation
// (model omni-moderation-latest, free) and decides:
//   ok      -> nothing happens
//   review  -> blurred ("Sensitive content · Tap to view") + admin review
//   hidden  -> only the owner sees it + admin review
//   unchecked -> OpenAI did not answer; tried again later (admin site / daily)
// Scores are kept in moderation/{id} (only the server can read it).
// Never used for chats.
import { HttpError, env } from './http.js';
import { commitWrites, getDoc, runQuery } from './google.js';
import { F, pool } from './admin.js';

export const MODEL = 'omni-moderation-latest';

/** OpenAI categories -> our groups (the admin website shows the groups). */
export const GROUPS = {
  sexual: ['sexual'],
  violence: ['violence', 'violence/graphic'],
  selfHarm: ['self-harm', 'self-harm/intent', 'self-harm/instructions'],
  hate: ['hate', 'hate/threatening'],
  harassment: ['harassment', 'harassment/threatening'],
  illicit: ['illicit', 'illicit/violent'],
};

export const GROUP_LABEL = {
  sexual: 'Sexual',
  violence: 'Violence',
  selfHarm: 'Self-harm',
  hate: 'Hate',
  harassment: 'Harassment',
  illicit: 'Illegal things',
  minors: 'Minors (urgent)',
};

/** Score from which content is blurred / hidden (admin can change them). */
export const DEFAULT_LIMITS = {
  sexual: { blur: 0.5, hide: 0.85 },
  violence: { blur: 0.5, hide: 0.85 },
  selfHarm: { blur: 0.4, hide: 0.8 },
  hate: { blur: 0.6, hide: 0.9 },
  harassment: { blur: 0.6, hide: 0.9 },
  illicit: { blur: 0.7, hide: 0.95 },
};

/** "sexual/minors" above this = always hidden + urgent. */
export const MINORS_HIDE = 0.2;

export const STATES = ['pending', 'ok', 'review', 'hidden', 'unchecked', 'blurred'];
export const KINDS = ['post', 'moment', 'comment'];

const MAX_IMAGES = 10;
const MAX_FRAME_CHARS = 700_000; // one base64 frame (~500 KB)

function clamp01(v, d) {
  const n = Number(v);
  if (!Number.isFinite(n)) return d;
  return Math.round(Math.min(1, Math.max(0.05, n)) * 100) / 100;
}

/** Makes saved / typed limits safe (hide is never below blur). */
export function cleanLimits(raw) {
  const out = {};
  for (const [g, d] of Object.entries(DEFAULT_LIMITS)) {
    const r = raw && typeof raw === 'object' ? raw[g] || {} : {};
    const blur = clamp01(r.blur, d.blur);
    const hide = Math.max(blur, clamp01(r.hide, d.hide));
    out[g] = { blur, hide };
  }
  return out;
}

export async function loadLimits(sa, fetchFn = fetch) {
  const d = await getDoc(sa, 'config/moderation', fetchFn).catch(() => null);
  return cleanLimits(d?.limits);
}

/** Highest score per group over all answers (text + every picture). */
export function groupScores(answers) {
  const out = { minors: 0 };
  for (const g of Object.keys(GROUPS)) out[g] = 0;
  for (const a of answers) {
    const s = a && typeof a === 'object' ? a : {};
    for (const [g, cats] of Object.entries(GROUPS)) {
      for (const c of cats) {
        const v = Number(s[c]);
        if (Number.isFinite(v) && v > out[g]) out[g] = Math.round(v * 1000) / 1000;
      }
    }
    const m = Number(s['sexual/minors']);
    if (Number.isFinite(m) && m > out.minors) out.minors = Math.round(m * 1000) / 1000;
  }
  return out;
}

/** Scores -> { state, sensitive, reasons, urgent } */
export function decide(scores, limits = DEFAULT_LIMITS) {
  const reasons = [];
  let hide = false;
  for (const [g, l] of Object.entries(cleanLimits(limits))) {
    const v = Number(scores[g]) || 0;
    if (v >= l.hide) hide = true;
    if (v >= l.blur) reasons.push(g);
  }
  const urgent = (Number(scores.minors) || 0) >= MINORS_HIDE;
  if (urgent) {
    hide = true;
    reasons.unshift('minors');
  }
  const state = hide ? 'hidden' : reasons.length ? 'review' : 'ok';
  return { state, sensitive: state !== 'ok', reasons, urgent };
}

/** One OpenAI call. -> category_scores, or null when OpenAI refused this picture. */
async function ask(input, key, fetchFn) {
  let r;
  try {
    r = await fetchFn('https://api.openai.com/v1/moderations', {
      method: 'POST',
      headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ model: MODEL, input }),
    });
  } catch (e) {
    throw new HttpError(503, `OpenAI not reachable (${e?.message || e})`);
  }
  const j = await r.json().catch(() => ({}));
  if (r.ok && Array.isArray(j.results) && j.results[0]) return j.results[0].category_scores || {};
  // a broken / unreachable picture: skip it, the rest still counts
  if (r.status === 400 && typeof input !== 'string') {
    console.warn('openai skipped a picture', j?.error?.message || '');
    return null;
  }
  if (r.status === 401) throw new HttpError(503, 'OPENAI_API_KEY is wrong (OpenAI said 401)');
  throw new HttpError(503, `OpenAI error ${r.status} ${j?.error?.message || ''}`.trim());
}

/**
 * Checks text + pictures (urls or data:image/jpeg;base64,...).
 * Every picture is its own call (safe for all OpenAI limits).
 * Throws 503 when OpenAI can't answer -> the item is "unchecked".
 */
export async function moderate({ text = '', images = [] }, { key = env('OPENAI_API_KEY'), fetchFn = fetch } = {}) {
  if (!key) throw new HttpError(503, 'Add OPENAI_API_KEY in Vercel');
  const jobs = [];
  const t = String(text || '').trim();
  if (t) jobs.push(t.slice(0, 8000));
  for (const url of images.slice(0, MAX_IMAGES)) jobs.push([{ type: 'image_url', image_url: { url } }]);
  if (!jobs.length) return [];
  const answers = await pool(jobs, 4, (input) => ask(input, key, fetchFn));
  const ok = answers.filter(Boolean);
  if (!ok.length && jobs.length) throw new HttpError(503, 'OpenAI could not read any picture');
  return ok;
}

function s(v) {
  return typeof v === 'string' ? v : '';
}

function overlayTexts(o) {
  const list = Array.isArray(o?.overlays) ? o.overlays : [];
  return list.filter((x) => x && x.kind === 'text').map((x) => s(x.text));
}

/** Frames sent by the app (3 per video): only small jpeg / png / webp. */
export function cleanFrames(frames) {
  if (!Array.isArray(frames)) return [];
  return frames
    .filter((f) => typeof f === 'string' && /^data:image\/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$/.test(f) && f.length <= MAX_FRAME_CHARS)
    .slice(0, 6);
}

/** What to check for a document: { text, images } */
export function inputsOf(kind, d, frames = []) {
  const images = [];
  const add = (u) => {
    if (typeof u === 'string' && /^https:\/\//.test(u) && !images.includes(u)) images.push(u);
  };
  let text = '';
  if (kind === 'comment') {
    text = s(d.text);
    add(d.imageUrl); // GIFs come from GIPHY (already rated) -> not sent
  } else if (kind === 'moment') {
    text = overlayTexts(d).join('\n');
    if (d.type !== 'video') add(d.mediaUrl);
  } else {
    const media = Array.isArray(d.media) && d.media.length ? d.media : [{ url: d.mediaUrl, type: d.type === 'clip' ? 'video' : 'photo', thumbUrl: d.thumbUrl }];
    text = [s(d.caption), ...media.flatMap(overlayTexts)].filter(Boolean).join('\n');
    add(d.thumbUrl);
    for (const m of media) {
      if (images.length >= MAX_IMAGES - frames.length) break;
      if (m?.type === 'video') add(m.thumbUrl);
      else add(m?.url);
    }
  }
  return { text, images: [...images.slice(0, Math.max(0, MAX_IMAGES - frames.length)), ...frames] };
}

export function pathOf(kind, id, postId = '') {
  if (kind === 'comment') return `posts/${postId}/comments/${id}`;
  return kind === 'moment' ? `stories/${id}` : `posts/${id}`;
}

/** moderation/{this id} */
export function modId(kind, id, postId = '') {
  if (kind === 'comment') return `c_${postId}_${id}`;
  return `${kind === 'moment' ? 'm' : 'p'}_${id}`;
}

/** Fields written on the post / moment / comment. */
export function targetFields(kind, state, reasons, now) {
  const sensitive = state === 'review' || state === 'hidden' || state === 'blurred';
  if (kind === 'comment') return { sensitive, hidden: state === 'hidden', modReasons: reasons };
  return { sensitive, modState: state, modReasons: reasons, modAt: new Date(now) };
}

/** Is it already decided (no new OpenAI call needed)? */
export function decided(kind, d) {
  if (kind === 'comment') return typeof d.sensitive === 'boolean';
  return ['ok', 'review', 'hidden', 'blurred'].includes(d.modState);
}

/**
 * Checks one item and saves the result.
 * -> { state, reasons, sensitive }
 */
export async function checkItem(sa, { kind, id, postId = '', doc = null, frames = [], source = 'app', now = Date.now() }, { fetchFn = fetch, key = env('OPENAI_API_KEY'), limits = null } = {}) {
  const path = pathOf(kind, id, postId);
  const d = doc || (await getDoc(sa, path, fetchFn));
  if (!d) throw new HttpError(404, 'Not found (maybe deleted)');
  const inputs = inputsOf(kind, d, cleanFrames(frames));
  const mid = modId(kind, id, postId);
  const base = {
    kind: kind === 'post' ? (d.type === 'clip' ? 'clip' : 'post') : kind,
    targetId: id,
    postId: kind === 'comment' ? postId : '',
    authorId: s(d.authorId),
    authorUsername: s(d.authorUsername).slice(0, 40),
    text: inputs.text.slice(0, 400),
    preview: inputs.images.find((u) => u.startsWith('https://')) || '',
    images: inputs.images.length,
    source,
    at: new Date(now),
  };
  let answers;
  try {
    answers = await moderate(inputs, { key, fetchFn });
  } catch (e) {
    const error = String(e?.message || e).slice(0, 300);
    const writes = [{ update: `moderation/${mid}`, fields: { ...base, state: 'unchecked', reasons: [], scores: {}, open: true, error } }];
    if (kind !== 'comment') writes.push({ update: path, fields: { modState: 'unchecked', modAt: new Date(now) }, mustExist: true });
    await commitWrites(sa, writes, fetchFn).catch((w) => console.warn('hi unchecked save', w?.message || w));
    return { state: 'unchecked', reasons: [], sensitive: false, error };
  }
  const scores = groupScores(answers);
  const r = decide(scores, limits || (await loadLimits(sa, fetchFn)));
  const writes = [{ update: path, fields: targetFields(kind, r.state, r.reasons, now), mustExist: true }];
  if (r.state !== 'ok') {
    writes.push({ update: `moderation/${mid}`, fields: { ...base, state: r.state, reasons: r.reasons, scores, urgent: r.urgent, open: true, error: '' } });
  } else if (d.modState === 'unchecked') {
    // it was waiting in the admin list: now fine -> out of the list
    writes.push({ update: `moderation/${mid}`, fields: { ...base, state: 'ok', reasons: [], scores, open: false, error: '' } });
  }
  try {
    await commitWrites(sa, writes, fetchFn);
  } catch (e) {
    // deleted while we checked -> nothing to save
    console.warn('hi save', e?.message || e);
  }
  return { state: r.state, reasons: r.reasons, sensitive: r.sensitive };
}

/**
 * Tries again everything not checked yet (posts + moments older than
 * 2 minutes that are "pending", and "unchecked" ones). Max [limit] items.
 */
export async function sweep(sa, { limit = 12, now = Date.now(), fetchFn = fetch, key = env('OPENAI_API_KEY') } = {}) {
  if (!key) return { checked: 0, left: 0, error: 'Add OPENAI_API_KEY in Vercel' };
  const found = [];
  for (const [coll, kind] of [['posts', 'post'], ['stories', 'moment']]) {
    for (const st of ['pending', 'unchecked']) {
      const rows = await runQuery(sa, { from: [{ collectionId: coll }], where: F.eq('modState', F.s(st)), limit: 40 }, '', fetchFn).catch(() => []);
      for (const r of rows) {
        const at = Date.parse(r.data.createdAt || '') || 0;
        if (st === 'pending' && now - at < 120_000) continue; // the app is still on it
        if (kind === 'moment' && Date.parse(r.data.expiresAt || '') < now) continue; // gone anyway
        found.push({ kind, id: r.id, doc: r.data });
      }
    }
  }
  const todo = found.slice(0, limit);
  const limits = await loadLimits(sa, fetchFn);
  const results = await pool(todo, 3, (x) =>
    checkItem(sa, { ...x, source: 'sweep', now }, { fetchFn, key, limits }).catch((e) => ({ state: 'error', error: String(e?.message || e) })),
  );
  const count = (st) => results.filter((r) => r.state === st).length;
  return { checked: results.length, left: found.length - todo.length, ok: count('ok'), review: count('review'), hidden: count('hidden'), unchecked: count('unchecked') };
}
