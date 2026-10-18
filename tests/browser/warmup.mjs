// How does LeanUI's per-operation script time evolve after page load? Browsers start wasm on a
// baseline compiler and tier up in the background, so a fresh-page benchmark can measure baseline
// code. Runs bursts of selects for 12 s on one page and prints the median per second.
//   node tests/browser/warmup.mjs [chromium|firefox] [impl-dir]     (under the host browser lock)
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const require = createRequire(process.env.LEANUI_PLAYWRIGHT_FROM || "/Users/fawadhaider/code/wasm64-lean-fable/qed64/package.json");
const pw = require("playwright");
const engine = process.argv[2] || "chromium", dir = path.resolve(ROOT, process.argv[3] || "dist/bench");
const TYPES = { ".html": "text/html", ".js": "text/javascript", ".wasm": "application/wasm", ".css": "text/css" };
const server = http.createServer((req, res) => {
  const u = new URL(req.url, "http://x").pathname;
  const f = u === "/bench.css" ? path.join(ROOT, "bench/bench.css") : path.join(dir, u.slice(1) || "index.html");
  if (!fs.existsSync(f)) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { "content-type": TYPES[path.extname(f)] || "application/octet-stream" }); res.end(fs.readFileSync(f));
});
await new Promise((ok) => server.listen(0, "127.0.0.1", ok));
const browser = await pw[engine].launch({ headless: true, firefoxUserPrefs: engine === "firefox" ? { "privacy.reduceTimerPrecision": false } : undefined });
const page = await browser.newPage();
await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);
await page.waitForFunction(() => window.__ready, null, { timeout: 30000 });
const series = await page.evaluate(() => new Promise((done) => {
  document.querySelector("#run").click();
  const t0 = performance.now(), out = []; let i = 0;
  // bursts of back-to-back selects keep the thread busy: with idle gaps between clicks, macOS
  // may run the renderer on an efficiency core, which reads as a 4-5x "slowdown"
  const tick = () => {
    let a = 0;
    for (let k = 0; k < 40; k++) {
      const el = document.querySelector(`#tbody tr:nth-child(${2 + (i++ & 1)}) td:nth-child(2) a`);
      a = performance.now(); el.click(); out.push([a - t0, performance.now() - a]);
    }
    if (a - t0 < 12000) setTimeout(tick, 0); else done(out);
  };
  setTimeout(tick, 0);
}));
await browser.close(); server.close();
const bySec = new Map();
for (const [t, d] of series) { const s = Math.floor(t / 1000); (bySec.get(s) || bySec.set(s, []).get(s)).push(d); }
const med = (a) => a.sort((x, y) => x - y)[a.length >> 1];
console.log(`${engine}: select script time (median per second after the first create)`);
for (const [s, ds] of bySec) console.log(`  ${String(s).padStart(2)}-${s + 1}s  ${med(ds).toFixed(3)} ms  (${ds.length} samples)`);
