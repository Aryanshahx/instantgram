// v0.0.1: email code (OTP) when making a new account.
//   POST /api/u { action: 'otpSend', email }         -> { sent, resendIn }
//   POST /api/u { action: 'otpVerify', email, code } -> { otpToken }
// Then, after the Firebase account is made, the app sends the otpToken to
// POST /api/accounts { action: 'verifyEmail', otpToken } and the server
// marks the email as verified (the database rules need that for a new
// email + password profile).
// The mail is sent from Gmail: GMAIL_USER + GMAIL_APP_PASSWORD (an "App
// password" from myaccount.google.com/apppasswords, needs 2-Step
// Verification). Codes are saved only as a hash, 10 minutes, 5 tries.
import { createHash, createHmac, randomInt, timingSafeEqual } from 'node:crypto';
import nodemailer from 'nodemailer';
import { HttpError, env } from './http.js';
import { authLookupEmail, commitWrites, getDocMeta, isPreconditionError } from './google.js';

export const OTP_TTL_MS = 10 * 60_000;
export const RESEND_MS = 60_000;
export const SENDS_PER_HOUR = 5;
export const MAX_TRIES = 5;
export const TOKEN_TTL_MS = 30 * 60_000;
/** Codes one internet address may ask for per hour (all emails). */
export const IP_PER_HOUR = 12;
const ipSends = new Map();

export function _resetOtp() {
  ipSends.clear();
}

export function cleanEmail(v) {
  const s = String(v ?? '').trim().toLowerCase();
  if (s.length > 254) return '';
  return /^[^\s@]{1,64}@[^\s@]+\.[a-z0-9-]{2,}$/.test(s) ? s : '';
}

const sha = (s) => createHash('sha256').update(s).digest('hex');
/** Secret for codes + tokens, made from the server's own service key. */
const secretOf = (sa) => sha(`instantgram-otp|${sa.private_key || sa.client_email || ''}`);
const hmac = (sa, s) => createHmac('sha256', secretOf(sa)).update(s).digest('base64url');
export const otpDocPath = (email) => `emailOtp/${sha(`otp:${email}`).slice(0, 40)}`;

function same(a, b) {
  const x = Buffer.from(String(a));
  const y = Buffer.from(String(b));
  return x.length === y.length && timingSafeEqual(x, y);
}

/** Proof that [email] got the right code (30 minutes). */
export function makeToken(sa, email, now = Date.now()) {
  const p = `${email}|${now + TOKEN_TTL_MS}`;
  return `${Buffer.from(p).toString('base64url')}.${hmac(sa, `tok|${p}`)}`;
}

/** The email in a good token, '' when wrong or old. */
export function readToken(sa, token, now = Date.now()) {
  const [b, sig] = String(token || '').split('.');
  if (!b || !sig) return '';
  let p;
  try {
    p = Buffer.from(b, 'base64url').toString('utf8');
  } catch {
    return '';
  }
  if (!same(sig, hmac(sa, `tok|${p}`))) return '';
  const i = p.lastIndexOf('|');
  const email = p.slice(0, i);
  const exp = Number(p.slice(i + 1));
  return Number.isFinite(exp) && exp > now ? email : '';
}

export function gmailReady() {
  return !!(env('GMAIL_USER') && env('GMAIL_APP_PASSWORD'));
}

let transport = null;
async function gmailSend(mail) {
  transport ??= nodemailer.createTransport({
    service: 'gmail',
    auth: { user: env('GMAIL_USER'), pass: env('GMAIL_APP_PASSWORD') },
  });
  await transport.sendMail({ from: `InstantGram <${env('GMAIL_USER')}>`, ...mail });
}

export function mailFor(code) {
  return {
    subject: `${code} is your InstantGram code`,
    text: `Your InstantGram code is ${code}\n\nIt works for 10 minutes. If you didn't try to make an account, ignore this email.`,
    html: `<div style="font-family:system-ui,Roboto,Arial,sans-serif;max-width:420px;margin:auto;padding:24px;background:#0C0D12;color:#F3F4F8;border-radius:16px">
<div style="font-size:22px;font-weight:800;color:#D2FF40">InstantGram</div>
<p style="color:#9A9DA6">Your code to make your account:</p>
<div style="font-size:34px;font-weight:800;letter-spacing:8px;margin:12px 0">${code}</div>
<p style="color:#9A9DA6;font-size:13px">It works for 10 minutes. If you didn't try to make an account, ignore this email.</p>
</div>`,
  };
}

