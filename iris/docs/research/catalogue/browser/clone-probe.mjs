// Can a page that is not cross-origin isolated hand a shared WebAssembly.Memory to a Worker?
import http from 'node:http'; import fs from 'node:fs'; import path from 'node:path'; import { chromium } from '/opt/node-tools/node_modules/playwright/index.mjs';
const dir = path.dirname(new URL(import.meta.url).pathname);
const serve = (port, iso) => http.createServer((q, s) => { const p = path.join(dir, q.url === '/' ? 'blank.html' : q.url);
  const h = { 'content-type': p.endsWith('.js') ? 'text/javascript' : 'text/html' };
  if (iso) { h['cross-origin-opener-policy'] = 'same-origin'; h['cross-origin-embedder-policy'] = 'require-corp'; }
  s.writeHead(200, h); if (fs.existsSync(p)) fs.createReadStream(p).pipe(s); else s.end('<!doctype html><title>b</title>'); }).listen(port);
const a = serve(8783, true), b = serve(8784, false);
const browser = await chromium.launch();
for (const [name, url] of [['isolated', 'http://localhost:8783/'], ['notIsolated', 'http://localhost:8784/']]) {
  const page = await browser.newPage(); await page.goto(url);
  const r = await page.evaluate(async () => {
    const m = new WebAssembly.Memory({ initial: 1, maximum: 1, shared: true });
    const w = new Worker('echo.js');
    const reply = new Promise(res => { w.onmessage = e => res(e.data); w.onmessageerror = () => res('messageerror in worker'); setTimeout(() => res('no reply in 2 s'), 2000); });
    try { w.postMessage(m); } catch (e) { return 'postMessage throws ' + e.name + ': ' + e.message; }
    const got = await reply; return got + '; counter after = ' + new Int32Array(m.buffer)[0];
  });
  console.log(name, r); await page.close();
}
await browser.close(); a.close(); b.close();
