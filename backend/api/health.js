// GET /api/health  -> shows whether the server is configured.
import { env } from '../lib/http.js';
import { accessToken, checkServiceAccount } from '../lib/google.js';
import { turnProviders } from './turn.js';

const NEED = ['TIGRIS_ACCESS_KEY_ID', 'TIGRIS_SECRET_ACCESS_KEY', 'TIGRIS_BUCKET', 'FIREBASE_PROJECT_ID'];

export default async function handler(req, res) {
  // v0.12: says exactly what is wrong with FIREBASE_SERVICE_ACCOUNT;
  // /api/health?google=1 also asks Google if the key works.
  const { sa, problem } = checkServiceAccount();
  let firebaseServiceAccount = problem || 'ok';
  if (sa && String(req.url || '').includes('google=1')) {
    try {
      await accessToken(sa);
      firebaseServiceAccount = 'ok (Google accepted the key)';
    } catch (e) {
      firebaseServiceAccount = `Google did not accept the key: create a new key and paste it again (${e.message})`;
    }
  }
  if (sa && env('FIREBASE_PROJECT_ID') && sa.project_id !== env('FIREBASE_PROJECT_ID')) {
    firebaseServiceAccount += ` (warning: key is for project ${sa.project_id}, FIREBASE_PROJECT_ID is ${env('FIREBASE_PROJECT_ID')})`;
  }
  const missing = NEED.filter((n) => !env(n));
  // Values with spaces / new lines still work (they are cleaned), but show a hint.
  const warnings = [...NEED, 'TIGRIS_ENDPOINT', 'PUBLIC_MEDIA_BASE_URL']
    .filter((n) => process.env[n] && /\s/.test(process.env[n]))
    .map((n) => `${n} has a space or new line in it (cleaned automatically)`);
  const bucket = env('TIGRIS_BUCKET');
  if (bucket && !/^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$/.test(bucket)) {
    warnings.push('TIGRIS_BUCKET should be lowercase letters, numbers and - only');
  }
  res.setHeader('Content-Type', 'application/json');
  res.setHeader('Cache-Control', 'no-store');
  res.end(
    JSON.stringify({
      ok: missing.length === 0,
      app: 'instantgram',
      version: '0.13.0',
      firebaseServiceAccount,
      bucket: bucket || null,
      firebaseProject: env('FIREBASE_PROJECT_ID') || null,
      missing,
      warnings,
      // optional features
      features: {
        gifSearch: !!env('GIPHY_API_KEY'),
        // v0.10 calls: TURN = calls also work on mobile data
        callsTurn: turnProviders().length > 0,
        turnServices: turnProviders(),
        // push = phone rings when the app is closed
        callRingWhenClosed: !!sa,
        // v0.11: "username: message" notifications (also when closed)
        messageNotifications: !!sa,
        // v0.12: likes, comments, followers, views ... notifications
        activityNotifications: !!sa,
      },
    }),
  );
}
