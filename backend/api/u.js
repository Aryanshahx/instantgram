// GET /u/<username>  (rewritten to /api/u?name=<username> by vercel.json)
// Small web page for shared profile links and QR codes:
// "Open in InstantGram" opens the app (instantgram://u/<username>).
const APP_PACKAGE = 'com.hypertechlabs.instantgram';
const DOWNLOAD_URL = 'https://github.com/Aryanshahx/instantgram/releases/latest';

export function cleanName(raw) {
  const n = String(raw || '').trim().toLowerCase().replace(/^@/, '');
  return /^[a-z0-9._]{3,30}$/.test(n) ? n : '';
}

export function page(name) {
  const title = name ? `@${name} on InstantGram` : 'InstantGram';
  const appUrl = name ? `instantgram://u/${name}` : 'instantgram://';
  const intent = `intent://u/${name}#Intent;scheme=instantgram;package=${APP_PACKAGE};`
    + `S.browser_fallback_url=${encodeURIComponent(DOWNLOAD_URL)};end`;
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title}</title>
<meta property="og:title" content="${title}">
<meta property="og:description" content="See photos, clips and moments on InstantGram.">
<style>
  body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
    background:#0C0D12;color:#F3F4F8;font-family:system-ui,-apple-system,Roboto,sans-serif}
  .card{width:min(360px,88vw);background:#141720;border:1px solid #262B35;border-radius:24px;
    padding:28px 22px;text-align:center}
  .logo{font-size:30px;font-weight:800;letter-spacing:-.5px;color:#D2FF40;margin-bottom:18px}
  .avatar{width:84px;height:84px;border-radius:50%;margin:0 auto 12px;display:flex;align-items:center;
    justify-content:center;font-size:36px;font-weight:800;color:#0C0D12;
    background:linear-gradient(135deg,#C0F954,#62F0A4)}
  h1{font-size:20px;margin:0 0 6px}
  p{color:#9A9DA6;font-size:14px;margin:0 0 22px}
  a.btn{display:block;padding:14px;border-radius:14px;font-weight:700;text-decoration:none;margin-top:10px}
  .open{background:linear-gradient(135deg,#C0F954,#62F0A4);color:#0C0D12}
  .get{border:1px solid #262B35;color:#F3F4F8}
</style></head>
<body><div class="card">
  <div class="logo">InstantGram</div>
  ${name ? `<div class="avatar">${name[0].toUpperCase()}</div><h1>@${name}</h1>` : '<h1>Profile not found</h1>'}
  <p>${name ? 'Follow them on InstantGram' : 'This link is not valid.'}</p>
  ${name ? `<a class="btn open" id="open" href="${appUrl}">Open in InstantGram</a>` : ''}
  <a class="btn get" href="${DOWNLOAD_URL}">Get the app</a>
</div>
<script>
  // Android Chrome opens apps with intent:// links
  var a = document.getElementById('open');
  if (a && /Android/i.test(navigator.userAgent)) a.href = ${JSON.stringify(intent)};
</script>
</body></html>`;
}

export default function handler(req, res) {
  const url = new URL(req.url, 'http://x');
  const name = cleanName(url.searchParams.get('name'));
  res.statusCode = name ? 200 : 404;
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.setHeader('Cache-Control', 'public, max-age=300');
  res.end(page(name));
}
