// POST /api/call-push  { callId, action: "ring" | "cancel" }   (v0.10)
//                      { action: "test" }                       (v0.11)
// -> { sent: number, tokens?: number, muted?: bool }
// Makes the called phone ring, also when the app is CLOSED (FCM push with
// high priority), or stops the ringing when the caller hangs up first.
// v0.11:
//  - muted calls (the person called muted your calls): no ringing, a quiet
//    notification "Voice call from X" instead (the app shows a silent
//    call screen when it is open)
//  - "test": rings YOUR phone after 6 seconds (Settings -> Calls check)
// Needs the Vercel setting FIREBASE_SERVICE_ACCOUNT (see lib/google.js).
// Only the caller of a call that is really ringing can send it.
import { requireUser } from '../lib/firebase-auth.js';
import { HttpError, postHandler } from '../lib/http.js';
import { getDoc, notSetUp, sendFcm, serviceAccount } from '../lib/google.js';

const MAX_AGE_MS = 60_000;
export const TEST_DELAY_MS = 6000;

/** The FCM messages for one call (one per phone of the person called). */
export function buildMessages(call, callId, action, tokens, now = Date.now(), { muted = false } = {}) {
  const data = {
    type: action === 'ring' ? 'call' : 'call_cancel',
    callId,
    callerId: String(call.callerId || ''),
    callerName: String(call.callerName || '').slice(0, 60),
    callerPhoto: String(call.callerPhoto || '').slice(0, 600),
    video: call.video === true ? '1' : '0',
    sentAt: String(now),
    ...(muted ? { muted: '1' } : {}),
  };
  const what = call.video === true ? 'Video call' : 'Voice call';
  const name = data.callerName || 'Someone';
  return tokens.map((token) => {
    const android = { priority: 'HIGH', ttl: action === 'ring' ? '45s' : '60s' };
    if (muted) {
      // quiet notification (channel "calls_muted": no sound, no vibration);
      // the same tag = the "missed" one replaces the "calling" one
      android.notification = {
        channel_id: 'calls_muted',
        icon: 'ic_stat_instantgram', // v0.13: InstantGram logo
        color: '#C6FF3D',
        tag: `call_${callId}`,
        title: action === 'ring' ? `${what} from ${name}` : `Missed ${what.toLowerCase()}`,
        body: action === 'ring' ? 'Muted call · tap to answer' : `From ${name}`,
      };
    }
    return { token, data, android };
  });
}

/** Checks the request; returns the call or throws. */
export function checkCall(call, uid, action, now = Date.now()) {
  if (!call) throw new HttpError(404, 'Call not found');
  if (call.callerId !== uid) throw new HttpError(403, 'Not your call');
  if (action === 'ring') {
    if (call.status !== 'ringing') throw new HttpError(409, 'Call is not ringing');
    const created = Date.parse(call.createdAt || '');
    if (Number.isFinite(created) && now - created > MAX_AGE_MS) {
      throw new HttpError(409, 'Call is too old');
    }
  }
  return call;
}

/** Push tokens of [uid] (last 5 phones). */
export async function tokensOf(sa, uid, fetchFn = fetch) {
  const push = await getDoc(sa, `pushTokens/${uid}`, fetchFn);
  return (Array.isArray(push?.tokens) ? push.tokens : [])
    .filter((t) => typeof t === 'string' && t.length > 20)
    .slice(-5);
}

/** prefs/{uid} (v0.11): mutedChats, mutedCalls ... ({} when missing). */
export async function prefsOf(sa, uid, fetchFn = fetch) {
  try {
    return (await getDoc(sa, `prefs/${uid}`, fetchFn)) || {};
  } catch {
    return {};
  }
}

export function callsMuted(prefs, callerId) {
  return Array.isArray(prefs?.mutedCalls) && prefs.mutedCalls.includes(callerId);
}

/** "test": rings your own phone (after a short wait, so you can close the app). */
export function testMessages(uid, tokens, now = Date.now()) {
  const data = {
    type: 'call_test',
    callId: `test${now}`,
    callerId: uid,
    callerName: 'InstantGram test call',
    callerPhoto: '',
    video: '0',
    sentAt: String(now),
  };
  return tokens.map((token) => ({ token, data, android: { priority: 'HIGH', ttl: '30s' } }));
}

export async function handle(
  uid,
  body,
  { sa = serviceAccount(), fetchFn = fetch, sleep = (ms) => new Promise((r) => setTimeout(r, ms)) } = {},
) {
  const action = ['ring', 'cancel', 'test'].includes(body.action) ? body.action : '';
  if (!action) throw new HttpError(400, 'Bad request');
  if (!sa) {
    throw notSetUp('Ringing when the app is closed');
  }
  if (action === 'test') {
    const tokens = await tokensOf(sa, uid, fetchFn);
    if (tokens.length === 0) return { sent: 0, tokens: 0 };
    await sleep(TEST_DELAY_MS);
    let sent = 0;
    for (const m of testMessages(uid, tokens)) {
      if (await sendFcm(sa, m, fetchFn)) sent++;
    }
    return { sent, tokens: tokens.length };
  }
  const callId = typeof body.callId === 'string' ? body.callId : '';
  if (!/^[A-Za-z0-9]{10,40}$/.test(callId)) throw new HttpError(400, 'Bad request');
  const call = checkCall(await getDoc(sa, `calls/${callId}`, fetchFn), uid, action);
  const [tokens, prefs] = await Promise.all([
    tokensOf(sa, call.calleeId, fetchFn),
    prefsOf(sa, call.calleeId, fetchFn),
  ]);
  const muted = callsMuted(prefs, uid);
  let sent = 0;
  for (const m of buildMessages(call, callId, action, tokens, Date.now(), { muted })) {
    if (await sendFcm(sa, m, fetchFn)) sent++;
  }
  return { sent, muted };
}

export default postHandler(async (req, body) => {
  const uid = await requireUser(req);
  return handle(uid, body);
});
