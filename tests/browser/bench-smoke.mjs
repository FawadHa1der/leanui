// Correctness + rough timing of dist/bench (js-framework-benchmark keyed operations).
// node tests/browser/bench-smoke.mjs [chromium|firefox] [url] [--leanvir]   (under the host browser lock)
// Without a url it serves dist/bench (and bench/bench.css) itself. --leanvir: the same clicks on the
// app run by lean-vir (dist/vir/bench, vir/build.sh bench) must give the same table; no timings
// for it (the interpreter is tens of times slower).
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { pw } from "./playwright.mjs";
import { fileURLToPath } from "node:url";
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const LEANVIR = process.argv.includes("--leanvir");
const [engine = "chromium", url] = process.argv.slice(2).filter((a) => !a.startsWith("--"));
const DIRS = { "/leanui/": "dist/bench", "/leanvir/": "dist/vir/bench" };
const TYPES = { ".html": "text/html", ".js": "text/javascript", ".wasm": "application/wasm", ".css": "text/css", ".json": "application/json" };
const server = http.createServer((req, res) => {
  const u = new URL(req.url, "http://x").pathname;
  const mount = Object.keys(DIRS).find((m) => u.startsWith(m));
  const f = u === "/bench.css" ? path.join(ROOT, "bench/bench.css") : mount ? path.join(ROOT, DIRS[mount], u.slice(mount.length) || "index.html") : "";
  if (!f || !fs.existsSync(f) || fs.statSync(f).isDirectory()) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { "content-type": TYPES[path.extname(f)] || "application/octet-stream" }); res.end(fs.readFileSync(f));
});
await new Promise((ok) => server.listen(0, "127.0.0.1", ok));
const local = (impl) => `http://127.0.0.1:${server.address().port}/${impl}/index.html`;
const browser = await pw[engine].launch({ headless: true });
const errors = [];
async function open(url) {
  const page = await browser.newPage();
  page.on("pageerror", (e) => errors.push(e.message));
  page.on("console", (m) => { if (m.type() === "error") errors.push(m.text()); });
  await page.goto(url);
  await page.waitForFunction(() => window.__leanui, null, { timeout: 30000 });
  return page;
}
const page = await open(url || local("leanui"));
// time = click -> synchronous Lean update + DOM work -> forced layout (no paint), median of 9
const op = (sel) => page.evaluate((sel) => { const t0 = performance.now(); document.querySelector(sel).click(); document.body.offsetHeight; return performance.now() - t0; }, sel);
const median = (a) => a.slice().sort((x, y) => x - y)[a.length >> 1];
const rows = () => page.$$eval("#tbody tr", (t) => t.length);
const label = (i) => page.$eval(`#tbody tr:nth-child(${i}) td:nth-child(2) a`, (a) => a.textContent);
// row count, text and selected row of the table
const table = (page) => page.$eval("#tbody", (t) => [t.children.length, t.textContent, [...t.children].findIndex((r) => r.className === "danger")].join("|"));
const out = { engine: browser.version(), boot: await page.evaluate(() => window.__leanui.bootMs) };
const checks = [];
const T = {};
const time = async (name, setup, sel, n = 9) => { const ts = []; for (let i = 0; i < n; i++) { if (setup) await setup(); ts.push(await op(sel)); } T[name] = +median(ts).toFixed(2); };
await op("#run"); checks.push(["run 1000", (await rows()) === 1000]);
const l1 = await label(2), l999 = await label(999);
await op("#swaprows"); checks.push(["swap", (await label(2)) === l999 && (await label(999)) === l1]);
const n2 = await page.$eval("#tbody tr:nth-child(2)", (e) => (e.__probe = 1, e.textContent));
await op("#swaprows"); checks.push(["swap back keeps nodes (keyed)", await page.$eval("#tbody tr:nth-child(999)", (e) => e.__probe === 1)]);
await op("#update"); checks.push(["update", (await label(1)).endsWith(" !!!") && !(await label(2)).endsWith(" !!!") && (await label(11)).endsWith(" !!!")]);
await op("#tbody tr:nth-child(5) td:nth-child(2) a"); checks.push(["select", await page.$eval("#tbody tr:nth-child(5)", (e) => e.className === "danger")]);
await op("#tbody tr:nth-child(7) td:nth-child(3) a"); checks.push(["remove", (await rows()) === 999]);
await op("#add"); checks.push(["append", (await rows()) === 1999]);
const appended = await table(page);
await op("#clear"); checks.push(["clear", (await rows()) === 0]);
await op("#runlots"); checks.push(["run 10000", (await rows()) === 10000]);
await op("#clear");
await time("create1k", async () => { await op("#clear"); }, "#run");
await time("replace1k", null, "#run");
await time("update10th", null, "#update");
{ // select a different row each time (re-selecting the same row is a no-op)
  const ts = []; for (let i = 0; i < 9; i++) ts.push(await op(`#tbody tr:nth-child(${5 + (i & 1)}) td:nth-child(2) a`));
  T.select = +median(ts).toFixed(2); }
await time("swap", null, "#swaprows");
await time("remove", async () => { if ((await rows()) < 900) await op("#run"); }, "#tbody tr:nth-child(4) td:nth-child(3) a");
await time("append1k", async () => { await op("#run"); }, "#add", 5);
await time("clear1k", async () => { await op("#run"); }, "#clear");
await time("create10k", async () => { await op("#clear"); }, "#runlots", 3);
out.checks = checks; out.ms = T; out.errors = errors;
out.wasmPages = await page.evaluate(() => performance.memory ? Math.round(performance.memory.usedJSHeapSize / 1048576) + " MB JS heap" : null);
if (LEANVIR) {
  // the clicks above up to "append", in the app run by lean-vir
  const vir = await open(local("leanvir"));
  out.leanvirBoot = await vir.evaluate(() => window.__leanui.bootMs);
  for (const sel of ["#run", "#swaprows", "#swaprows", "#update", "#tbody tr:nth-child(5) td:nth-child(2) a", "#tbody tr:nth-child(7) td:nth-child(3) a", "#add"])
    await vir.evaluate((sel) => document.querySelector(sel).click(), sel);
  checks.push(["lean-vir: same table as wasm64", (await table(vir)) === appended]);
}
await browser.close();
server.close();
console.log(JSON.stringify(out, null, 1));
const ok = checks.every(([, v]) => v) && errors.length === 0;
console.log(ok ? "PASS" : "FAIL");
process.exit(ok ? 0 : 1);
