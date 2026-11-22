import http from "node:http"; import fs from "node:fs"; import path from "node:path";
import { createRequire } from "node:module";
const require = createRequire("/opt/node-tools/node_modules/");
const { chromium } = require("playwright");
const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const types = { ".html": "text/html", ".js": "text/javascript", ".wasm": "application/wasm" };
const srv = http.createServer((req, res) => {
  const p = path.join(root, decodeURIComponent(new URL(req.url, "http://x").pathname));
  console.log("GET", req.url);
  if (!fs.existsSync(p)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { "Content-Type": types[path.extname(p)] || "application/octet-stream", "Cross-Origin-Opener-Policy": "same-origin", "Cross-Origin-Embedder-Policy": "require-corp" });
  fs.createReadStream(p).pipe(res);
}).listen(0);
const browser = await chromium.launch();
const page = await browser.newPage();
page.on("worker", (w) => { console.log("worker created", w.url()); w.on("console", (m) => console.log("  [worker console]", m.text().slice(0, 200))); });
page.on("console", (m) => console.log("[page console]", m.type(), m.text().slice(0, 200)));
await page.goto(`http://127.0.0.1:${srv.address().port}/web/page.html?build=wasm-mt&workers=0&where=worker&runs=[]`);
await new Promise((r) => setTimeout(r, 8000));
for (const w of page.workers()) console.log("live worker", w.url(), await w.evaluate(() => [self.name, self.crossOriginIsolated]).catch((e) => e.message));
await browser.close(); srv.close();
