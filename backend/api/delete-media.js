// POST /api/delete-media  { key }  -> deletes your own file from Tigris
import { requireUser } from '../lib/firebase-auth.js';
import { postHandler } from '../lib/http.js';
import { deleteOwned } from '../lib/tigris.js';

export default postHandler(async (req, body) => {
  const uid = await requireUser(req);
  return deleteOwned({ uid, key: body.key });
});
