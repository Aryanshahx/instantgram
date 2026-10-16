// v0.18: one function for all media uploads (Vercel's free plan allows
// max 12 functions). The old addresses still work (vercel.json rewrites):
//   POST /api/upload-url    { kind, contentType, size }
//        -> { uploadUrl, publicUrl, key, headers }
//   POST /api/delete-media  { key }  -> deletes your own file
//   POST /api/multipart     (big videos: parts upload in parallel)
//     { action: 'create', kind, contentType, size, partSize }
//        -> { key, uploadId, publicUrl, partSize, partUrls[] }
//     { action: 'complete', key, uploadId, parts: [{ PartNumber, ETag }] }
//     { action: 'abort', key, uploadId }
//     { action: 'sign', key, uploadId, parts: [3, 4] } -> { partUrls: { 3: url } }
import { requireUser } from '../lib/firebase-auth.js';
import { HttpError, postHandler } from '../lib/http.js';
import {
  abortMultipart,
  completeMultipart,
  createMultipart,
  createUpload,
  deleteOwned,
  signParts,
} from '../lib/tigris.js';

/** Which job: ?op=upload | delete | multipart (set by the rewrites). */
export function opOf(req) {
  const q = req.query && typeof req.query.op === 'string' ? req.query.op : '';
  if (q) return q;
  try {
    return new URL(req.url || '/', 'http://x').searchParams.get('op') || '';
  } catch {
    return '';
  }
}

export function multipart(uid, body, t = { abortMultipart, completeMultipart, createMultipart, signParts }) {
  switch (body.action) {
    case 'create':
      return t.createMultipart({
        uid,
        kind: body.kind,
        contentType: body.contentType,
        size: body.size,
        partSize: body.partSize,
      });
    case 'complete':
      return t.completeMultipart({ uid, key: body.key, uploadId: body.uploadId, parts: body.parts });
    case 'sign':
      return t.signParts({ uid, key: body.key, uploadId: body.uploadId, parts: body.parts });
    case 'abort':
      return t.abortMultipart({ uid, key: body.key, uploadId: body.uploadId });
    default:
      throw new HttpError(400, 'Bad action');
  }
}

export async function handle(req, body, { user = requireUser } = {}) {
  const op = opOf(req);
  if (!['upload', 'delete', 'multipart'].includes(op)) throw new HttpError(404, 'Unknown media job');
  const uid = await user(req);
  if (op === 'upload') {
    return createUpload({ uid, kind: body.kind, contentType: body.contentType, size: body.size });
  }
  if (op === 'delete') return deleteOwned({ uid, key: body.key });
  return multipart(uid, body);
}

export default postHandler((req, body) => handle(req, body));
