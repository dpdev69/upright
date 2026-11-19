// Tells IndexNow search engines (Bing, Yandex, Seznam, Naver and others) which pages
// of this site changed, so they come back to them sooner.
//
// How it runs: the "IndexNow" workflow runs it after every push to main that touches
// a page or the sitemap, once Cloudflare Pages has had time to publish. It can also be
// run by hand from the repository root:
//
//   node tools/indexnow.mjs --dry-run --all      print what would be sent, send nothing
//   node tools/indexnow.mjs --all                send every URL in the sitemap
//   node tools/indexnow.mjs --since <git-sha>    send pages whose HTML changed since that commit
//   node tools/indexnow.mjs /privacy/            send specific paths
//
// Google does not use IndexNow. It finds changes through sitemap.xml and its own crawling.
// The key below is public by design: the same key is served at <site>/<key>.txt so the
// engines can check the site owner sent the request. It protects nothing secret.
//
// A failed ping never fails the deploy: every problem is logged as a warning and the
// script exits 0.

import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { join, posix } from 'node:path';
import { fileURLToPath } from 'node:url';

const SITE = 'https://upright.hellobasalt.dev'; // no trailing slash
const PUBLISHED_DIR = 'site'; // '' for the repo root, 'site' when the pages live in site/
const KEY = 'ca7b8a73313a7602b9cbb493324d451a';

const ENDPOINT = 'https://api.indexnow.org/indexnow';
const ROOT = fileURLToPath(new URL('..', import.meta.url));
const HOST = new URL(SITE).host;
const ZERO_SHA = /^0+$/;

const args = process.argv.slice(2);
const flags = { all: false, dryRun: false, since: undefined };
const explicit = [];
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === '--all') flags.all = true;
  else if (a === '--dry-run') flags.dryRun = true;
  else if (a === '--since') {
    const next = args[i + 1];
    if (next !== undefined && !next.startsWith('--')) { flags.since = next; i++; } else flags.since = '';
  } else if (a.startsWith('--since=')) flags.since = a.slice(8);
  else if (a.startsWith('--')) { console.error(`IndexNow: unknown flag ${a}`); process.exit(2); }
  else explicit.push(a);
}

const warn = (msg) => console.log(`::warning::${String(msg).replace(/\s+/g, ' ').trim()}`);
const git = (...a) => execFileSync('git', a, { cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });

function sitemapUrls() {
  const file = join(ROOT, PUBLISHED_DIR, 'sitemap.xml');
  const xml = readFileSync(file, 'utf8');
  const urls = [];
  for (const m of xml.matchAll(/<loc>\s*([^<]+?)\s*<\/loc>/g)) {
    urls.push(m[1].replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'"));
  }
  return urls;
}

// The source HTML file (repo-relative, forward slashes) behind a URL, or null.
function sourceFile(url) {
  let p;
  try { p = decodeURIComponent(new URL(url).pathname); } catch { return null; }
  const base = p.replace(/\/+$/, '');
  const candidates = [];
  if (p.endsWith('/')) candidates.push(`${base.slice(1)}${base ? '/' : ''}index.html`);
  if (base) candidates.push(`${base.slice(1)}.html`, `${base.slice(1)}/index.html`);
  for (const c of candidates) {
    const rel = posix.join(PUBLISHED_DIR, c);
    if (existsSync(join(ROOT, rel))) return rel;
  }
  return null;
}

function changedSince(sha) {
  if (!sha) return { reason: 'empty --since value' };
  if (ZERO_SHA.test(sha)) return { reason: `${sha} is the all-zero sha (new branch or first push)` };
  try { git('cat-file', '-e', `${sha}^{commit}`); } catch { return { reason: `git does not know commit ${sha}` }; }
  try {
    const files = git('diff', '--name-only', sha, 'HEAD').split('\n').filter(Boolean);
    return { files: new Set(files) };
  } catch (e) { return { reason: `git diff failed: ${String(e.message).split('\n')[0]}` }; }
}

function toUrl(arg) {
  if (/^https?:\/\//i.test(arg)) return arg;
  return SITE + (arg.startsWith('/') ? arg : `/${arg}`);
}

async function keyIsLive() {
  const url = `${SITE}/${KEY}.txt`;
  for (let attempt = 1; attempt <= 6; attempt++) {
    try {
      const res = await fetch(url, { signal: AbortSignal.timeout(15000), headers: { 'Cache-Control': 'no-cache' } });
      const body = (await res.text()).trim();
      if (res.ok && body === KEY) return true;
      console.log(`IndexNow: key file check ${attempt}/6 got ${res.status}`);
    } catch (e) {
      console.log(`IndexNow: key file check ${attempt}/6 failed: ${e.message}`);
    }
    if (attempt < 6) await new Promise((r) => setTimeout(r, 10000));
  }
  return false;
}

async function main() {
  let urls;
  if (explicit.length) {
    urls = explicit.map(toUrl);
  } else if (flags.since !== undefined && !flags.all) {
    const r = changedSince(flags.since);
    if (r.files) {
      urls = sitemapUrls().filter((u) => {
        const src = sourceFile(u);
        return src && r.files.has(src);
      });
    } else {
      console.log(`IndexNow: ${r.reason}, falling back to --all`);
      urls = sitemapUrls();
    }
  } else if (flags.all) {
    urls = sitemapUrls();
  } else {
    console.error('IndexNow: nothing to do. Pass --all, --since <sha> or one or more paths.');
    process.exit(2);
  }

  const foreign = urls.filter((u) => { try { return new URL(u).host !== HOST; } catch { return true; } });
  if (foreign.length) {
    console.log(`IndexNow: skipping ${foreign.length} URL(s) outside ${HOST}: ${foreign.join(' ')}`);
    urls = urls.filter((u) => !foreign.includes(u));
  }
  urls = [...new Set(urls)];

  if (!urls.length) { console.log('IndexNow: no changed pages'); return; }

  const payload = { host: HOST, key: KEY, keyLocation: `${SITE}/${KEY}.txt`, urlList: urls };
  if (flags.dryRun) {
    console.log(JSON.stringify(payload, null, 2));
    return;
  }

  if (!(await keyIsLive())) {
    warn(`IndexNow key file is not live at ${SITE}/${KEY}.txt, nothing sent`);
    return;
  }

  try {
    const res = await fetch(ENDPOINT, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=utf-8' },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(30000),
    });
    const text = (await res.text()).slice(0, 300);
    if (res.ok) {
      console.log(`IndexNow ${res.status}: ${urls.length} URLs`);
      for (const u of urls) console.log(`  ${u}`);
    } else {
      warn(`IndexNow ${res.status}: ${text || res.statusText} (${urls.length} URLs not accepted)`);
    }
  } catch (e) {
    warn(`IndexNow request failed: ${e.message}`);
  }
}

main().catch((e) => { warn(`IndexNow error: ${e.message}`); process.exit(0); });
