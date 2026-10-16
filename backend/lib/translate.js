// "See translation" (Hyper Intelligence) - free Google links, no key.
// v0.19: 1) clients5.google.com  2) translate.googleapis.com (gtx)
// v0.20: + translate-pa.googleapis.com (Google's website translator), and
//   only the words are sent: emojis, #tags, @names, links and line breaks
//   stay exactly as written (Google used to change 😍 into 👍).
// All are unofficial: if Google blocks one, the next is tried, and the
// app itself tries once more from the phone.
import { HttpError } from './http.js';

const LANG = /^[a-z]{2,3}$/;
// our codes -> Google's codes (and back)
const TO_GOOGLE = { fil: 'tl', zh: 'zh-CN', he: 'iw' };
const FROM_GOOGLE = { tl: 'fil', 'zh-cn': 'zh', 'zh-tw': 'zh', iw: 'he', jw: 'jv' };
export const MAX_TEXT = 3000;
const MAX_PARTS = 60;
const WAIT_MS = 5000;
// the public key of Google's free website translator
const PA_KEY = 'AIzaSyATBXajvzQLTDHEQbcpq0Ihe0vWDHmO520';

export function fromGoogle(code) {
  const c = String(code || '').toLowerCase();
  return FROM_GOOGLE[c] || c.split('-')[0];
}

const UA = 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126 Mobile Safari/537.36';

// ------------------------------------------------------------ parts

