// Small helpers for Vercel Node functions.

export function send(res, status, data) {
  res.statusCode = status;
  res.setHeader('Content-Type', 'application/json');
  res.setHeader('Cache-Control', 'no-store');
  res.end(JSON.stringify(data));
}

export class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

/** Wraps a handler: allows only POST (+ OPTIONS), parses JSON, catches errors. */
export function postHandler(fn) {
  return async (req, res) => {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Headers', 'Authorization, Content-Type');
    res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
    if (req.method === 'OPTIONS') return send(res, 204, {});
    if (req.method !== 'POST') return send(res, 405, { error: 'Use POST' });
    try {
      let body = req.body;
      if (typeof body === 'string') body = body ? JSON.parse(body) : {};
      const result = await fn(req, body || {});
      return send(res, 200, result);
    } catch (e) {
      const status = e instanceof HttpError ? e.status : 500;
      if (status === 500) console.error(e);
      return send(res, status, { error: status === 500 ? 'Server error' : e.message });
    }
  };
}

export function requireEnv(name) {
  const v = process.env[name];
  if (!v) throw new HttpError(500, `Server not configured: ${name} missing`);
  return v;
}
