// POST /api/turn  {}   (v0.10.1, voice + video calls)
// -> { iceServers: [...], turn: true|false }
// TURN relays the call when the 2 phones can't connect directly (often on
// mobile data). Set ANY of these in Vercel (all free, no card needed for 1 + 2):
//
// 1) ExpressTURN (free 1000 GB / month)  https://www.expressturn.com
//      TURN_SERVER    e.g. relay1.expressturn.com:3478
//      TURN_USERNAME  the username from your ExpressTURN dashboard
//      TURN_PASSWORD  the password from your ExpressTURN dashboard
//    (works with any TURN server; TURN_SERVER may also be a comma list or
//     full turn:/turns: urls)
// 2) Metered Open Relay (free 20 GB / month)  https://www.metered.ca/tools/openrelay/
//      METERED_DOMAIN   e.g. instantgram.metered.live
//      METERED_API_KEY  the TURN API key from the Metered dashboard
// 3) Cloudflare (needs a card)
//      CLOUDFLARE_TURN_KEY_ID + CLOUDFLARE_TURN_API_TOKEN
//
// With none of them only free STUN servers are sent (calls work on most Wi-Fi).
import { requireUser } from '../lib/firebase-auth.js';
import { env, postHandler } from '../lib/http.js';

export const STUN_ONLY = [
  { urls: ['stun:stun.cloudflare.com:3478', 'stun:stun.l.google.com:19302'] },
];

/** Builds a TURN entry from a server + username + password (ExpressTURN etc.). */
export function staticTurn(server, username, password) {
  if (!server || !username || !password) return null;
  const urls = [];
  for (let s of server.split(',')) {
    s = s.trim();
    if (!s) continue;
    if (/^turns?:/i.test(s)) {
      urls.push(s);
      continue;
    }
    s = s.replace(/^[a-z]+:\/\//i, '').replace(/\/+$/, '');
    if (!s.includes(':')) s += ':3478';
    urls.push(`turn:${s}?transport=udp`, `turn:${s}?transport=tcp`);
  }
  if (urls.length === 0) return null;
  return { urls: [...new Set(urls)], username, credential: password };
}

/** Keeps only entries that look like real ICE servers. */
export function cleanIce(list) {
  if (!Array.isArray(list)) return [];
  return list.filter((e) => {
    if (!e || typeof e !== 'object') return false;
    const urls = Array.isArray(e.urls) ? e.urls : [e.urls];
    return urls.some((u) => typeof u === 'string' && /^(stun|turns?):/i.test(u));
  });
}

/** Asks Metered (Open Relay) for TURN servers near the user. */
export async function meteredIce(domain, apiKey, { fetchFn = fetch } = {}) {
  const host = domain.replace(/^https?:\/\//i, '').replace(/\/.*$/, '');
  if (!host || !apiKey) return null;
  try {
    const r = await fetchFn(
      `https://${host}/api/v1/turn/credentials?apiKey=${encodeURIComponent(apiKey)}`,
    );
    const j = await r.json().catch(() => null);
    const ice = cleanIce(j);
    if (!r.ok || ice.length === 0) {
      console.error('metered turn', r.status, JSON.stringify(j).slice(0, 300));
      return null;
    }
    return ice;
  } catch (e) {
    console.error('metered turn', e);
    return null;
  }
}

/** Asks Cloudflare for TURN passwords that expire after [ttl] seconds. */
export async function cloudflareIce(keyId, apiToken, { ttl = 14400, fetchFn = fetch } = {}) {
  try {
    const r = await fetchFn(
      `https://rtc.live.cloudflare.com/v1/turn/keys/${encodeURIComponent(keyId)}/credentials/generate-ice-servers`,
      {
        method: 'POST',
        headers: { Authorization: `Bearer ${apiToken}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ ttl }),
      },
    );
    const j = await r.json().catch(() => ({}));
    if (!r.ok || !Array.isArray(j.iceServers) || j.iceServers.length === 0) {
      console.error('cloudflare turn', r.status, JSON.stringify(j).slice(0, 300));
      return null;
    }
    return j.iceServers;
  } catch (e) {
    console.error('cloudflare turn', e);
    return null;
  }
}

/** Which TURN services are set in Vercel (used by /api/health too). */
export function turnProviders(get = env) {
  const out = [];
  if (get('TURN_SERVER') && get('TURN_USERNAME') && get('TURN_PASSWORD')) out.push('static');
  if (get('METERED_DOMAIN') && get('METERED_API_KEY')) out.push('metered');
  if (get('CLOUDFLARE_TURN_KEY_ID') && get('CLOUDFLARE_TURN_API_TOKEN')) out.push('cloudflare');
  return out;
}

/** STUN + every TURN service that is set and answers. */
export async function buildIce(get = env, { fetchFn = fetch } = {}) {
  const providers = turnProviders(get);
  const jobs = providers.map(async (p) => {
    if (p === 'static') {
      const t = staticTurn(get('TURN_SERVER'), get('TURN_USERNAME'), get('TURN_PASSWORD'));
      return t ? [t] : null;
    }
    if (p === 'metered') {
      return meteredIce(get('METERED_DOMAIN'), get('METERED_API_KEY'), { fetchFn });
    }
    return cloudflareIce(get('CLOUDFLARE_TURN_KEY_ID'), get('CLOUDFLARE_TURN_API_TOKEN'), { fetchFn });
  });
  const turn = [];
  for (const list of await Promise.all(jobs)) {
    for (const e of list || []) {
      const urls = Array.isArray(e.urls) ? e.urls : [e.urls];
      // STUN is already in STUN_ONLY; keep only relay entries
      if (urls.some((u) => typeof u === 'string' && /^turns?:/i.test(u))) turn.push(e);
    }
  }
  return { iceServers: [...STUN_ONLY, ...turn], turn: turn.length > 0 };
}

export default postHandler(async (req) => {
  await requireUser(req);
  return buildIce();
});
