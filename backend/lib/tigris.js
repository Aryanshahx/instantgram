// Tigris (S3-compatible) storage helpers.
import { randomUUID } from 'node:crypto';
import { DeleteObjectCommand, PutObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { env, HttpError, requireEnv } from './http.js';

/** Files never change (unique names) -> cache for a year. */
export const CACHE_CONTROL = 'public, max-age=31536000, immutable';

export const KINDS = ['post', 'clip', 'story', 'avatar', 'cover', 'thumb', 'audio'];

const MB = 1024 * 1024;
export const MAX_IMAGE = 15 * MB;
export const MAX_VIDEO = 150 * MB;
export const MAX_AUDIO = 20 * MB;

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
  'audio/mpeg': 'mp3',
  'audio/mp4': 'm4a',
  'audio/x-m4a': 'm4a',
  'audio/aac': 'aac',
  'audio/wav': 'wav',
  'audio/x-wav': 'wav',
  'audio/ogg': 'ogg',
};

// Posts, clips and moments: photos AND videos (v0.5.0). Music: 'audio' only.
const VIDEO_KINDS = ['post', 'clip', 'story'];

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
  const isAudio = contentType.startsWith('audio/');
  if (isVideo && !VIDEO_KINDS.includes(kind)) {
    throw new HttpError(400, 'Videos are only allowed in posts, clips and moments');
  }
  if (isAudio !== (kind === 'audio')) {
    throw new HttpError(400, 'Music must be an audio file');
  }
  const n = Number(size);
  if (!Number.isInteger(n) || n <= 0) throw new HttpError(400, 'Bad file size');
  const max = isAudio ? MAX_AUDIO : isVideo ? MAX_VIDEO : MAX_IMAGE;
  if (n > max) throw new HttpError(413, `File too big (max ${max / MB} MB)`);

  const key = `${kind}/${uid}/${Date.now()}-${randomUUID()}.${ext}`;
  const command = new PutObjectCommand({
    Bucket: requireEnv('TIGRIS_BUCKET'),
    Key: key,
    ContentType: contentType,
    ContentLength: n,
    // every file name is unique and never changes -> phones and the
    // Tigris CDN may keep it for a year (instant repeat loads)
    CacheControl: CACHE_CONTROL,
  });
  const uploadUrl = await getSignedUrl(s3(), command, {
    expiresIn: 600,
    // make sure size + type are part of the signature
    signableHeaders: new Set(['content-type', 'content-length', 'cache-control']),
  });
  return {
    uploadUrl,
    publicUrl: publicUrl(key),
    key,
    headers: { 'Content-Type': contentType, 'Cache-Control': CACHE_CONTROL },
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
