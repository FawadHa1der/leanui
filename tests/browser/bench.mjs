// LeanUI benchmark harness: the js-framework-benchmark keyed operations, run against LeanUI
// (examples/Bench.lean compiled to wasm64) and a hand-written vanilla reference
// (bench/vanilla/index.html) with the same markup, stylesheet and labels; and, when asked for, the
// same Lean app run by lean-vir's interpreter ("leanvir": dist/vir/bench, built by vir/build.sh).
//
//   node tests/browser/bench.mjs [--engines chromium,firefox] [--runs 7] [--impls leanui,vanilla,leanvir]
//                                [--json results.json] [--leanui-dir dist/bench] [--leanvir-dir dist/vir/bench]
//                                [--only create1k,...] [--cpu-only]   (no startup and memory runs)
//
// The default --impls is leanui,vanilla: leanvir needs the separate lean-vir build, and the
// interpreter's runs take most of the time.
// Run it under the host browser lock (one heavy browser at a time). It serves the pages itself.
//
// Chromium: every measurement is one traced click. "script" is the click's EventDispatch (the
// handler: for LeanUI, Lean's update, view and diff plus applying the commands); "render" is the
// main-thread work of the frame that follows (style, layout, pre-paint, paint, layerize, commit);
// "total" is their sum: the CPU time the click costs, without the wait for the next vsync (which
// is up to a frame of idle time, the same for every implementation). Firefox has no trace access
// here, so it reports in-page times: "script" (synchronous click) and "layout" (script plus a
// forced layout). Do not use Playwright's Firefox build to judge wasm speed: it runs wasm about
// 8x slower than release Firefox; tests/browser/selfbench.mjs measures release browsers.
// Each run loads a fresh page, does the operation's setup and warm-ups, then measures once.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";
import { pw } from "./playwright.mjs";
import { fileURLToPath } from "node:url";
import { OPS as ALL_OPS } from "../../bench/ops.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

// ---------- options ----------
const argv = process.argv.slice(2);
const opt = (name, dflt) => { const i = argv.indexOf("--" + name); return i >= 0 ? argv[i + 1] : dflt; };
const ENGINES = opt("engines", "chromium").split(",");
const RUNS = +opt("runs", "7");
const IMPLS = opt("impls", "leanui,vanilla").split(",");
const JSON_OUT = opt("json", null);
const ONLY = opt("only", null);
// another LeanUI build to measure in place of dist/bench (e.g. an allocator variant)
const LEANUI_DIR = opt("leanui-dir", "dist/bench").replace(/\/?$/, "/");
const LEANVIR_DIR = opt("leanvir-dir", "dist/vir/bench").replace(/\/?$/, "/");
const SKIP_CPU = argv.includes("--no-cpu");
// only the per-operation CPU times (no startup or memory runs), e.g. for A/B runs of two builds
const CPU_ONLY = argv.includes("--cpu-only");
// ms of busy-waiting in the page before each measured click: an idle renderer is often moved to an
// efficiency core, which makes single-click timings bimodal; spinning first applies to all alike
const SPIN = +opt("spin", "30");

// ---------- a static server: each implementation at /<impl>/, and bench/bench.css ----------
const DIRS = { leanui: LEANUI_DIR, vanilla: "bench/vanilla/", leanvir: LEANVIR_DIR };
for (const impl of IMPLS) if (!DIRS[impl] || !fs.existsSync(path.join(ROOT, DIRS[impl], "index.html"))) {
  console.error(`no ${impl} build at ${DIRS[impl] ?? "?"} (leanui: tools/build-app.sh BenchApp bench; leanvir: vir/build.sh bench)`);
  process.exit(2);
}
const MOUNTS = [...Object.entries(DIRS).map(([impl, dir]) => [`/${impl}/`, dir]), ["/", "bench/"]];
const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".mjs": "text/javascript", ".wasm": "application/wasm", ".css": "text/css", ".json": "application/json" };
const served = [];   // every file served, in order: startup() counts what one page load fetched
const server = http.createServer((req, res) => {
  const url = decodeURIComponent(new URL(req.url, "http://x").pathname);
  for (const [prefix, dir] of MOUNTS) {
    if (!url.startsWith(prefix)) continue;
    let file = path.join(ROOT, dir, url.slice(prefix.length) || "index.html");
    if (!file.startsWith(path.join(ROOT, dir))) break;
    if (fs.existsSync(file) && fs.statSync(file).isDirectory()) file = path.join(file, "index.html");
    if (!fs.existsSync(file)) break;
    served.push(file);
    res.writeHead(200, { "content-type": TYPES[path.extname(file)] || "application/octet-stream", "cache-control": "no-store" });
    res.end(fs.readFileSync(file));
    return;
  }
  res.writeHead(404); res.end("not found");
});
await new Promise((ok) => server.listen(0, "127.0.0.1", ok));
const BASE = `http://127.0.0.1:${server.address().port}`;
const PAGES = Object.fromEntries(Object.keys(DIRS).map((impl) => [impl, `${BASE}/${impl}/index.html`]));

