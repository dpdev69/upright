// Gives each HTML response a fresh CSP nonce. Cloudflare's Bot Fight Mode injects an
// inline script into every page on the zone and copies the nonce from script-src onto
// it, so the script runs without 'unsafe-inline'. Our own scripts load from /assets/,
// and the one-line inline "js" class script is allowed by its hash in _headers.
//
// Links pasted from chat apps and AI answers often carry Markdown or punctuation stuck
// to the end ("/**", "/privacy)."). A 404 whose path ends in that junk redirects to the
// path without it; whatever is left is served or 404s as usual, so a page that exists is
// never redirected and the clean path cannot loop.
const JUNK = /(?:[*_)\].,;:!'"`>]|%2A|%29|%5D|%22|%27|%60|%3E)+$/i;
export const tidyPath = (p) => { const t = p.replace(JUNK, ""); return t !== p ? (t || "/") : null; };

export async function onRequest({ request, next }) {
  const res = await next();
  if (res.status === 404) {
    const url = new URL(request.url);
    const tidy = tidyPath(url.pathname);
    if (tidy) return Response.redirect(new URL(tidy + url.search, url).toString(), 301);
  }
  const csp = res.headers.get("Content-Security-Policy");
  if (!csp || !(res.headers.get("Content-Type") || "").includes("text/html")) return res;
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  const nonce = btoa(String.fromCharCode(...bytes));
  const out = new Response(res.body, res);
  out.headers.set("Content-Security-Policy", csp.replace("script-src 'self'", `script-src 'self' 'nonce-${nonce}'`));
  return out;
}
