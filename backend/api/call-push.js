// POST /api/call-push  { callId, action: "ring" | "cancel" }   (v0.10)
// -> { sent: number }
// Makes the called phone ring, also when the app is CLOSED (FCM push with
// high priority), or stops the ringing when the caller hangs up first.
// Needs the Vercel setting FIREBASE_SERVICE_ACCOUNT (see lib/google.js).
// Only the caller of a call that is really ringing can send it.
import { requireUser } from '../lib/firebase-auth.js';
import { HttpError, postHandler } from '../lib/http.js';
import { getDoc, sendFcm, serviceAccount } from '../lib/google.js';

const MAX_AGE_MS = 60_000;

/** The FCM messages for one call (one per phone of the person called). */
export function buildMessages(call, callId, action, tokens, now = Date.now()) {
  const data = {
    type: action === 'ring' ? 'call' : 'call_cancel',
    callId,
    callerId: String(call.callerId || ''),
    callerName: String(call.callerName || '').slice(0, 60),
    callerPhoto: String(call.callerPhoto || '').slice(0, 600),
    video: call.video === true ? '1' : '0',
    sentAt: String(now),
  };
  return tokens.map((token) => ({
    token,
    data,
    android: { priority: 'HIGH', ttl: action === 'ring' ? '45s' : '60s' },
  }));
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

export async function handle(uid, body, { sa = serviceAccount(), fetchFn = fetch } = {}) {
  const callId = typeof body.callId === 'string' ? body.callId : '';
  const action = body.action === 'cancel' ? 'cancel' : body.action === 'ring' ? 'ring' : '';
  if (!/^[A-Za-z0-9]{10,40}$/.test(callId) || !action) throw new HttpError(400, 'Bad request');
  if (!sa) {
    throw new HttpError(503, 'Ringing when the app is closed is not set up (FIREBASE_SERVICE_ACCOUNT missing)');
  }
  const call = checkCall(await getDoc(sa, `calls/${callId}`, fetchFn), uid, action);
  const push = await getDoc(sa, `pushTokens/${call.calleeId}`, fetchFn);
  const tokens = (Array.isArray(push?.tokens) ? push.tokens : [])
    .filter((t) => typeof t === 'string' && t.length > 20)
    .slice(-5);
  let sent = 0;
  for (const m of buildMessages(call, callId, action, tokens)) {
    if (await sendFcm(sa, m, fetchFn)) sent++;
  }
  return { sent };
}

export default postHandler(async (req, body) => {
  const uid = await requireUser(req);
  return handle(uid, body);
});
