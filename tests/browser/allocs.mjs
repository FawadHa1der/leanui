// Every allocation one benchmark click makes in the wasm build: malloc/calloc/memalign calls,
// frees, reallocs and bytes requested, counted by tools/alloc-count.c. The counts are exact and
// deterministic (one fresh page per operation, after the operation's warm-up clicks), so one run
// is enough and two builds compare exactly; timings from such a build mean nothing.
//
//   LEANUI_COUNT_ALLOCS=1 LEANUI_PAGE=examples/bench.html tools/build-app.sh BenchApp bench-allocs
//   node tests/browser/allocs.mjs dist/bench-allocs [dist/other-build ...] [--only create1k,clear1k]
//
// With several builds it prints one table per build and the difference to the first.
// Run it under the host browser lock.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { pw } from "./playwright.mjs";
import { fileURLToPath } from "node:url";
import { OPS as ALL_OPS } from "../../bench/ops.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const argv = process.argv.slice(2);
const oi = argv.indexOf("--only");
const ONLY = oi >= 0 ? argv[oi + 1].split(",") : null;
const DIRS = argv.filter((a, i) => !a.startsWith("--") && !(oi >= 0 && i === oi + 1));
if (!DIRS.length) { console.error("usage: node tests/browser/allocs.mjs <dist/build> [<dist/build> ...] [--only ops]"); process.exit(2); }
const OPS = ALL_OPS.filter((o) => !ONLY || ONLY.includes(o.name));
const ROWS = { create1k: 1000, replace1k: 1000, create10k: 10000, append1k: 1000 };

const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".wasm": "application/wasm", ".css": "text/css" };
let dir = null;
const server = http.createServer((req, res) => {
  const u = decodeURIComponent(new URL(req.url, "http://x").pathname);
  const file = u === "/bench.css" ? path.join(ROOT, "bench/bench.css") : path.join(ROOT, dir, u.replace(/^\/leanui\//, "") || "index.html");
  if (!fs.existsSync(file) || fs.statSync(file).isDirectory()) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { "content-type": TYPES[path.extname(file)] || "application/octet-stream", "cache-control": "no-store" });
  res.end(fs.readFileSync(file));
});
await new Promise((ok) => server.listen(0, "127.0.0.1", ok));
const URL_ = `http://127.0.0.1:${server.address().port}/leanui/index.html`;

const browser = await pw.chromium.launch({ headless: true });
const results = [];
try {
  for (const d of DIRS) {
    dir = d;
    const rows = {};
    for (const op of OPS) {
      const page = await browser.newPage();
      const errors = [];
      page.on("pageerror", (e) => errors.push(e.message));
      await page.goto(URL_);
      await page.waitForFunction(() => window.__leanui, null, { timeout: 30000 });
      const r = await page.evaluate(({ warm, click }) => {
        const mod = window.__leanui.transport.mod;
        if (!mod._leanui_alloc_counter) throw new Error("not a counting build (LEANUI_COUNT_ALLOCS=1)");
        const read = () => [0, 1, 2, 3].map((i) => mod._leanui_alloc_counter(i));
        const q = (s) => { const e = document.querySelector(s); if (!e) throw new Error("no " + s); return e; };
        for (const s of warm) q(s).click();
        const el = q(click);
        const a = read(); el.click(); const b = read();
        return { allocs: b[0] - a[0], frees: b[1] - a[1], reallocs: b[2] - a[2], bytes: b[3] - a[3] };
      }, { warm: op.warm, click: op.click });
      if (errors.length) throw new Error(d + " " + op.name + ": " + errors.join("; "));
      rows[op.name] = r;
      await page.close();
    }
    results.push([d, rows]);
  }
} finally { await browser.close(); server.close(); }

const fmt = (x) => (Math.round(x * 100) / 100).toString();
for (const [d, rows] of results) {
  console.log(`\n${d}: allocations per click (exact)\n`);
  console.log("| operation | allocs | frees | reallocs | KB requested | allocs per new row |");
  console.log("|---|--:|--:|--:|--:|--:|");
  for (const op of OPS) {
    const r = rows[op.name];
    console.log(`| ${op.name} | ${r.allocs} | ${r.frees} | ${r.reallocs} | ${fmt(r.bytes / 1024)} | ${ROWS[op.name] ? fmt(r.allocs / ROWS[op.name]) : ""} |`);
  }
}
if (results.length > 1) {
  const [d0, base] = results[0];
  for (const [d, rows] of results.slice(1)) {
    console.log(`\n${d} vs ${d0}: allocs (frees) per click\n`);
    console.log("| operation | " + d0 + " | " + d + " | change |");
    console.log("|---|--:|--:|--:|");
    for (const op of OPS) {
      const a = base[op.name], b = rows[op.name];
      console.log(`| ${op.name} | ${a.allocs} (${a.frees}) | ${b.allocs} (${b.frees}) | ${fmt(100 * (b.allocs - a.allocs) / a.allocs)}% |`);
    }
  }
}
