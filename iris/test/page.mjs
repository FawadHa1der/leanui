// node iris/test/page.mjs <url serving dist/ with COOP and COEP> [chromium|firefox] [--full]
// Run after iris/build.sh, against `leanui serve dist --coop`. Checks the side-by-side page
// (dist/iris/index.html):
//  1. isolated, it runs every scenario in Web Workers (short runs, 1 and 2 threads, fuzz off;
//     --full: 1, 2 and 4 threads, fuzz on too), with no page or console error; no verified lane shows
//     a violation, an error or an unexpected hang; the Web Locks lanes run; every scenario's section
//     ends with a chart that has a mark per lane that ran and a verdict computed from the run; the
//     live views end on a result (S1's counters, S5's images); every verified lane has a proof
//     chip; no lane broken on purpose shows a speed; a scenario's own Run button runs it alone, and
//     Stop stops a run; and at 375 px the page does not scroll sideways;
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
const SCENARIOS = ['s1', 's2', 's4', 's5', 's11'];

let failures = 0;
const fail = (m) => { failures++; console.log('FAIL  ' + m); };
const browser = await pw[engine].launch({ headless: true });

// 1. isolated
{
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  page.on('console', (m) => { if (m.type() === 'error') errors.push(`console: ${m.text()}`); });
  const qs = full ? 'auto=1&quick=1&w=1,2,4&fuzz=off,on' : 'auto=1&quick=1&w=1,2&fuzz=off';
  const t0 = Date.now();
  await page.goto(`${base}/iris/index.html?${qs}`);
  await page.waitForFunction(() => window.__iris && ['done', 'error', 'refused'].includes(window.__iris.state), null, { timeout: 15 * 60 * 1000 });
  const s = await page.evaluate((ids) => ({
    ...window.__iris, chips: document.querySelectorAll('.lane-row .chip.proved').length,
    sections: ids.map((id) => {
      const el = document.getElementById(id);
      return { id, rows: el?.querySelectorAll('.lane-row').length || 0, marks: el?.querySelectorAll('.lane-row .res .dot, .lane-row .res .bar, .lane-row .res .pill').length || 0,
        pending: el?.querySelectorAll('.lane-row .res .busy, .lane-row .res .idle').length || 0, verdict: el?.querySelector('.verdict')?.className || '',
        text: el?.querySelector('.verdict')?.textContent || '', title: el?.querySelector('.chart-title')?.textContent || '' };
    }),
    meters: [...document.querySelectorAll('#s1 .meter')].map((m) => m.dataset.state),
    cards: [...document.querySelectorAll('#s5 .card .cap')].map((c) => c.textContent),
    canvases: [...document.querySelectorAll('#s5 .card canvas')].map((c) => {
      // a drawn image has more than one colour
      const d = c.getContext('2d').getImageData(0, 0, 256, 256).data, seen = new Set();
      for (let i = 0; i < d.length && seen.size < 3; i += 4 * 97) seen.add(d[i] + ',' + d[i + 1] + ',' + d[i + 2]);
      return seen.size;
    }),
  }), SCENARIOS);
  if (!s.isolated) fail('the page under --coop is not cross-origin isolated');
  if (s.state !== 'done') fail(`state ${s.state}: ${s.error || ''}`);
  for (const f of s.failures) fail(f);
  const ran = (id) => s.rows.filter((r) => r.lane === id && !r.skipped && !r.error);
  if (engine === 'chromium') {
    if (!ran('weblocks').length) fail('the Web Locks lane did not run');
    const k = s.rows.find((r) => r.lane === 'kill-weblocks');
    if (!k || !/acquired after/.test(k.extra?.after_kill || '')) fail(`kill test: Web Locks should be released when the holder dies, got ${JSON.stringify(k?.extra)}`);
  }
  for (const id of ['faa-verified', 'futex-verified', 'ring-heap', 'ring-dataplane', 'pmapg-verified', 'nowake-verified'])
    if (!ran(id).length) fail(`lane ${id} did not run`);
  for (const r of s.rows.filter((x) => x.error)) fail(`${r.scenario} ${r.lane} W=${r.W}: ${String(r.error).split('\n')[0]}`);
  // every section: a chart with a mark for every lane (a speed, a count, or what went wrong; a
  // broken lane may also say it saw no failure), and a verdict that is the one window.__iris has
  for (const c of s.sections) {
    const sc = s.scenarios[c.id];
    if (c.rows < 4) fail(`${c.id}: the chart has ${c.rows} lanes`);
    if (c.marks < c.rows - 2 || c.pending > 2) fail(`${c.id}: ${c.marks} marks for ${c.rows} lanes, ${c.pending} without a result`);
    if (!/\bdone\b/.test(c.verdict) || c.text.length < 60) fail(`${c.id}: no verdict (${c.verdict}: ${c.text.slice(0, 80)})`);
    if (!sc || sc.state !== 'done' || !c.text.startsWith(sc.verdict)) fail(`${c.id}: the verdict shown is not the one computed (${sc?.state})`);
    if (!/at \d+ thread/.test(c.title)) fail(`${c.id}: chart title "${c.title}"`);
  }
  if (s.meters.length < 8 || s.meters.some((m) => m !== 'done' && m !== 'bad')) fail(`S1's counters did not all end on a result: ${s.meters.join(', ')}`);
  if (s.cards.length !== 5 || s.cards.some((c) => !/checksum/.test(c))) fail(`S5's cards: ${JSON.stringify(s.cards)}`);
  if (s.canvases.length !== 4 || s.canvases.some((n) => n < 2)) fail(`S5's images were not drawn: ${s.canvases.join(', ')}`);
  if (s.chips < 10) fail(`only ${s.chips} proof chips`);
  // one lane opens to its chip and to the figures of its run
  await page.click('#s1 .lane-row[data-lane="faa-verified"] summary');
  const opened = await page.evaluate(() => { const d = document.querySelector('#s1 .lane-row[data-lane="faa-verified"]'); return d.open && /theorems/i.test(d.textContent) && /operations in/.test(d.querySelector('.figures').textContent); });
  if (!opened) fail('a verified lane does not open to its proof chip and its figures');
  // a lane broken on purpose shows what went wrong, never a speed
  if (await page.locator('.lane-row.broken .res .dot').count()) fail('a broken lane shows a speed');
  // a scenario's own Run button runs that scenario alone
  const s1ms = await page.evaluate(() => { window.__iris.scenarios.s11 = null; return window.__iris.scenarios.s1.ms; });
  await page.click('#s11 .run');
  await page.waitForFunction(() => window.__iris.state === 'done' && window.__iris.scenarios.s11, null, { timeout: 120000 });
  const again = await page.evaluate(() => ({ ...window.__iris.scenarios, shown: document.querySelector('#s11 .verdict').textContent }));
  if (again.s11.state !== 'done' || !again.shown.startsWith(again.s11.verdict) || again.s1.ms !== s1ms) fail(`Run S11: ${JSON.stringify(again.s11)}`);
  // Stop ends a run after the lane that is running (here the first): the lanes after it say "not run"
  await page.evaluate(() => { document.querySelector('#s1 .run').click(); document.querySelector('#stop').click(); });
  await page.waitForFunction(() => window.__iris.state === 'done' && window.__iris.scenarios.s1.state !== 'running', null, { timeout: 120000 });
  const stop = await page.evaluate(() => ({ state: window.__iris.scenarios.s1.state, verdict: document.querySelector('#s1 .verdict').textContent,
    meters: [...document.querySelectorAll('#s1 .meter .count')].map((c) => c.textContent), rows: [...document.querySelectorAll('#s1 .lane-row .res')].map((c) => c.textContent) }));
  const pending = (xs) => !xs.includes('not run') || xs.some((x) => /waiting|running/.test(x));
  if (stop.state !== 'stopped' || !/Stopped/.test(stop.verdict) || pending(stop.meters) || pending(stop.rows))
    fail(`Stop: ${JSON.stringify(stop)}`);
  for (const e of errors) fail(`page error: ${e}`);
  await page.setViewportSize({ width: 375, height: 800 });
  const wide = await page.evaluate(() => document.documentElement.scrollWidth);
  if (wide > 375) fail(`at 375 px the page is ${wide} px wide`);
  console.log(`isolated: ${s.rows.length} rows, ${s.rows.filter((r) => r.skipped).length} skipped (Node-only lanes), ${s.chips} proof chips, ` +
    `${s.sections.map((c) => `${c.id} ${((s.scenarios[c.id]?.ms || 0) / 1000).toFixed(1)} s`).join(', ')}; ${((Date.now() - t0) / 1000).toFixed(0)} s`);
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
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  await page.goto(`http://127.0.0.1:${srv.address().port}/iris/index.html?auto=1`);
  await page.waitForFunction(() => window.__iris && window.__iris.state !== 'loading', null, { timeout: 60000 });
  const s = await page.evaluate(() => ({ ...window.__iris, gate: document.querySelector('#gate').textContent,
    theorems: document.querySelectorAll('#theorems tbody tr').length, sections: document.querySelectorAll('.scenario').length }));
  // what is rendered, not the attribute: a stylesheet's display can override `hidden`
  s.controls = (await Promise.all(['#controls', '#runall', '#key'].map((q) => page.isVisible(q)))).some(Boolean);
  if (s.isolated || s.state !== 'refused') fail(`without COOP/COEP the page should refuse, got ${s.state}`);
  if (!/not cross-origin isolated/.test(s.gate)) fail('the refusal does not say why');
  if (s.theorems < 10 || s.controls || s.sections) fail(`the refusal should show the theorem table (${s.theorems} rows) and no controls or scenarios (${s.sections})`);
  for (const e of errors) fail(`page error without isolation: ${e}`);
  console.log(`not isolated: refused, with ${s.theorems} kernels in the theorem table`);
  await page.close();
  srv.close();
}

await browser.close();
console.log(failures ? `\n${failures} failures` : `\n[${engine}] page: all checks passed`);
process.exit(failures ? 1 : 0);
