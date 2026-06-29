// Post-build step for serving the static export under the `/astrolabe` path.
//
// `next build` (output: 'export', basePath: '/astrolabe') writes files FLAT into
// ./out (out/index.html, out/docs.html, out/_next/...) while rewriting in-page
// URLs to /astrolabe/...  The Cloudflare Workers assets engine maps the request
// path 1:1 onto files, so a request for /astrolabe/docs looks for out/astrolabe/docs
// and 404s. This script nests everything under out/astrolabe/ so files line up
// with the URLs, then lifts _redirects back to the assets-dir root (Cloudflare only
// reads _redirects/_headers from the root of the assets directory).
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { readdirSync, mkdirSync, renameSync, rmSync, existsSync } from 'node:fs';

const out = fileURLToPath(new URL('../out', import.meta.url));
const stage = fileURLToPath(new URL('../.out-stage', import.meta.url));

if (!existsSync(out)) {
  throw new Error(`Expected build output at ${out} — run \`next build\` first.`);
}

// Move out/ aside, recreate out/astrolabe/, and drop everything back inside it.
rmSync(stage, { recursive: true, force: true });
renameSync(out, stage);
const nested = join(out, 'astrolabe');
mkdirSync(nested, { recursive: true });
for (const entry of readdirSync(stage)) {
  renameSync(join(stage, entry), join(nested, entry));
}
rmSync(stage, { recursive: true, force: true });

// Cloudflare reads _redirects only from the assets-dir root, not from out/astrolabe/.
const nestedRedirects = join(nested, '_redirects');
if (existsSync(nestedRedirects)) {
  renameSync(nestedRedirects, join(out, '_redirects'));
}

console.log('arranged static export under out/astrolabe/');
