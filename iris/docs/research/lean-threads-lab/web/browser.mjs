// node browser.mjs <coi 0|1> <build> <workers> <where page|worker> '<runs json>'
// Serves lab/ (COOP+COEP when coi=1) and runs the page in Playwright's Chromium.
import http from "node:http"; import fs from "node:fs"; import path from "node:path";
import { createRequire } from "node:module";
const require = createRequire("/opt/node-tools/node_modules/");
const { chromium } = require("playwright");
const [coi, build, workers, where, runs] = process.argv.slice(2);
const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const types = { ".html": "text/html", ".js": "text/javascript", ".wasm": "application/wasm" };
const srv = http.createServer((req, res) => {
  const p = path.join(root, decodeURIComponent(new URL(req.url, "http://x").pathname));
  if (!p.startsWith(root) || !fs.existsSync(p)) { res.writeHead(404); return res.end(); }
  const h = { "Content-Type": types[path.extname(p)] || "application/octet-stream" };
  if (coi === "1") { h["Cross-Origin-Opener-Policy"] = "same-origin"; h["Cross-Origin-Embedder-Policy"] = "require-corp"; }
  res.writeHead(200, h); fs.createReadStream(p).pipe(res);
}).listen(0);
const port = srv.address().port;
const browser = await chromium.launch();
const page = await browser.newPage();
page.on("pageerror", (e) => console.log("pageerror", e.message));
page.on("console", (m) => { if (m.type() === "error" || m.type() === "warning") console.log("console." + m.type(), m.text().slice(0, 300)); });
const url = where === "bg" ? `http://127.0.0.1:${port}/web/bg.html?build=${build}&workers=${workers}&${runs}` : `http://127.0.0.1:${port}/web/page.html?build=${build}&workers=${workers}&where=${where}&runs=${encodeURIComponent(runs)}`;
await page.goto(url);
await page.waitForFunction(() => window.__results, null, { timeout: +(process.env.WAIT_MS || 600000) }).catch((e) => console.log("TIMEOUT waiting for results:", e.message.split("\n")[0]));
for (const l of (await page.evaluate(() => window.__results || window.__steps)) || []) console.log(l);
console.log(JSON.stringify({ browser: browser.version(), coi: coi === "1", where }));
await browser.close(); srv.close();
