// POST /api/message-push  { chatId, messageId }   (v0.11)
// -> { sent: number, muted?: bool }
// After you send a chat message the app calls this: the other person gets
// a notification "username: message" (also when the app is closed), unless
// they muted this chat. Needs FIREBASE_SERVICE_ACCOUNT (same as calls).
// Only the sender of a fresh message (< 2 minutes) can trigger it.
import { requireUser } from '../lib/firebase-auth.js';
import { HttpError, postHandler } from '../lib/http.js';
import { getDoc, notSetUp, sendFcm, serviceAccount } from '../lib/google.js';
import { prefsOf, tokensOf } from './call-push.js';

const MAX_AGE_MS = 120_000;

/** Text shown in the notification for one message. */
export function previewOf(m) {
  if (m.vanish === true) return 'New message (disappears after seen)';
  const text = String(m.text || '');
  switch (m.kind) {
    case 'image':
      return text ? `📷 ${text}` : '📷 Photo';
    case 'gif':
      return 'GIF';
    case 'voice':
      return '🎤 Voice message';
    case 'location':
      return `📍 ${m.address || 'Location'}`;
    default:
      if (m.postId) return text || 'Shared a post';
      return text || 'New message';
  }
}

export function checkMessage(m, uid, now = Date.now()) {
  if (!m) throw new HttpError(404, 'Message not found');
  if (m.senderId !== uid) throw new HttpError(403, 'Not your message');
  if (m.kind === 'call' || m.kind === 'system') throw new HttpError(409, 'No push for this message');
  const created = Date.parse(m.createdAt || '');
  if (Number.isFinite(created) && now - created > MAX_AGE_MS) {
    throw new HttpError(409, 'Message is too old');
  }
  return m;
}

export function buildMessages({ chatId, fromUid, fromName, fromPhoto, preview }, tokens) {
  const body = preview.length > 180 ? `${preview.slice(0, 180)}…` : preview;
  return tokens.map((token) => ({
    token,
    data: {
      type: 'message',
      chatId,
      fromUid,
      fromName: fromName.slice(0, 60),
      fromPhoto: fromPhoto.slice(0, 600),
    },
    android: {
      priority: 'HIGH',
      ttl: '86400s',
      notification: {
        channel_id: 'messages',
        // one notification per chat (the newest message replaces it)
        tag: `chat_${chatId}`,
        title: fromName || 'New message',
        body,
      },
    },
  }));
}

export async function handle(uid, body, { sa = serviceAccount(), fetchFn = fetch } = {}) {
  const chatId = typeof body.chatId === 'string' ? body.chatId : '';
  const messageId = typeof body.messageId === 'string' ? body.messageId : '';
  const parts = chatId.split('_');
  if (
    parts.length !== 2 ||
    !parts.every((p) => /^[A-Za-z0-9]{6,64}$/.test(p)) ||
    !/^[A-Za-z0-9]{10,40}$/.test(messageId)
  ) {
    throw new HttpError(400, 'Bad request');
  }
  if (!parts.includes(uid)) throw new HttpError(403, 'Not your chat');
  if (!sa) throw notSetUp('Notifications');
  const other = parts[0] === uid ? parts[1] : parts[0];
  if (other === uid) return { sent: 0 };
  const m = checkMessage(await getDoc(sa, `chats/${chatId}/messages/${messageId}`, fetchFn), uid);
  const prefs = await prefsOf(sa, other, fetchFn);
  if (Array.isArray(prefs.mutedChats) && prefs.mutedChats.includes(chatId)) {
    return { sent: 0, muted: true };
  }
  const [chat, tokens] = await Promise.all([
    getDoc(sa, `chats/${chatId}`, fetchFn),
    tokensOf(sa, other, fetchFn),
  ]);
  const info = (chat?.memberInfo && chat.memberInfo[uid]) || {};
  let sent = 0;
  const msgs = buildMessages(
    {
      chatId,
      fromUid: uid,
      fromName: String(info.username || ''),
      fromPhoto: String(info.photoUrl || ''),
      preview: previewOf(m),
    },
    tokens,
  );
  for (const msg of msgs) {
    if (await sendFcm(sa, msg, fetchFn)) sent++;
  }
  return { sent };
}

export default postHandler(async (req, body) => {
  const uid = await requireUser(req);
  return handle(uid, body);
});
