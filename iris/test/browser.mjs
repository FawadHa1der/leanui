// node iris/test/browser.mjs <url serving dist/ with COOP and COEP> [chromium|firefox]
// Run after iris/build.sh, against `leanui serve dist --coop`: translated programs in module Web
// Workers on a cross-origin isolated page (dist/iris/rt/browser/index.html), each of which must
// give the result HeapLang's semantics gives, or trap where the encoding must.
import { pw } from '../../tests/browser/playwright.mjs';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const OUT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../dist/iris');
const args = process.argv.slice(2);
const base = (args.find((a) => /^https?:/.test(a)) || '').replace(/\/$/, '');
const engine = args.find((a) => a === 'chromium' || a === 'firefox') || 'chromium';
if (!base) { console.error('usage: node iris/test/browser.mjs <url serving dist/ with --coop> [chromium|firefox]'); process.exit(64); }
const manifest = JSON.parse(fs.readFileSync(path.join(OUT, 'gen/manifest.json'), 'utf8'));
const NAMES = ['edge_eval-order-pair', 'edge_overflow-traps', 'small_counter_futex', 'small_pfib',
  'closed_two_incr', 'closed_spsc_client', 'large_counter_futex', 'large_treiber', 'large_spsc_stream'];

const browser = await pw[engine].launch({ headless: true });
let failures = 0;
for (const name of NAMES) {
  const p = manifest.programs.find((q) => q.name === name);
  const page = await browser.newPage();
  await page.goto(`${base}/iris/rt/browser/index.html?prog=../../gen/js/${name}.mjs&pool=4&runs=1`);
  await page.waitForFunction(() => window.__result, null, { timeout: 120000 });
  const r = await page.evaluate(() => window.__result);
  await page.close();
  const got = r.error ? 'ERROR ' + r.error : r.trap ? 'TRAP' : r.result;
  const ok = got === p.expect && r.crossOriginIsolated;
  if (!ok) failures++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name.padEnd(28)} ${got}${r.median_ms != null ? `  (${r.median_ms} ms, ${r.threads} threads)` : ''}`);
}
await browser.close();
console.log(`[${engine}] ${NAMES.length - failures} passed, ${failures} failed`);
process.exit(failures ? 1 : 0);
