// POST /api/call-config  {}   (v0.9, voice + video calls)
// -> { appID, appSign, resourceID }
// Calls use ZEGOCLOUD. Needs the Vercel settings ZEGO_APP_ID and
// ZEGO_APP_SIGN (ZEGOCLOUD console -> your project). ZEGO_RESOURCE_ID is
// the push "Resource ID" that makes the phone ring when the app is closed.
// Only signed-in users get the values.
import { requireUser } from '../lib/firebase-auth.js';
import { env, HttpError, postHandler } from '../lib/http.js';

export function callConfig(read = env) {
  const appID = Number(read('ZEGO_APP_ID'));
  const appSign = (read('ZEGO_APP_SIGN') || '').trim();
  if (!Number.isInteger(appID) || appID <= 0 || !/^[0-9a-fA-F]{64}$/.test(appSign)) {
    return null;
  }
  return { appID, appSign, resourceID: (read('ZEGO_RESOURCE_ID') || '').trim() };
}

export default postHandler(async (req) => {
  await requireUser(req);
  const cfg = callConfig();
  if (!cfg) throw new HttpError(503, 'Calls are not set up yet (ZEGO_APP_ID / ZEGO_APP_SIGN missing)');
  return cfg;
});
