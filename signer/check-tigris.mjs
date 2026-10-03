// Checks your Tigris bucket end to end, the same way the app will use it:
//   1. upload a tiny test file with a signed link        (proves the keys + bucket name)
//   2. read it back from the public address, with Range  (proves the bucket is public + seeking works)
//   3. delete the test file
// Reads TIGRIS_BUCKET, TIGRIS_ACCESS_KEY_ID, TIGRIS_SECRET_ACCESS_KEY from the environment.
// Prints one line:  OK <public address>   or   BAD <what to fix>
import { presign } from "./lib/core.js";

const { TIGRIS_BUCKET: bucket, TIGRIS_ACCESS_KEY_ID: id, TIGRIS_SECRET_ACCESS_KEY: secret } = process.env;
const endpoint = process.env.TIGRIS_ENDPOINT || "t3.storage.dev";
const host = `${bucket}.${endpoint}`;
const key = `healthcheck/${Date.now()}.txt`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const link = (method) =>
  presign({ method, host, path: `/${key}`, region: "auto", service: "s3", accessKeyId: id, secret, expires: 120, date: new Date() });
const code = (body) => (body.match(/<Code>([^<]+)<\/Code>/) || [])[1] || "";
const say = (m) => { console.log(m); };

async function main() {
  if (!bucket || !id || !secret) return say("BAD the bucket name and both keys are needed.");
  if (/[A-Z.]/.test(bucket)) return say("BAD bucket names must be lower case and must not contain dots.");

  let put;
  try {
    put = await fetch(await link("PUT"), { method: "PUT", body: "instantgram-ok", headers: { "content-type": "text/plain" } });
  } catch (e) {
    return say(`BAD could not reach Tigris (${e.cause?.code || e.message}). Check the bucket name and your internet.`);
  }
  if (put.status !== 200) {
    const c = code(await put.text());
    const hint = {
      NoSuchBucket: `the bucket '${bucket}' does not exist. Check the spelling.`,
      InvalidAccessKeyId: "Tigris does not know this Access Key ID. Copy it again (it starts with tid_).",
      SignatureDoesNotMatch: "the Secret Access Key is wrong. Copy it again (it starts with tsec_).",
      AccessDenied: "the key has no write access to this bucket. In the Tigris console give the key the Editor role on this bucket.",
    }[c] || `Tigris answered ${put.status} ${c}.`;
    return say("BAD " + hint);
  }

  let found = "";
  let range = false;
  let lastStatus = 0;
  for (let attempt = 0; attempt < 4 && !found; attempt++) {
    for (const domain of ["t3.tigrisfiles.io", "t3.tigrisbucket.io", "t3.tigrisblob.io"]) {
      try {
        const res = await fetch(`https://${bucket}.${domain}/${key}`, { headers: { range: "bytes=0-9" } });
        lastStatus = res.status;
        const text = await res.text();
        if ((res.status === 206 || res.status === 200) && text.startsWith("instantgra")) {
          found = `https://${bucket}.${domain}`;
          range = res.status === 206;
          break;
        }
      } catch { /* try the next address */ }
    }
    if (!found) await sleep(1500);
  }

  await fetch(await link("DELETE"), { method: "DELETE" }).catch(() => {});

  if (!found) {
    if (lastStatus === 403 || lastStatus === 404 || lastStatus === 401)
      return say(`BAD the upload worked, but the file is not publicly readable (${lastStatus}). In the Tigris console open the bucket -> Settings -> set Access to Public. Public buckets need a payment method on the account.`);
    return say(`BAD the public address did not answer (${lastStatus || "no connection"}). Try again in a minute.`);
  }
  if (!range) return say(`OK ${found} (note: video seeking may be limited)`);
  say(`OK ${found}`);
}
main().catch((e) => say("BAD " + (e && e.message ? e.message : e)));