function ipAllowed(ip, now) {
  if (!ip) return true;
  const list = (ipSends.get(ip) || []).filter((t) => now - t < 3600_000);
  if (list.length >= IP_PER_HOUR) return false;
  list.push(now);
  ipSends.set(ip, list);
  if (ipSends.size > 5000) ipSends.delete(ipSends.keys().next().value);
  return true;
}

export async function otpSend(sa, body, { fetchFn = fetch, now = Date.now(), sendMail = null, ip = '' } = {}) {
  const email = cleanEmail(body?.email);
  if (!email) throw new HttpError(400, 'Enter a valid email.');
  const send = sendMail || (gmailReady() ? gmailSend : null);
  if (!send) throw new HttpError(503, 'Email codes are not set up yet. Try again later.');
  if (await authLookupEmail(sa, email, fetchFn)) {
    throw new HttpError(409, 'An account with this email already exists. Log in instead.');
  }
  const path = otpDocPath(email);
  const meta = await getDocMeta(sa, path, fetchFn);
  const d = meta?.data || {};
  const sends = (Array.isArray(d.sends) ? d.sends : []).filter((t) => typeof t === 'number' && now - t < 3600_000);
  const last = sends.length ? Math.max(...sends) : 0;
  if (now - last < RESEND_MS) {
    throw new HttpError(429, `Wait ${Math.ceil((RESEND_MS - (now - last)) / 1000)} seconds for a new code.`);
  }
  if (sends.length >= SENDS_PER_HOUR) throw new HttpError(429, 'Too many codes. Try again in an hour.');
  if (!ipAllowed(ip, now)) throw new HttpError(429, 'Too many codes. Try again in an hour.');
  const code = String(randomInt(0, 1_000_000)).padStart(6, '0');
  try {
    await commitWrites(sa, [{
      update: path,
      fields: {
        hash: hmac(sa, `code|${email}|${code}`),
        expires: now + OTP_TTL_MS,
        tries: 0,
        sends: [...sends, now],
        // for an optional Firestore TTL policy (auto delete)
        expireAt: new Date(now + 24 * 3600_000),
      },
      ...(meta?.updateTime ? { updateTime: meta.updateTime } : { mustNotExist: true }),
    }], fetchFn);
  } catch (e) {
    if (isPreconditionError(e)) throw new HttpError(429, 'Wait a moment for a new code.');
    throw e;
  }
  try {
    await send({ to: email, ...mailFor(code) });
  } catch (e) {
    console.error('otp mail', e?.message || e);
    throw new HttpError(502, "Couldn't send the email. Check the address and try again.");
  }
  return { sent: true, resendIn: RESEND_MS / 1000 };
}

export async function otpVerify(sa, body, { fetchFn = fetch, now = Date.now() } = {}) {
  const email = cleanEmail(body?.email);
  const code = String(body?.code ?? '').trim();
  if (!email) throw new HttpError(400, 'Enter a valid email.');
  if (!/^\d{6}$/.test(code)) throw new HttpError(400, 'Enter the 6 digit code.');
  const path = otpDocPath(email);
  const meta = await getDocMeta(sa, path, fetchFn);
  const d = meta?.data;
  if (!d || !d.hash || !(Number(d.expires) > now)) {
    throw new HttpError(400, 'This code has expired. Tap "Send again" for a new code.');
  }
  const tries = Number(d.tries) || 0;
  if (tries >= MAX_TRIES) throw new HttpError(429, 'Too many wrong tries. Tap "Send again" for a new code.');
  if (!same(d.hash, hmac(sa, `code|${email}|${code}`))) {
    const left = MAX_TRIES - tries - 1;
    try {
      await commitWrites(sa, [{ update: path, fields: { tries: tries + 1 }, updateTime: meta.updateTime }], fetchFn);
    } catch (e) {
      if (!isPreconditionError(e)) throw e;
    }
    throw new HttpError(400, left > 0 ? `Wrong code. ${left} ${left === 1 ? 'try' : 'tries'} left.` : 'Wrong code. Tap "Send again" for a new code.');
  }
  // used once
  try {
    await commitWrites(sa, [{ update: path, fields: { hash: '', usedAt: now }, updateTime: meta.updateTime }], fetchFn);
  } catch (e) {
    if (isPreconditionError(e)) throw new HttpError(409, 'Try again.');
    throw e;
  }
  return { otpToken: makeToken(sa, email, now) };
}

export const OTP_ACTIONS = ['otpSend', 'otpVerify'];

export async function handleOtp(sa, body, o = {}) {
  if (body?.action === 'otpSend') return otpSend(sa, body, o);
  if (body?.action === 'otpVerify') return otpVerify(sa, body, o);
  throw new HttpError(400, 'Unknown action');
}