const KEEP = /(https?:\/\/\S+|www\.\S+|[@#][\p{L}\p{M}\p{N}_.]+|(?:[\p{Extended_Pictographic}\u{1F1E6}-\u{1F1FF}\u{1F3FB}-\u{1F3FF}\u200D\uFE0F\u20E3])+|\n+)/u;
const LETTER = /\p{L}/u;

/**
 * Text -> parts. { keep: 'text as is' } or { lead, core, trail } (core is
 * sent to Google, lead / trail = spaces around it).
 */
export function splitText(text) {
  const out = [];
  // split() with one ( ) group: odd places = the kept bits
  String(text).split(KEEP).forEach((piece, i) => {
    if (!piece) return;
    if (i % 2 === 1) {
      out.push({ keep: piece });
      return;
    }
    const m = /^(\s*)([\s\S]*?)(\s*)$/.exec(piece);
    if (!LETTER.test(m[2])) out.push({ keep: piece });
    else out.push({ lead: m[1], core: m[2], trail: m[3] });
  });
  return out;
}

/** Parts + translated cores (same order) -> text. */
export function joinText(parts, cores) {
  let i = 0;
  return parts.map((p) => (p.keep !== undefined ? p.keep : `${p.lead}${cores[i++] ?? p.core}${p.trail}`)).join('');
}

/** "Bahut ..." -> "This ..." (Google sometimes starts with a small letter). */
export function keepCapital(orig, out) {
  const a = orig.charAt(0);
  const b = out.charAt(0);
  if (a && a !== a.toLowerCase() && b && b === b.toLowerCase() && b !== b.toUpperCase()) {
    return b.toUpperCase() + out.slice(1);
  }
  return out;
}

/** Most used source language (by length). */
function mainFrom(cores, froms) {
  const w = {};
  cores.forEach((c, i) => {
    const f = froms[i];
    if (f) w[f] = (w[f] || 0) + c.length;
  });
  return Object.keys(w).sort((a, b) => w[b] - w[a])[0] || '';
}

// ------------------------------------------------------------ Google

async function call(fetchFn, url, init) {
  const r = await fetchFn(url, { ...init, signal: AbortSignal.timeout(WAIT_MS) });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  const raw = await r.text();
  try {
    return JSON.parse(raw);
  } catch {
    throw new Error('Not JSON (blocked?)');
  }
}

function form(list) {
  const p = new URLSearchParams();
  for (const q of list) p.append('q', q);
  return p.toString();
}

const FORM = { 'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8', 'User-Agent': UA };

/** One entry: ["text","src"] or "text" or ["text"] */
function c5Entry(e) {
  if (typeof e === 'string') return { text: e, from: '' };
  if (Array.isArray(e) && typeof e[0] === 'string') return { text: e[0], from: String(e[1] || '') };
  throw new Error('Unknown answer');
}

/** [["text","src"]] or ["text"] or [["text"]] (one text) */
export function parseClients5(d) {
  const first = Array.isArray(d) ? d[0] : null;
  return c5Entry(first);
}

/** Many texts -> [{text, from}] in the same order. */
export function parseClients5Many(d, n) {
  if (!Array.isArray(d)) throw new Error('Unknown answer');
  if (n === 1) return [parseClients5(d)];
  if (d.length !== n) throw new Error('Wrong answer size');
  return d.map(c5Entry);
}

/** [[[\"Hola\",\"Hello\",..],[\"mundo\",\"world\",..]], null, \"en\", ...] */
export function parseGtx(d) {
  if (!Array.isArray(d) || !Array.isArray(d[0])) throw new Error('Unknown answer');
  const text = d[0].map((s) => (Array.isArray(s) && typeof s[0] === 'string' ? s[0] : '')).join('');
  if (!text) throw new Error('Empty answer');
  return { text, from: String(d[2] || '') };
}

const ENT = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' };
export function unescapeHtml(s) {
  return String(s).replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (all, e) => {
    if (e[0] === '#') {
      const n = e[1] === 'x' || e[1] === 'X' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
      return Number.isFinite(n) ? String.fromCodePoint(n) : all;
    }
    return ENT[e.toLowerCase()] ?? all;
  });
}
const escapeHtml = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

/** [["t1","t2"],["hi","hi"]] */
export function parsePa(d, n) {
  if (!Array.isArray(d) || !Array.isArray(d[0]) || d[0].length !== n) throw new Error('Unknown answer');
  const froms = Array.isArray(d[1]) ? d[1] : [];
  return d[0].map((t, i) => {
    if (typeof t !== 'string') throw new Error('Unknown answer');
    return { text: unescapeHtml(t), from: String(froms[i] || '') };
  });
}

export async function translate(body, { fetchFn = fetch } = {}) {
  const text = typeof body.text === 'string' ? body.text.trim() : '';
  const to = typeof body.to === 'string' ? body.to.toLowerCase() : '';
  if (!text || text.length > MAX_TEXT) throw new HttpError(400, 'Bad text');
  if (!LANG.test(to)) throw new HttpError(400, 'Bad language');
  const gl = TO_GOOGLE[to] || to;
  const tl = encodeURIComponent(gl);
  let parts = splitText(text);
  let cores = parts.filter((p) => p.keep === undefined).map((p) => p.core);
  if (!cores.length) return { text, from: '', to };
  if (cores.length > MAX_PARTS) {
    parts = [{ lead: '', core: text, trail: '' }];
    cores = [text];
  }
  const tries = [
    async () => parseClients5Many(
      await call(fetchFn, `https://clients5.google.com/translate_a/t?client=dict-chrome-ex&sl=auto&tl=${tl}`, { method: 'POST', headers: FORM, body: form(cores) }),
      cores.length,
    ),
    async () => parsePa(
      await call(fetchFn, 'https://translate-pa.googleapis.com/v1/translateHtml', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json+protobuf', 'X-Goog-API-Key': PA_KEY, 'User-Agent': UA },
        body: JSON.stringify([[cores.map(escapeHtml), 'auto', gl], 'wt_lib']),
      }),
      cores.length,
    ),
    // last: the whole text at once (emojis may change)
    async () => {
      const r = parseGtx(await call(fetchFn, `https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=${tl}&dt=t`, { method: 'POST', headers: FORM, body: form([text]) }));
      return [{ ...r, whole: true }];
    },
  ];
  let last;
  for (const t of tries) {
    try {
      const r = await t();
      if (r.length === 1 && r[0].whole) return { text: r[0].text, from: fromGoogle(r[0].from), to };
      const out = joinText(parts, r.map((x, i) => keepCapital(cores[i], x.text)));
      return { text: out, from: fromGoogle(mainFrom(cores, r.map((x) => x.from))), to };
    } catch (e) {
      last = e;
    }
  }
  console.error('translate failed', last?.message);
  throw new HttpError(502, 'Translation is not available right now');
}

// small per-user limit (one server copy): 120 translations / 10 minutes
const used = new Map();
export function allowTranslate(uid, now = Date.now()) {
  const list = (used.get(uid) || []).filter((t) => now - t < 10 * 60 * 1000);
  if (list.length >= 120) return false;
  list.push(now);
  used.set(uid, list);
  if (used.size > 5000) used.clear();
  return true;
}