// ---------- the operations (js-framework-benchmark CPU suite, keyed): bench/ops.mjs ----------
const row = (i, cell) => `#tbody tr:nth-child(${i}) td:nth-child(${cell}) a`;
const OPS = ALL_OPS.filter((o) => !ONLY || ONLY.split(",").includes(o.name));

const median = (a) => { const s = a.slice().sort((x, y) => x - y); return s.length ? s[s.length >> 1] : NaN; };
const r2 = (x) => Math.round(x * 100) / 100;
const settle = (page) => page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(r, 30)))));
const clickSync = (page, sel) => page.evaluate((sel) => { const e = document.querySelector(sel); if (!e) throw new Error("no " + sel); e.click(); }, sel);

async function open(browser, impl) {
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  page.on("console", (m) => { if (m.type() === "error") errors.push(m.text()); });
  await page.goto(PAGES[impl]);
  await page.waitForFunction(() => window.__ready, null, { timeout: 30000 });
  await settle(page);
  return { page, errors };
}

// One traced click in Chromium: script = the click's EventDispatch, render = the frame work after it.
const FRAME_WORK = new Set(["UpdateLayoutTree", "Layout", "PrePaint", "Paint", "Layerize", "Commit", "UpdateLayer", "CompositeLayers"]);
async function tracedClick(page, cdp, sel) {
  const events = [];
  const onData = ({ value }) => { for (const e of value) events.push(e); };
  cdp.on("Tracing.dataCollected", onData);
  await cdp.send("Tracing.start", {
    transferMode: "ReportEvents",
    traceConfig: { recordMode: "recordAsMuchAsPossible", includedCategories: ["devtools.timeline", "disabled-by-default-devtools.timeline"] },
  });
  await page.evaluate((ms) => { for (const end = performance.now() + ms; performance.now() < end; ); }, SPIN);
  await page.click(sel, { timeout: 60000 });   // lean-vir takes seconds for 10,000 rows
  await settle(page);
  const done = new Promise((r) => cdp.once("Tracing.tracingComplete", r));
  await cdp.send("Tracing.end");
  await done;
  cdp.off("Tracing.dataCollected", onData);
  const click = events.find((e) => e.name === "EventDispatch" && e.args?.data?.type === "click");
  if (!click) throw new Error("no click EventDispatch in the trace");
  const scriptEnd = click.ts + (click.dur || 0);
  // frame work on the renderer main thread after the handler (layouts forced inside the handler
  // are already part of its duration)
  let render = 0;
  const begun = new Map();
  for (const e of events) {
    if (e.pid !== click.pid || e.tid !== click.tid || e.ts < scriptEnd || !FRAME_WORK.has(e.name)) continue;
    if (e.ph === "X") render += e.dur || 0;
    else if (e.ph === "B") begun.set(e.name, e.ts);
    else if (e.ph === "E" && begun.has(e.name)) { render += e.ts - begun.get(e.name); begun.delete(e.name); }
  }
  const script = (click.dur || 0) / 1000;
  return { total: script + render / 1000, script, render: render / 1000 };
}

// Firefox (no trace): synchronous click, then a forced layout.
async function timedClick(page, sel) {
  const r = await page.evaluate((sel) => {
    const e = document.querySelector(sel); if (!e) throw new Error("no " + sel);
    const t0 = performance.now(); e.click(); const t1 = performance.now(); document.body.offsetHeight; const t2 = performance.now();
    return { script: t1 - t0, layout: t2 - t0 };
  }, sel);
  await settle(page);
  return r;
}

