// Tigris (S3-compatible) storage helpers.
import { randomUUID } from 'node:crypto';
import {
  AbortMultipartUploadCommand,
  CompleteMultipartUploadCommand,
  CreateMultipartUploadCommand,
  DeleteObjectCommand,
  PutObjectCommand,
  S3Client,
  UploadPartCommand,
} from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { env, HttpError, requireEnv } from './http.js';

/** Files never change (unique names) -> cache for a year. */
export const CACHE_CONTROL = 'public, max-age=31536000, immutable';

export const KINDS = ['post', 'clip', 'story', 'avatar', 'cover', 'thumb', 'audio'];

const MB = 1024 * 1024;
export const MAX_IMAGE = 15 * MB;
export const MAX_VIDEO = 500 * MB;
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

/** Checks kind / type / size. Returns { ext, n } or throws HttpError. */
function checkUpload({ kind, contentType, size }) {
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
  return { ext, n };
}

function newKey(kind, uid, ext) {
  return `${kind}/${uid}/${Date.now()}-${randomUUID()}.${ext}`;
}

/** Validates the request and returns a presigned PUT url. */
export async function createUpload({ uid, kind, contentType, size }) {
  const { ext, n } = checkUpload({ kind, contentType, size });
  const key = newKey(kind, uid, ext);
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

// ---------------- multipart (big videos, parts in parallel) ----------------

const MIN_PART = 5 * MB;
const MAX_PARTS = 1000;

/** Your own key only: "<kind>/<uid>/..." */
function ownKey(uid, key) {
  if (typeof key !== 'string' || key.includes('..')) throw new HttpError(400, 'Bad key');
  if (!KINDS.some((k) => key.startsWith(`${k}/${uid}/`))) throw new HttpError(403, 'Not your file');
  return key;
}

/** Starts a multipart upload and signs one PUT url per part. */
export async function createMultipart({ uid, kind, contentType, size, partSize }) {
  const { ext, n } = checkUpload({ kind, contentType, size });
  const ps = Math.max(MIN_PART, Number(partSize) || 8 * MB);
  const count = Math.ceil(n / ps);
  if (count < 1 || count > MAX_PARTS) throw new HttpError(400, 'Bad part size');
  const Bucket = requireEnv('TIGRIS_BUCKET');
  const key = newKey(kind, uid, ext);
  const created = await s3().send(new CreateMultipartUploadCommand({
    Bucket, Key: key, ContentType: contentType, CacheControl: CACHE_CONTROL,
  }));
  const uploadId = created.UploadId;
  const partUrls = await Promise.all(
    Array.from({ length: count }, (_, i) => getSignedUrl(
      s3(),
      new UploadPartCommand({ Bucket, Key: key, UploadId: uploadId, PartNumber: i + 1 }),
      { expiresIn: 3600 },
    )),
  );
  return { key, uploadId, publicUrl: publicUrl(key), partSize: ps, partUrls };
}

export async function completeMultipart({ uid, key, uploadId, parts }) {
  ownKey(uid, key);
  if (typeof uploadId !== 'string' || !uploadId) throw new HttpError(400, 'Bad upload id');
  if (!Array.isArray(parts) || parts.length < 1 || parts.length > MAX_PARTS) {
    throw new HttpError(400, 'Bad parts');
  }
  const Parts = parts.map((p, i) => {
    const PartNumber = Number(p && p.PartNumber);
    const ETag = String((p && p.ETag) || '');
    if (PartNumber !== i + 1 || !ETag) throw new HttpError(400, 'Bad parts');
    return { PartNumber, ETag };
  });
  await s3().send(new CompleteMultipartUploadCommand({
    Bucket: requireEnv('TIGRIS_BUCKET'), Key: key, UploadId: uploadId,
    MultipartUpload: { Parts },
  }));
  return { done: true, publicUrl: publicUrl(key), key };
}

export async function abortMultipart({ uid, key, uploadId }) {
  ownKey(uid, key);
  if (typeof uploadId !== 'string' || !uploadId) throw new HttpError(400, 'Bad upload id');
  await s3().send(new AbortMultipartUploadCommand({
    Bucket: requireEnv('TIGRIS_BUCKET'), Key: key, UploadId: uploadId,
  }));
  return { aborted: true };
}
