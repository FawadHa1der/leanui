// node iris/test/page.mjs <url serving dist/ with COOP and COEP> [chromium|firefox] [--full]
// Run after iris/build.sh, against `leanui serve dist --coop`. Checks the side-by-side page
// (dist/iris/index.html):
//  1. isolated, it runs every scenario in Web Workers (short runs, W = 1 and 2, fuzz off; --full:
//     W = 1, 2, 4 and fuzz on too), and no verified lane shows a violation, an error or an
//     unexpected hang; the Web Locks lanes run; every verified lane has a proof chip;
//  2. served without COOP and COEP (a plain static server started here), it refuses to run and
//     still shows what is proved.
import { pw } from '../../tests/browser/playwright.mjs';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const DIST = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../dist');
const args = process.argv.slice(2);
const base = (args.find((a) => /^https?:/.test(a)) || '').replace(/\/$/, '');
const engine = args.find((a) => a === 'chromium' || a === 'firefox') || 'chromium';
const full = args.includes('--full');
if (!base) { console.error('usage: node iris/test/page.mjs <url serving dist/ with --coop> [chromium|firefox] [--full]'); process.exit(64); }

let failures = 0;
const fail = (m) => { failures++; console.log('FAIL  ' + m); };
const browser = await pw[engine].launch({ headless: true });

// 1. isolated
{
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  const qs = full ? 'auto=1&quick=1&w=1,2,4&fuzz=off,on' : 'auto=1&quick=1&w=1,2&fuzz=off';
  const t0 = Date.now();
  await page.goto(`${base}/iris/index.html?${qs}`);
  await page.waitForFunction(() => window.__iris && ['done', 'error', 'refused'].includes(window.__iris.state), null, { timeout: 15 * 60 * 1000 });
  const s = await page.evaluate(() => ({ ...window.__iris, chips: document.querySelectorAll('details.chip.proved').length }));
  if (!s.isolated) fail('the page under --coop is not cross-origin isolated');
  if (s.state !== 'done') fail(`state ${s.state}: ${s.error || ''}`);
  for (const f of s.failures) fail(f);
  for (const e of errors) fail(`page error: ${e}`);
  const ran = (id) => s.rows.filter((r) => r.lane === id && !r.skipped && !r.error);
  if (engine === 'chromium') {
    if (!ran('weblocks').length) fail('the Web Locks lane did not run');
    const k = s.rows.find((r) => r.lane === 'kill-weblocks');
    if (!k || !/acquired after/.test(k.extra?.after_kill || '')) fail(`kill test: Web Locks should be released when the holder dies, got ${JSON.stringify(k?.extra)}`);
  }
  for (const id of ['faa-verified', 'futex-verified', 'ring-heap', 'ring-dataplane', 'pmapg-verified', 'nowake-verified'])
    if (!ran(id).length) fail(`lane ${id} did not run`);
  if (s.chips < 10) fail(`only ${s.chips} proof chips`);
  const errs = s.rows.filter((r) => r.error);
  for (const r of errs) fail(`${r.scenario} ${r.lane} W=${r.W}: ${String(r.error).split('\n')[0]}`);
  console.log(`isolated: ${s.rows.length} rows, ${s.rows.filter((r) => r.skipped).length} skipped (Node-only lanes), ${s.chips} proof chips, ${((Date.now() - t0) / 1000).toFixed(0)} s`);
  if (process.env.IRIS_PAGE_JSON) fs.writeFileSync(process.env.IRIS_PAGE_JSON, JSON.stringify(s.rows, null, 1));
  await page.close();
}

// 2. not isolated: the same files from a server that sends no COOP or COEP
{
  const types = { '.html': 'text/html', '.mjs': 'text/javascript', '.js': 'text/javascript', '.json': 'application/json', '.css': 'text/css' };
  const srv = http.createServer((req, res) => {
    const f = path.join(DIST, decodeURIComponent(new URL(req.url, 'http://x').pathname));
    if (!f.startsWith(DIST) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { 'content-type': types[path.extname(f)] || 'application/octet-stream' });
    fs.createReadStream(f).pipe(res);
  });
  await new Promise((r) => srv.listen(0, '127.0.0.1', r));
  const page = await browser.newPage();
  await page.goto(`http://127.0.0.1:${srv.address().port}/iris/index.html?auto=1`);
  await page.waitForFunction(() => window.__iris && window.__iris.state !== 'loading', null, { timeout: 60000 });
  const s = await page.evaluate(() => ({ ...window.__iris, gate: document.querySelector('#gate').textContent,
    theorems: document.querySelectorAll('#theorems tbody tr').length, controls: !document.querySelector('#controls').hidden }));
  if (s.isolated || s.state !== 'refused') fail(`without COOP/COEP the page should refuse, got ${s.state}`);
  if (!/not cross-origin isolated/.test(s.gate)) fail('the refusal does not say why');
  if (s.theorems < 10 || s.controls) fail(`the refusal should show the theorem table (${s.theorems} rows) and no controls`);
  console.log(`not isolated: refused, with ${s.theorems} kernels in the theorem table`);
  await page.close();
  srv.close();
}

await browser.close();
console.log(failures ? `\n${failures} failures` : `\n[${engine}] page: all checks passed`);
process.exit(failures ? 1 : 0);
