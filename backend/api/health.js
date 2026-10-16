// GET /api/health  -> shows whether the server is configured.
import { env } from '../lib/http.js';
import { accessToken, checkServiceAccount } from '../lib/google.js';
import { turnProviders } from './turn.js';
import { adminPassword } from '../lib/admin.js';
import { VERSION } from '../lib/version.js';
import { moderate } from '../lib/hi.js';
import { translate } from '../lib/translate.js';

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
  // v0.18: Hyper Intelligence (OpenAI moderation). ?openai=1 tests the key.
  let hyperIntelligence = env('OPENAI_API_KEY') ? 'ok' : 'add OPENAI_API_KEY';
  if (env('OPENAI_API_KEY') && String(req.url || '').includes('openai=1')) {
    try {
      await moderate({ text: 'hello' });
      hyperIntelligence = 'ok (OpenAI accepted the key)';
    } catch (e) {
      hyperIntelligence = `OpenAI did not accept the key: ${e.message}`;
    }
  }
  // v0.20: ?translate=1 -> asks Google from this server ("See translation")
  let translation = 'ok';
  if (String(req.url || '').includes('translate=1')) {
    try {
      const r = await translate({ text: 'kya baat hai', to: 'en' });
      translation = `ok (${r.from} -> en: ${r.text})`;
    } catch (e) {
      translation = `server can't reach Google (the phone tries itself): ${e.message}`;
    }
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
      version: VERSION,
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
        // v0.14: admin website login (ADMIN_PASSWORD, 16+ letters)
        // v0.18: Hyper Intelligence = safety checks of posts, clips, moments, comments
        hyperIntelligence,
        translation,
        adminLogin: adminPassword() ? 'ok' : process.env.ADMIN_PASSWORD ? 'ADMIN_PASSWORD too short (16+)' : 'add ADMIN_PASSWORD',
      },
    }),
  );
}
