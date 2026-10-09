// The admin panel page: https://<your signer>.vercel.app/admin
// The page itself holds no data; everything it shows comes from /api/admin with the admin key.
import { readFileSync } from "node:fs";

const html = readFileSync(new URL("../lib/panel.html", import.meta.url), "utf8");

export default {
  fetch(request) {
    if (request.method !== "GET") return new Response("Not found", { status: 404 });
    return new Response(html, {
      headers: {
        "content-type": "text/html; charset=utf-8",
        "cache-control": "no-store",
        "x-robots-tag": "noindex, nofollow",
        "x-frame-options": "DENY",
        "referrer-policy": "no-referrer",
        "content-security-policy":
          "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src https: data:; media-src https:; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
      },
    });
  },
};
