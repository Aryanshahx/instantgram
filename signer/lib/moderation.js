// The same word rules as the app (lib/services/moderation.dart), so the signer can check
// what was posted even if somebody changed their app.
import { readFileSync } from "node:fs";

export const DEFAULT_WORDS = JSON.parse(readFileSync(new URL("./mod_words.json", import.meta.url), "utf8"));

const LEET = { 0: "o", 1: "i", 3: "e", 4: "a", 5: "s", 7: "t", 8: "b", "@": "a", $: "s", "!": "i", "|": "i" };
const TOKEN = /[\p{L}\p{M}\p{N}@$*!|#']+/gu;
const NOT_LETTER = /[^\p{L}\p{M}*]/gu;
const LETTER = /[\p{L}\p{M}]/u;

export const collapseRuns = (s) => {
  let out = "", last = null;
  for (const c of s) { if (c !== last) out += c; last = c; }
  return out;
};
const hasDouble = (s) => { const a = [...s]; for (let i = 1; i < a.length; i++) if (a[i] === a[i - 1]) return true; return false; };

export function normalizeToken(raw) {
  let out = "";
  for (const c of raw.replace(/^[@#]+/, "").toLowerCase()) out += LEET[c] ?? c;
  return out.replace(NOT_LETTER, "");
}

export class WordFilter {
  constructor({ blocked = [], mild = [], allow = [] }) {
    this.exact = new Map(); this.stems = new Map(); this.phrases = [];
    this.allow = new Set(allow.map((a) => String(a).trim().toLowerCase()));
    const add = (e, isBlocked) => {
      const w = String(e).trim().toLowerCase();
      if (!w || this.allow.has(w) || this.allow.has(w.replaceAll("*", ""))) return;
      if (w.includes(" ")) { if (isBlocked) this.phrases.push(w.split(/\s+/).join(" ")); return; }
      if (w.endsWith("*")) {
        const stem = normalizeToken(w.slice(0, -1));
        if (stem.length >= 3) this.stems.set(stem, isBlocked || (this.stems.get(stem) ?? false));
        return;
      }
      const n = normalizeToken(w);
      if (n) this.exact.set(n, isBlocked || (this.exact.get(n) ?? false));
    };
    for (const w of mild) add(w, false);
    for (const w of blocked) add(w, true);
  }

  matchToken(token) {
    const v = normalizeToken(token);
    if (!v || this.allow.has(v)) return null;
    if (v.includes("*")) return this.wildcard(v);
    if (this.exact.has(v)) return [v, this.exact.get(v)];
    const dbl = hasDouble(v);
    const c = dbl ? collapseRuns(v) : v;
    if (dbl) for (const [k, b] of this.exact) if (collapseRuns(k) === c) return [k, b];
    for (const [k, b] of this.stems) if (v.includes(k) || (dbl && c.includes(collapseRuns(k)))) return [k + "*", b];
    return null;
  }

  wildcard(v) {
    const letters = v.replaceAll("*", "").length;
    if (letters < 2 || letters * 2 < v.length || !LETTER.test(v[0])) return null;
    const re = new RegExp("^" + [...v].map((c) => (c === "*" ? "." : c.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))).join("") + "$", "u");
    for (const [k, b] of this.exact) if (re.test(k)) return [k, b];
    for (const [k, b] of this.stems) if ([...k].length === [...v].length && re.test(k)) return [k + "*", b];
    return null;
  }

  /** {hits:[{start,end,word,blocked}], phrases:[...], blocked, clean} */
  scan(text) {
    const toks = [...String(text || "").matchAll(TOKEN)].map((m) => ({ s: m.index, e: m.index + m[0].length, t: m[0] }));
    const hits = [], words = [];
    let i = 0;
    while (i < toks.length) {
      const n = normalizeToken(toks[i].t);
      if ([...n].length === 1) {
        let j = i, joined = "";
        while (j < toks.length) {
          const nj = normalizeToken(toks[j].t);
          if ([...nj].length !== 1) break;
          if (j > i && toks[j].s - toks[j - 1].e > 2) break;
          joined += nj; j++;
        }
        if (j - i >= 3) {
          const m = this.matchToken(joined);
          if (m) hits.push({ start: toks[i].s, end: toks[j - 1].e, word: m[0], blocked: m[1] });
          words.push(joined); i = j; continue;
        }
      }
      const m = this.matchToken(toks[i].t);
      if (m) hits.push({ start: toks[i].s, end: toks[i].e, word: m[0], blocked: m[1] });
      words.push(n); i++;
    }
    const joined = ` ${words.join(" ")} `;
    const plain = ` ${toks.map((x) => normalizeToken(x.t)).join(" ")} `; // without joining single letters
    const phrases = this.phrases.filter((p) => joined.includes(` ${p} `) || plain.includes(` ${p} `));
    return { hits, phrases, blocked: phrases.length > 0 || hits.some((h) => h.blocked), clean: !hits.length && !phrases.length };
  }
}

/** The filter with the panel's extra lists (config/moderation). */
export function filterFor(cfg) {
  const l = (v) => (Array.isArray(v) ? v.filter((x) => typeof x === "string") : []);
  return new WordFilter({
    blocked: [...DEFAULT_WORDS.blocked, ...l(cfg && cfg.blocked)],
    mild: [...DEFAULT_WORDS.mild, ...l(cfg && cfg.mild)],
    allow: l(cfg && cfg.allow),
  });
}
