// Where does LeanUI's script time go? Sample-profile benchmark operations in Chromium (CDP
// Profiler) or Firefox (the Gecko profiler, MOZ_PROFILER_*), and summarise self time by function
// and by layer: Lean (wasm), the JS runtime (leanui.js), the DOM/engine.
//
//   node tests/browser/profile.mjs <app-dir> [--engine chromium|firefox] [--op create1k] [--reps 30]
//
// <app-dir> is a build with function names (tools/build-app.sh BenchApp bench-prof --debug).
// Firefox writes the raw profile (loadable at profiler.firefox.com) next to the summary. Its
// absolute times come from Playwright's Firefox build, which runs wasm about 8x slower than
// release Firefox: use it for proportions, not speed.
// Run it under the host browser lock.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const require = createRequire(process.env.LEANUI_PLAYWRIGHT_FROM || "/Users/fawadhaider/code/wasm64-lean-fable/qed64/package.json");
const pw = require("playwright");
const argv = process.argv.slice(2);
const opt = (n, d) => { const i = argv.indexOf("--" + n); return i >= 0 ? argv[i + 1] : d; };
const APP = path.resolve(argv[0] || "dist/bench-prof");
const ENGINE = opt("engine", "chromium"), OP = opt("op", "create1k"), REPS = +opt("reps", "30");
const OUT = path.join(ROOT, "work", "profiles"); fs.mkdirSync(OUT, { recursive: true });

const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".wasm": "application/wasm", ".css": "text/css" };
const server = http.createServer((req, res) => {
  const u = decodeURIComponent(new URL(req.url, "http://x").pathname);
  const file = u === "/bench.css" ? path.join(ROOT, "bench/bench.css") : path.join(APP, u.slice(1) || "index.html");
  if (!file.startsWith(ROOT) || !fs.existsSync(file)) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { "content-type": TYPES[path.extname(file)] || "application/octet-stream" }); res.end(fs.readFileSync(file));
});
await new Promise((ok) => server.listen(0, "127.0.0.1", ok));
const URL_ = `http://127.0.0.1:${server.address().port}/index.html`;

// each operation: what to click once per repetition (after its setup)
const OPS = {
  create1k: { setup: "#clear", click: "#run" },
  replace1k: { setup: null, click: "#run", pre: "#run" },
  update10th: { setup: null, click: "#update", pre: "#run" },
  select: { setup: null, click: (i) => `#tbody tr:nth-child(${2 + (i & 1)}) td:nth-child(2) a`, pre: "#run" },
  swap: { setup: null, click: "#swaprows", pre: "#run" },
  clear1k: { setup: "#run", click: "#clear" },
};
const op = OPS[OP]; if (!op) throw new Error("unknown op " + OP);
const drive = (page) => page.evaluate(({ op, reps }) => {
  const q = (s) => document.querySelector(s);
  if (op.pre) q(op.pre).click();
  let t = 0;
  for (let i = 0; i < reps; i++) {
    if (op.setup) q(op.setup).click();
    const sel = typeof op.click === "string" ? op.click : null;
    const el = q(sel || `#tbody tr:nth-child(${2 + (i & 1)}) td:nth-child(2) a`);
    const t0 = performance.now(); el.click(); t += performance.now() - t0;
  }
  return t / reps;
}, { op: { ...op, click: typeof op.click === "string" ? op.click : null }, reps: REPS });

const layer = (fn, url) => {
  if (/\.wasm|wasm-function|^\$?lp_|^l_|^lean_|^_?mi_|^LeanUI|^leanui_/.test(url + " " + fn) || url.includes("app.wasm")) return "lean (wasm)";
  if (url.endsWith("leanui.js")) return "runtime (leanui.js)";
  if (url.endsWith("app.js")) return "emscripten glue (app.js)";
  if (fn === "(garbage collector)") return "gc";
  if (fn === "(program)" || fn === "(idle)") return "other";
  return "engine (DOM, natives)";
};

function summarise(self) {
  const total = [...self.values()].reduce((a, b) => a + b.ms, 0);
  const byLayer = new Map();
  for (const v of self.values()) byLayer.set(v.layer, (byLayer.get(v.layer) || 0) + v.ms);
  const lines = [`self time by layer (${total.toFixed(1)} ms sampled):`];
  for (const [l, ms] of [...byLayer].sort((a, b) => b[1] - a[1])) lines.push(`  ${l.padEnd(26)} ${ms.toFixed(1).padStart(8)} ms  ${(100 * ms / total).toFixed(1).padStart(5)}%`);
  lines.push("top functions by self time:");
  for (const [k, v] of [...self].sort((a, b) => b[1].ms - a[1].ms).slice(0, 40)) lines.push(`  ${v.ms.toFixed(1).padStart(8)} ms  ${(100 * v.ms / total).toFixed(1).padStart(5)}%  [${v.layer}] ${k}`);
  return lines.join("\n");
}

