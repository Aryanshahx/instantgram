// POST /api/message-push  { chatId, messageId }   (v0.11)
// v0.0.2: also groups (every member who did not mute it) and channels
// (one push to the channel's topic; the poster's phone is left out).
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
        icon: 'ic_stat_instantgram', // v0.13: InstantGram logo
        color: '#C6FF3D',
        // one notification per chat (the newest message replaces it)
        tag: `chat_${chatId}`,
        title: fromName || 'New message',
        body,
      },
    },
  }));
}

// v0.0.2: groups/{g_...} and channels/{ch_...}
export const GROUP_RE = /^g_[A-Za-z0-9]{20}$/;
export const CHANNEL_RE = /^ch_[A-Za-z0-9]{20}$/;

/** Runs [fn] for every item, [n] at a time. */
export async function pool(items, n, fn) {
  let next = 0;
  const workers = Array.from({ length: Math.min(n, items.length) }, async () => {
    while (next < items.length) {
      const item = items[next++];
      try {
        await fn(item);
      } catch (e) {
        console.warn('push', e?.message || e);
      }
    }
  });
  await Promise.all(workers);
}

/** One push to every follower of a channel (push topic), not to the poster. */
export function channelMessage({ chatId, fromUid, name, photo, preview }) {
  const body = preview.length > 180 ? `${preview.slice(0, 180)}…` : preview;
  return {
    condition: `'${chatId}' in topics && !('u_${fromUid}' in topics)`,
    data: {
      type: 'message',
      chatId,
      fromUid,
      fromName: name.slice(0, 60),
      fromPhoto: photo.slice(0, 600),
    },
    android: {
      priority: 'HIGH',
      ttl: '86400s',
      notification: {
        channel_id: 'messages',
        icon: 'ic_stat_instantgram',
        color: '#C6FF3D',
        tag: `chat_${chatId}`,
        title: name || 'Channel',
        body,
      },
    },
  };
}

/** Group: everyone else who did not mute it. Channel: one topic push. */
export async function handleGroup(uid, chatId, messageId, { sa, fetchFn }) {
  const channel = CHANNEL_RE.test(chatId);
  const col = channel ? 'channels' : 'groups';
  const g = await getDoc(sa, `${col}/${chatId}`, fetchFn);
  if (!g) throw new HttpError(404, 'Not found');
  const members = Array.isArray(g.members) ? g.members.filter((x) => typeof x === 'string') : [];
  const admins = Array.isArray(g.admins) ? g.admins : [];
  if (channel ? !admins.includes(uid) : !members.includes(uid)) {
    throw new HttpError(403, channel ? 'Only admins can post' : 'Not in this group');
  }
  const m = checkMessage(await getDoc(sa, `${col}/${chatId}/messages/${messageId}`, fetchFn), uid);
  const name = String(g.name || '');
  const photo = String(g.photoUrl || '');
  const preview = previewOf(m);
  if (channel) {
    const ok = await sendFcm(sa, channelMessage({ chatId, fromUid: uid, name, photo, preview }), fetchFn);
    return { sent: ok ? 1 : 0, topic: true };
  }
  const sender = String((g.memberInfo && g.memberInfo[uid] && g.memberInfo[uid].username) || '');
  const text = sender ? `${sender}: ${preview}` : preview;
  const others = members.filter((x) => x !== uid).slice(0, 256);
  let sent = 0;
  let muted = 0;
  await pool(others, 16, async (other) => {
    const prefs = await prefsOf(sa, other, fetchFn);
    if (Array.isArray(prefs.mutedChats) && prefs.mutedChats.includes(chatId)) {
      muted++;
      return;
    }
    const tokens = await tokensOf(sa, other, fetchFn);
    const msgs = buildMessages(
      { chatId, fromUid: uid, fromName: name, fromPhoto: photo, preview: text },
      tokens,
    );
    for (const msg of msgs) {
      if (await sendFcm(sa, msg, fetchFn)) sent++;
    }
  });
  return { sent, muted };
}

export async function handle(uid, body, { sa = serviceAccount(), fetchFn = fetch } = {}) {
  const chatId = typeof body.chatId === 'string' ? body.chatId : '';
  const messageId = typeof body.messageId === 'string' ? body.messageId : '';
  if (GROUP_RE.test(chatId) || CHANNEL_RE.test(chatId)) {
    if (!/^[A-Za-z0-9]{10,40}$/.test(messageId)) throw new HttpError(400, 'Bad request');
    if (!sa) throw notSetUp('Notifications');
    return handleGroup(uid, chatId, messageId, { sa, fetchFn });
  }
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
