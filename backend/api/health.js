// GET /api/health  -> shows whether the server is configured.
export default function handler(req, res) {
  const need = ['TIGRIS_ACCESS_KEY_ID', 'TIGRIS_SECRET_ACCESS_KEY', 'TIGRIS_BUCKET', 'FIREBASE_PROJECT_ID'];
  const missing = need.filter((n) => !process.env[n]);
  res.setHeader('Content-Type', 'application/json');
  res.setHeader('Cache-Control', 'no-store');
  res.end(
    JSON.stringify({
      ok: missing.length === 0,
      app: 'instantgram',
      version: '0.3.0',
      bucket: process.env.TIGRIS_BUCKET || null,
      firebaseProject: process.env.FIREBASE_PROJECT_ID || null,
      missing,
    }),
  );
}
