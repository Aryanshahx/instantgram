// Tigris (S3-compatible) storage helpers.
import { randomUUID } from 'node:crypto';
import { DeleteObjectCommand, PutObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { env, HttpError, requireEnv } from './http.js';

export const KINDS = ['post', 'clip', 'story', 'avatar', 'cover', 'thumb'];

const MB = 1024 * 1024;
export const MAX_IMAGE = 15 * MB;
export const MAX_VIDEO = 150 * MB;

const TYPES = {
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
  'image/heic': 'heic',
  'image/gif': 'gif',
  'video/mp4': 'mp4',
  'video/quicktime': 'mov',
  'video/webm': 'webm',
  'video/3gpp': '3gp',
  'video/x-matroska': 'mkv',
};

let client;
function s3() {
  if (!client) {
    client = new S3Client({
      region: 'auto',
      endpoint: env('TIGRIS_ENDPOINT') || 'https://t3.storage.dev',
      credentials: {
        accessKeyId: requireEnv('TIGRIS_ACCESS_KEY_ID'),
        secretAccessKey: requireEnv('TIGRIS_SECRET_ACCESS_KEY'),
      },
    });
  }
  return client;
}

export function publicUrl(key) {
  const base = env('PUBLIC_MEDIA_BASE_URL');
  if (base) return `${base.replace(/\/$/, '')}/${key}`;
  return `https://${requireEnv('TIGRIS_BUCKET')}.t3.tigrisfiles.io/${key}`;
}

/** Validates the request and returns a presigned PUT url. */
export async function createUpload({ uid, kind, contentType, size }) {
  if (!KINDS.includes(kind)) throw new HttpError(400, 'Bad upload kind');
  const ext = TYPES[contentType];
  if (!ext) throw new HttpError(400, `File type not allowed: ${contentType}`);
  const isVideo = contentType.startsWith('video/');
  if (isVideo && kind !== 'clip' && kind !== 'story') {
    throw new HttpError(400, 'Videos are only allowed for clips');
  }
  if (kind === 'clip' && !isVideo) throw new HttpError(400, 'A clip must be a video');
  const n = Number(size);
  if (!Number.isInteger(n) || n <= 0) throw new HttpError(400, 'Bad file size');
  const max = isVideo ? MAX_VIDEO : MAX_IMAGE;
  if (n > max) throw new HttpError(413, `File too big (max ${max / MB} MB)`);

  const key = `${kind}/${uid}/${Date.now()}-${randomUUID()}.${ext}`;
  const command = new PutObjectCommand({
    Bucket: requireEnv('TIGRIS_BUCKET'),
    Key: key,
    ContentType: contentType,
    ContentLength: n,
  });
  const uploadUrl = await getSignedUrl(s3(), command, {
    expiresIn: 600,
    // make sure size + type are part of the signature
    signableHeaders: new Set(['content-type', 'content-length']),
  });
  return {
    uploadUrl,
    publicUrl: publicUrl(key),
    key,
    headers: { 'Content-Type': contentType },
  };
}

/** Deletes a file, but only if it belongs to [uid]. */
export async function deleteOwned({ uid, key }) {
  if (typeof key !== 'string' || key.includes('..')) {
    throw new HttpError(400, 'Bad key');
  }
  const owned = KINDS.some((k) => key.startsWith(`${k}/${uid}/`));
  if (!owned) throw new HttpError(403, 'Not your file');
  await s3().send(new DeleteObjectCommand({ Bucket: requireEnv('TIGRIS_BUCKET'), Key: key }));
  return { deleted: true };
}
