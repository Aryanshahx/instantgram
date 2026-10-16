// v0.19 "See translation" (Hyper Intelligence) - free Google links, no key.
// 1) clients5.google.com (Chrome dictionary link)  2) translate.googleapis.com
// Both are unofficial: if Google blocks one, the other is tried, and the
// app itself tries once more from the phone.
import { HttpError } from './http.js';

const LANG = /^[a-z]{2,3}$/;
// our codes -> Google's codes (and back)
const TO_GOOGLE = { fil: 'tl', zh: 'zh-CN', he: 'iw' };
const FROM_GOOGLE = { tl: 'fil', 'zh-cn': 'zh', 'zh-tw': 'zh', iw: 'he', jw: 'jv' };
export const MAX_TEXT = 3000;

export function fromGoogle(code) {
  const c = String(code || '').toLowerCase();
  return FROM_GOOGLE[c] || c.split('-')[0];
}

const UA = 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126 Mobile Safari/537.36';

async function postForm(fetchFn, url, text) {
  const r = await fetchFn(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8', 'User-Agent': UA },
    body: new URLSearchParams({ q: text }).toString(),
    signal: AbortSignal.timeout(8000),
  });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  const raw = await r.text();
  try {
    return JSON.parse(raw);
  } catch {
    throw new Error('Not JSON (blocked?)');
  }
}

/** [["text","src"]] or ["text"] or [["text"]] */
export function parseClients5(d) {
  const first = Array.isArray(d) ? d[0] : null;
  if (typeof first === 'string') return { text: first, from: '' };
  if (Array.isArray(first) && typeof first[0] === 'string') return { text: first[0], from: String(first[1] || '') };
  throw new Error('Unknown answer');
}

/** [[["Hola","Hello",..],["mundo","world",..]], null, "en", ...] */
export function parseGtx(d) {
  if (!Array.isArray(d) || !Array.isArray(d[0])) throw new Error('Unknown answer');
  const text = d[0].map((s) => (Array.isArray(s) && typeof s[0] === 'string' ? s[0] : '')).join('');
  if (!text) throw new Error('Empty answer');
  return { text, from: String(d[2] || '') };
}

export async function translate(body, { fetchFn = fetch } = {}) {
  const text = typeof body.text === 'string' ? body.text.trim() : '';
  const to = typeof body.to === 'string' ? body.to.toLowerCase() : '';
  if (!text || text.length > MAX_TEXT) throw new HttpError(400, 'Bad text');
  if (!LANG.test(to)) throw new HttpError(400, 'Bad language');
  const tl = encodeURIComponent(TO_GOOGLE[to] || to);
  const tries = [
    async () => parseClients5(await postForm(fetchFn, `https://clients5.google.com/translate_a/t?client=dict-chrome-ex&sl=auto&tl=${tl}`, text)),
    async () => parseGtx(await postForm(fetchFn, `https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=${tl}&dt=t`, text)),
  ];
  let last;
  for (const t of tries) {
    try {
      const r = await t();
      return { text: r.text, from: fromGoogle(r.from), to };
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
