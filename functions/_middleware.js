// Gives each HTML response a fresh CSP nonce. Cloudflare's Bot Fight Mode injects an
// inline script into every page on the zone and copies the nonce from script-src onto
// it, so the script runs without 'unsafe-inline'. Our own scripts load from /assets/,
// and the one-line inline "js" class script is allowed by its hash in _headers.
export async function onRequest({ next }) {
  const res = await next();
  const csp = res.headers.get("Content-Security-Policy");
  if (!csp || !(res.headers.get("Content-Type") || "").includes("text/html")) return res;
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  const nonce = btoa(String.fromCharCode(...bytes));
  const out = new Response(res.body, res);
  out.headers.set("Content-Security-Policy", csp.replace("script-src 'self'", `script-src 'self' 'nonce-${nonce}'`));
  return out;
}
