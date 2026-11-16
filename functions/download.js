// Serves the latest Upright disk image from this domain. The release lives on the
// upstream repository; this function finds the latest tag, fetches the .dmg server-side
// and streams it back, so the browser never sees a redirect or the upstream address.
//
// The latest tag comes from the redirect on /releases/latest rather than the API, which
// rate-limits shared egress IPs. The tag is cached for an hour; the body is not cached.
const REPO = "https://github.com/dpdev69/upright";
const TAG_RE = /^v\d+\.\d+\.\d+$/;
const TAG_TTL = 3600;
const UPSTREAM_HEADERS = { "User-Agent": "upright-site-download" };
const UNAVAILABLE =
  "The download is temporarily unavailable. Please try again in a few minutes, or email support@hellobasalt.dev.";

// "https://…/releases/tag/v1.1.2" -> "v1.1.2", or null for anything else.
export function tagFromLocation(location) {
  if (!location) return null;
  let path;
  try { path = new URL(location, REPO + "/").pathname; } catch { return null; }
  const m = path.match(/\/releases\/tag\/([^/]+)\/?$/);
  if (!m) return null;
  let tag;
  try { tag = decodeURIComponent(m[1]); } catch { return null; }
  return TAG_RE.test(tag) ? tag : null;
}

// "v1.1.2" -> { filename: "Upright-1.1.2.dmg", url: "…/releases/download/v1.1.2/Upright-1.1.2.dmg" }
export function assetFor(tag) {
  if (typeof tag !== "string" || !TAG_RE.test(tag)) return null;
  const filename = `Upright-${tag.slice(1)}.dmg`;
  return { filename, url: `${REPO}/releases/download/${tag}/${filename}` };
}

function unavailable() {
  return new Response(UNAVAILABLE + "\n", {
    status: 503,
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "no-store",
      "Retry-After": "300",
      "X-Robots-Tag": "noindex",
    },
  });
}

async function latestTag(origin, waitUntil) {
  const key = new Request(`${origin}/__cache/download-latest-tag`);
  try {
    const hit = await caches.default.match(key);
    if (hit) {
      const tag = (await hit.text()).trim();
      if (TAG_RE.test(tag)) return tag;
    }
  } catch { /* no cache: look it up */ }

  const res = await fetch(`${REPO}/releases/latest`, { redirect: "manual", headers: UPSTREAM_HEADERS });
  if (res.body) await res.body.cancel();
  if (res.status < 300 || res.status > 399) return null;
  const tag = tagFromLocation(res.headers.get("Location"));
  if (!tag) return null;

  try {
    const entry = new Response(tag, { headers: { "Cache-Control": `public, max-age=${TAG_TTL}` } });
    waitUntil(caches.default.put(key, entry).catch(() => {}));
  } catch { /* caching is best effort */ }
  return tag;
}

async function serve(context) {
  try {
    const origin = new URL(context.request.url).origin;
    const tag = await latestTag(origin, (p) => context.waitUntil(p));
    const asset = tag && assetFor(tag);
    if (!asset) return unavailable();

    const up = await fetch(asset.url, { redirect: "follow", headers: UPSTREAM_HEADERS });
    if (!up.ok || !up.body) {
      if (up.body) await up.body.cancel();
      return unavailable();
    }

    const headers = new Headers({
      "Content-Type": "application/x-apple-diskimage",
      "Content-Disposition": `attachment; filename="${asset.filename}"`,
      "Cache-Control": "public, max-age=3600",
      "X-Robots-Tag": "noindex",
      "X-Content-Type-Options": "nosniff",
    });
    const length = up.headers.get("Content-Length");
    if (length && /^\d+$/.test(length)) headers.set("Content-Length", length);
    return new Response(up.body, { status: 200, headers });
  } catch {
    return unavailable();
  }
}

export const onRequestGet = serve;

// Same status and headers as GET, without the body.
export async function onRequestHead(context) {
  const res = await serve(context);
  if (res.body) await res.body.cancel();
  return new Response(null, { status: res.status, headers: res.headers });
}
