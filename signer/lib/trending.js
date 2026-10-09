// Trending posts and clips for the app's "For you" feed and Clips.
// Worked out at most once an hour, when a phone finds the list older than that
// (Vercel's free plan has no hourly timer). Stored in config/trending.

const HOUR = 3600_000;
const DAY = 24 * HOUR;
const num = (v) => (typeof v === "number" && Number.isFinite(v) ? v : 0);

/** Same idea as the app: engagement over age (hours + 2) ^ 1.5. */
export function trendScore(p, nowMs) {
  const at = p.createdAt instanceof Date ? p.createdAt.getTime() : nowMs;
  const hours = Math.max(0, (nowMs - at) / HOUR);
  const eng = num(p.likeCount) + 2 * num(p.commentCount) + 3 * num(p.shareCount) + 2 * num(p.superCount) + 0.05 * num(p.viewCount);
  return eng / Math.pow(hours + 2, 1.5);
}

/** Only public, visible, non-sensitive posts can trend. */
export function canTrend(p) {
  if (!p || p.hidden === true || p.sensitive === true || p.profileOnly === true || p.authorPrivate === true) return false;
  const aud = typeof p.audience === "string" && p.audience ? p.audience : "everyone";
  if (aud !== "everyone") return false;
  if (num(p.reportWeight) >= 6 || num(p.reportCount) >= 3) return false;
  return true;
}

const isClip = (p) => p.type === "video" || p.type === "photoclip";

/** Ranks the recent posts. Returns {posts: [ids], clips: [ids]} (top 30 each, max 3 per author). */
export function rankTrending(docs, nowMs) {
  const scored = docs
    .filter((d) => canTrend(d.data))
    .map((d) => ({ id: d.id, p: d.data, s: trendScore(d.data, nowMs) }))
    .filter((x) => x.s > 0)
    .sort((a, b) => b.s - a.s);
  const pick = (rows) => {
    const per = {};
    const out = [];
    for (const r of rows) {
      const a = typeof r.p.authorId === "string" ? r.p.authorId : "";
      per[a] = (per[a] || 0) + 1;
      if (per[a] > 3) continue;
      out.push(r.id);
      if (out.length >= 30) break;
    }
    return out;
  };
  return { posts: pick(scored.filter((x) => !isClip(x.p))), clips: pick(scored.filter((x) => isClip(x.p))) };
}

/** Reads config/trending; works it out again when it is older than an hour. */
export async function trending(db, nowMs, { force = false } = {}) {
  const cur = await db.get("config/trending");
  const at = cur && cur.data.at instanceof Date ? cur.data.at.getTime() : 0;
  if (!force && nowMs - at < HOUR) return { ok: true, fresh: false, at: new Date(at).toISOString() };
  const docs = await db.query("posts", { where: [["createdAt", ">", new Date(nowMs - 2 * DAY)]], orderBy: [["createdAt", "desc"]], limit: 300 });
  const r = rankTrending(docs, nowMs);
  await db.write([{ put: "config/trending", data: { posts: r.posts, clips: r.clips, at: new Date(nowMs), scanned: docs.length } }]);
  return { ok: true, fresh: true, posts: r.posts.length, clips: r.clips.length };
}
