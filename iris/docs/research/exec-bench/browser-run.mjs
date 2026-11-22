// Runs translated programs in headless Chromium on a COOP/COEP page.  node bench/browser-run.mjs prog1 prog2 ...
import { createRequire } from 'node:module';
import { serve } from '../rt/browser/serve.mjs';
const require = createRequire('/opt/node22/lib/node_modules/');
const { chromium } = require('playwright');
const progs = process.argv.slice(2).filter(a => !a.startsWith('--'));
const srv = await serve(0);
const port = srv.address().port;
const browser = await chromium.launch();
for (const p of progs) {
  const page = await browser.newPage();
  const [name, pool = '4'] = p.split(':');
  await page.goto(`http://127.0.0.1:${port}/rt/browser/index.html?prog=../../out/${name}.mjs&pool=${pool}&runs=5`);
  await page.waitForFunction(() => window.__result, null, { timeout: 120000 });
  console.log(JSON.stringify(await page.evaluate(() => window.__result)));
  await page.close();
}
await browser.close(); srv.close();