async function runOp(browser, engine, impl, op) {
  const samples = [];
  for (let run = 0; run < RUNS; run++) {
    const { page, errors } = await open(browser, impl);
    for (const sel of op.warm) { await clickSync(page, sel); await settle(page); }
    let m;
    if (engine === "chromium") {
      const cdp = await page.context().newCDPSession(page);
      m = await tracedClick(page, cdp, op.click);
      await cdp.detach();
    } else m = await timedClick(page, op.click);
    if (errors.length) throw new Error(`${impl} ${op.name}: ${errors.join("; ")}`);
    samples.push(m);
    await page.close();
  }
  const keys = Object.keys(samples[0]);
  return Object.fromEntries(keys.map((k) => [k, r2(median(samples.map((s) => s[k])))]));
}

// Memory after a sequence of operations (Chromium: JS heap after a full GC, DOM node count, the
// ArrayBuffer backing stores, wasm memories included, and for LeanUI's wasm64 build its linear
// memory, which only grows). lean-vir's createProgram does not expose its memory: wasmMB is null
// (not available) for leanvir, whose wasm memory is counted in buffersMB only.
const MEMORY = [
  { name: "ready", desc: "after load", steps: [] },
  { name: "run1k", desc: "after creating 1,000 rows", steps: ["#run"] },
  { name: "update5", desc: "after 5 updates of every 10th row", steps: ["#run", "#update", "#update", "#update", "#update", "#update"] },
  { name: "runClear5", desc: "after 5 create/clear cycles", steps: ["#run", "#clear", "#run", "#clear", "#run", "#clear", "#run", "#clear", "#run", "#clear"] },
  { name: "run10k", desc: "after creating 10,000 rows", steps: ["#runlots"] },
];
async function memory(browser, impl) {
  const out = {};
  for (const m of MEMORY) {
    const { page } = await open(browser, impl);
    for (const sel of m.steps) { await clickSync(page, sel); await settle(page); }
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("HeapProfiler.collectGarbage");
    await cdp.send("Performance.enable");
    const { metrics } = await cdp.send("Performance.getMetrics");
    const get = (n) => metrics.find((x) => x.name === n)?.value ?? 0;
    const { backingStorageSize } = await cdp.send("Runtime.getHeapUsage");
    // heapBytes: set by the wasm64 host on every update; lean-vir's host never sets it
    const wasm = await page.evaluate(() => window.__leanui ? window.__leanui.stats.heapBytes ?? null : 0);
    out[m.name] = { jsHeapMB: r2(get("JSHeapUsedSize") / 1048576), wasmMB: wasm === null ? null : r2(wasm / 1048576),
      buffersMB: r2(backingStorageSize / 1048576), domNodes: get("Nodes") };
    await page.close();
  }
  return out;
}

// Startup: navigation to ready (median of RUNS loads), and what the page transfers.
async function startup(browser, impl) {
  const times = [], boots = [];
  for (let i = 0; i < RUNS; i++) {
    const first = served.length;
    const { page } = await open(browser, impl);
    times.push(await page.evaluate(() => window.__ready));
    boots.push(await page.evaluate(() => window.__leanui ? window.__leanui.bootMs : 0));
    if (i === 0) var files = served.slice(first);
    await page.close();
  }
  // the files of the first load: their bytes as served, and brotli (quality 11) of each one once
  const bytes = files.reduce((n, f) => n + fs.statSync(f).size, 0);
  let brotli = 0;
  for (const f of new Set(files)) brotli += zlib.brotliCompressSync(fs.readFileSync(f), { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 11 } }).length;
  return { readyMs: r2(median(times)), bootMs: r2(median(boots)), transferKB: r2(bytes / 1024), brotliKB: r2(brotli / 1024) };
}

// Every implementation must build the same table (same LCG, same markup).
async function crossCheck(browser) {
  const texts = {};
  for (const impl of IMPLS) {
    const { page } = await open(browser, impl);
    await clickSync(page, "#run"); await settle(page);
    await clickSync(page, "#update"); await settle(page);
    await clickSync(page, row(3, 2)); await settle(page);
    texts[impl] = await page.$eval("#tbody", (t) => [t.children.length, t.textContent, [...t.children].findIndex((r) => r.className === "danger")].join("|"));
    await page.close();
  }
  const vals = Object.values(texts);
  return vals.every((v) => v === vals[0]);
}

