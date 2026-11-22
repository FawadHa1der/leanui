// Serves this directory twice: :8781 cross-origin isolated (COOP same-origin + COEP require-corp), :8782 plain.
import http from 'node:http'; import fs from 'node:fs'; import path from 'node:path'; import { chromium } from '/opt/node-tools/node_modules/playwright/index.mjs';
const dir = path.dirname(new URL(import.meta.url).pathname);
const serve = (port, iso) => http.createServer((q, s) => { const p = path.join(dir, q.url === '/' ? 'page.html' : q.url.split('?')[0]);
  if (!fs.existsSync(p)) { s.writeHead(404); return s.end(); }
  const h = { 'content-type': p.endsWith('.js') ? 'text/javascript' : 'text/html' };
  if (iso) { h['cross-origin-opener-policy'] = 'same-origin'; h['cross-origin-embedder-policy'] = 'require-corp'; }
  s.writeHead(200, h); fs.createReadStream(p).pipe(s); }).listen(port);
const a = serve(8781, true), b = serve(8782, false);
const browser = await chromium.launch({ executablePath: process.env.CHROME || undefined });
for (const [name, url] of [['isolated', 'http://localhost:8781/'], ['notIsolated', 'http://localhost:8782/']]) {
  const page = await browser.newPage();
  await page.goto(url); await page.waitForFunction(() => window.__probe, null, { timeout: 20000 }).catch(() => {});
  console.log(name, JSON.stringify(await page.evaluate(() => window.__probe), null, 1));
  await page.close();
}
await browser.close(); a.close(); b.close();
