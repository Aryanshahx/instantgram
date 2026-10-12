// POST /api/upload-url  { kind, contentType, size }
// -> { uploadUrl, publicUrl, key, headers }
import { requireUser } from '../lib/firebase-auth.js';
import { postHandler } from '../lib/http.js';
import { createUpload } from '../lib/tigris.js';

export default postHandler(async (req, body) => {
  const uid = await requireUser(req);
  return createUpload({
    uid,
    kind: body.kind,
    contentType: body.contentType,
    size: body.size,
  });
});