const results = { date: new Date().toISOString(), runs: RUNS, engines: {} };
for (const engine of ENGINES) {
  // Firefox rounds performance.now() to 1 ms unless told not to
  const firefoxUserPrefs = engine === "firefox" ? { "privacy.reduceTimerPrecision": false, "privacy.resistFingerprinting.reduceTimerPrecision.jitter": false } : undefined;
  const browser = await pw[engine].launch({ headless: true, firefoxUserPrefs });
  const R = { version: browser.version(), cpu: {}, memory: {}, startup: {} };
  results.engines[engine] = R;
  if (IMPLS.length > 1) R.sameTables = await crossCheck(browser);
  for (const op of SKIP_CPU ? [] : OPS) {
    R.cpu[op.name] = {};
    for (const impl of IMPLS) {
      R.cpu[op.name][impl] = await runOp(browser, engine, impl, op);
      process.stderr.write(`${engine} ${op.name.padEnd(10)} ${impl.padEnd(8)} ${JSON.stringify(R.cpu[op.name][impl])}\n`);
    }
  }
  for (const impl of CPU_ONLY ? [] : IMPLS) {
    R.startup[impl] = await startup(browser, impl);
    if (engine === "chromium") R.memory[impl] = await memory(browser, impl);
  }
  await browser.close();
}
server.close();

// ---------- report ----------
// ratios: each LeanUI build against vanilla, and the interpreter against the compiled build
const RATIOS = [["leanui", "vanilla"], ["leanvir", "vanilla"], ["leanvir", "leanui"]].filter((p) => p.every((i) => IMPLS.includes(i)));
const mb = (x) => (x === null ? "n/a" : `${x} MB`);
const lines = [];
for (const [engine, R] of Object.entries(results.engines)) {
  lines.push(`\n## ${engine} ${R.version}  (median of ${RUNS} runs${R.sameTables === undefined ? "" : `; identical tables: ${R.sameTables}`})\n`);
  const metric = engine === "chromium" ? ["total", "script", "render"] : ["layout", "script"];
  const head = ["operation", ...IMPLS.flatMap((i) => metric.map((m) => `${i} ${m}`)), ...RATIOS.map(([a, b]) => `${a}/${b} (${metric[0]})`)];
  lines.push("| " + head.join(" | ") + " |", "|" + head.map(() => "---").join("|") + "|");
  for (const op of SKIP_CPU ? [] : OPS) {
    const c = R.cpu[op.name];
    const cells = [op.desc, ...IMPLS.flatMap((i) => metric.map((m) => `${c[i][m].toFixed(2)} ms`)),
      ...RATIOS.map(([a, b]) => `${(c[a][metric[0]] / c[b][metric[0]]).toFixed(2)}×`)];
    lines.push("| " + cells.join(" | ") + " |");
  }
  if (Object.keys(R.startup).length) {
    lines.push("", "| startup | " + IMPLS.join(" | ") + " |", "|---|" + IMPLS.map(() => "---").join("|") + "|");
    for (const k of ["readyMs", "bootMs", "transferKB", "brotliKB"]) lines.push(`| ${k} | ` + IMPLS.map((i) => R.startup[i][k]).join(" | ") + " |");
  }
  if (Object.keys(R.memory).length) {
    lines.push("", "| memory | " + IMPLS.map((i) => `${i} JS heap / wasm / array buffers / DOM nodes`).join(" | ") + " |", "|---|" + IMPLS.map(() => "---").join("|") + "|");
    for (const m of MEMORY) lines.push(`| ${m.desc} | ` + IMPLS.map((i) => { const x = R.memory[i][m.name]; return `${mb(x.jsHeapMB)} / ${mb(x.wasmMB)} / ${mb(x.buffersMB)} / ${x.domNodes}`; }).join(" | ") + " |");
  }
}
console.log(lines.join("\n"));
if (JSON_OUT) fs.writeFileSync(JSON_OUT, JSON.stringify(results, null, 1));
