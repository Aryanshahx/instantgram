// POST /api/multipart  (big videos: parts upload in parallel)
//   { action: 'create', kind, contentType, size, partSize }
//      -> { key, uploadId, publicUrl, partSize, partUrls[] }
//   { action: 'complete', key, uploadId, parts: [{ PartNumber, ETag }] }
//   { action: 'abort', key, uploadId }
import { requireUser } from '../lib/firebase-auth.js';
import { HttpError, postHandler } from '../lib/http.js';
import { abortMultipart, completeMultipart, createMultipart } from '../lib/tigris.js';

export default postHandler(async (req, body) => {
  const uid = await requireUser(req);
  switch (body.action) {
    case 'create':
      return createMultipart({
        uid,
        kind: body.kind,
        contentType: body.contentType,
        size: body.size,
        partSize: body.partSize,
      });
    case 'complete':
      return completeMultipart({ uid, key: body.key, uploadId: body.uploadId, parts: body.parts });
    case 'abort':
      return abortMultipart({ uid, key: body.key, uploadId: body.uploadId });
    default:
      throw new HttpError(400, 'Bad action');
  }
});