let report;
if (ENGINE === "chromium") {
  const browser = await pw.chromium.launch({ headless: true });
  const page = await browser.newPage();
  await page.goto(URL_);
  await page.waitForFunction(() => window.__ready || window.__leanui, null, { timeout: 30000 });
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Profiler.enable");
  await cdp.send("Profiler.setSamplingInterval", { interval: 50 });
  await cdp.send("Profiler.start");
  const perOp = await drive(page);
  const { profile } = await cdp.send("Profiler.stop");
  await browser.close();
  fs.writeFileSync(path.join(OUT, `chromium-${OP}.cpuprofile`), JSON.stringify(profile));
  // self time per node from the sample deltas
  const byId = new Map(profile.nodes.map((n) => [n.id, n]));
  const self = new Map();
  for (let i = 0; i < profile.samples.length; i++) {
    const n = byId.get(profile.samples[i]); const dt = (profile.timeDeltas[i + 1] ?? profile.timeDeltas[i]) / 1000;
    const { functionName, url } = n.callFrame; const key = (functionName || "(anonymous)") + (url ? "  " + path.basename(url) : "");
    const e = self.get(key) || { ms: 0, layer: layer(functionName, url) }; e.ms += dt; self.set(key, e);
  }
  self.delete("(idle)");
  report = `chromium ${OP}: ${perOp.toFixed(2)} ms per click (synchronous script), ${REPS} reps\n` + summarise(self);
} else {
  // Gecko profiler: started with the process, dumped at shutdown
  const dump = path.join(os.tmpdir(), `leanui-ff-${process.pid}.json`);
  const browser = await pw.firefox.launch({ headless: true, firefoxUserPrefs: { "privacy.reduceTimerPrecision": false }, env: { ...process.env, MOZ_PROFILER_STARTUP: "1", MOZ_PROFILER_STARTUP_INTERVAL: "0.1", MOZ_PROFILER_STARTUP_FEATURES: "js,stackwalk,cpu", MOZ_PROFILER_STARTUP_ENTRIES: "16777216", MOZ_PROFILER_SHUTDOWN: dump } });
  const page = await browser.newPage();
  await page.goto(URL_);
  await page.waitForFunction(() => window.__ready || window.__leanui, null, { timeout: 30000 });
  const perOp = await drive(page);
  await browser.close();
  await new Promise((r) => setTimeout(r, 1500));
  if (!fs.existsSync(dump)) throw new Error("Firefox wrote no profile (MOZ_PROFILER_SHUTDOWN): " + dump);
  const raw = JSON.parse(fs.readFileSync(dump, "utf8"));
  fs.copyFileSync(dump, path.join(OUT, `firefox-${OP}.json`));
  // processed format: threads[] with samples {stack, time}, stackTable {frame, prefix}, frameTable {func}, funcTable {name}, stringTable
  const self = new Map();
  const visit = (proc) => {
    for (const th of proc.threads || []) {
      if (th.name !== "GeckoMain" || !th.processType || th.processType === "default") { if (th.name !== "GeckoMain") continue; }
      const st = th.stringTable || th.stringArray; const strs = Array.isArray(st) ? st : st?._array || [];
      const S = th.samples, schema = S.schema || {}, data = S.data || [];
      const sStack = schema.stack ?? 0, sTime = schema.time ?? 1;
      const stack = th.stackTable, sSchema = stack.schema, frames = th.frameTable, fSchema = frames.schema;
      const frameOf = (si) => stack.data[si][sSchema.frame];
      const name = (fi) => { const loc = frames.data[fi][fSchema.location]; return typeof loc === "number" ? strs[loc] : String(loc); };
      for (let i = 0; i < data.length; i++) {
        const si = data[i][sStack]; if (si == null) continue;
        const dt = i + 1 < data.length ? data[i + 1][sTime] - data[i][sTime] : 0.1;
        const fn = name(frameOf(si)) || "?";
        const e = self.get(fn) || { ms: 0, layer: layer(fn, fn) }; e.ms += dt; self.set(fn, e);
      }
    }
    for (const p of proc.processes || []) visit(p);
  };
  visit(raw);
  report = `firefox ${OP}: ${perOp.toFixed(2)} ms per click (synchronous script), ${REPS} reps (raw profile: work/profiles/firefox-${OP}.json)\n` + summarise(self);
}
server.close();
fs.writeFileSync(path.join(OUT, `${ENGINE}-${OP}.txt`), report + "\n");
console.log(report);
