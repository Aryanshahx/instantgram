// Verifies Firebase ID tokens (sent by the app) without the Admin SDK.
import { createRemoteJWKSet, jwtVerify } from 'jose';
import { HttpError, requireEnv } from './http.js';

const JWKS = createRemoteJWKSet(
  new URL(
    'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com',
  ),
);

/** Returns the Firebase uid of the caller, or throws 401. */
export async function requireUser(req) {
  const header = req.headers['authorization'] || '';
  const match = /^Bearer (.+)$/.exec(header);
  if (!match) throw new HttpError(401, 'Not logged in');
  const projectId = requireEnv('FIREBASE_PROJECT_ID');
  try {
    const { payload } = await jwtVerify(match[1], JWKS, {
      issuer: `https://securetoken.google.com/${projectId}`,
      audience: projectId,
      algorithms: ['RS256'],
    });
    if (!payload.sub) throw new Error('no sub');
    return payload.sub;
  } catch {
    throw new HttpError(401, 'Login expired. Please log in again.');
  }
}
