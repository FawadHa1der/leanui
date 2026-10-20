// Interaction measurements for the photo editor (examples/Editor.lean), for docs/BENCHMARKS.md:
// opening JPEGs of 1, 4 and 12 MP; slider input to pixels at preview size; brush moves; full-size
// apply and export (time, and the longest frame gap while they run); the layers panel with 10 and
// 100 layers; history with 200 steps; wasm memory; download size.
//   node tests/browser/editor-perf.mjs <url of dist/editor/index.html> [chromium|firefox] [--out file.json] [--quick]
// In the page, with performance.now(): "script" is the synchronous dispatch of the event (Lean's
// update, view and diff, and the runtime applying the buffer, PUT_IMAGE included); "toPixels" runs
// from the dispatch to the end of the next frame's rendering (a task queued from that frame's
// requestAnimationFrame callback runs after its style, layout and paint). In Chromium every slider
// input and UI click is also traced, as tests/browser/bench.mjs does: "trace.script" is the
// event's dispatch, "trace.render" the main-thread frame work after it (style, layout, pre-paint,
// paint, layerize, commit). The UI-scaling rows load a fresh page per run (the setup, a warm-up
// click, then one measured click) and give medians of the runs. Opening a JPEG is one run per
// size; the sliders are medians of 8 inputs; the brush, of 40 moves.
import { pw } from "./playwright.mjs";
import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";
import { fileURLToPath } from "node:url";

const args = process.argv.slice(2);
const url = args.find((a) => a.startsWith("http")) || "http://127.0.0.1:5331/editor/index.html";
const engine = args.find((a) => a === "chromium" || a === "firefox") || "chromium";
const outIdx = args.indexOf("--out");
const out = outIdx >= 0 ? args[outIdx + 1] : null;
const quick = args.includes("--quick");
const RUNS = quick ? 3 : 5;
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

const median = (xs) => { const s = [...xs].sort((a, b) => a - b); return s.length ? s[Math.floor((s.length - 1) / 2)] : NaN; };
const r1 = (x) => Math.round(x * 10) / 10;
const browser = await pw[engine].launch({ headless: true });
const results = { engine, version: browser.version(), url, sizes: {}, ui: {}, memory: {}, download: {} };
const errors = [];

async function fresh() {
  const page = await browser.newPage({ viewport: { width: 1600, height: 1000 }, acceptDownloads: true });
  page.on("pageerror", (e) => errors.push("pageerror: " + e.message));
  page.on("console", (m) => { if (m.type() === "error") errors.push("console: " + m.text()); });
  await page.goto(url);
  await page.waitForFunction(() => window.__leanui, null, { timeout: 30000 });
  await page.evaluate(() => {
    // helpers in the page: timed dispatch, the next frame, frame gaps
    window.__nextFrame = () => new Promise((ok) => requestAnimationFrame(() => setTimeout(() => ok(performance.now()), 0)));
    window.__timed = async (fn) => { const t0 = performance.now(); fn(); const t1 = performance.now(); const t2 = await window.__nextFrame(); return [t1 - t0, t2 - t0]; };
    window.__gaps = { on: false, last: 0, max: 0, n: 0 };
    const loop = (t) => { const g = window.__gaps; if (g.on) { if (g.last) { g.max = Math.max(g.max, t - g.last); g.n++; } g.last = t; } requestAnimationFrame(loop); };
    requestAnimationFrame(loop);
    window.__heapMB = () => Math.round(window.__leanui.stats.heapBytes / 1048576);
  });
  return page;
}

// Chromium: one traced action. script = the action's event dispatches (outermost ones), render =
// the main-thread frame work after the last of them; also the in-page [script, toPixels].
const FRAME_WORK = new Set(["UpdateLayoutTree", "Layout", "PrePaint", "Paint", "Layerize", "Commit", "UpdateLayer", "CompositeLayers"]);
const DISPATCH = new Set(["click", "input", "change", "pointerdown", "pointermove", "pointerup"]);
async function traced(page, fn, arg) {
  if (engine !== "chromium") { const [script, toPixels] = await page.evaluate(fn, arg); return { script, toPixels }; }
  const cdp = await page.context().newCDPSession(page);
  const events = [];
  const onData = ({ value }) => { for (const e of value) events.push(e); };
  cdp.on("Tracing.dataCollected", onData);
  await cdp.send("Tracing.start", { transferMode: "ReportEvents",
    traceConfig: { recordMode: "recordAsMuchAsPossible", includedCategories: ["devtools.timeline", "disabled-by-default-devtools.timeline"] } });
  const [script, toPixels] = await page.evaluate(fn, arg);
  const done = new Promise((r) => cdp.once("Tracing.tracingComplete", r));
  await cdp.send("Tracing.end");
  await done;
  cdp.off("Tracing.dataCollected", onData);
  await cdp.detach();
  const ds = events.filter((e) => e.name === "EventDispatch" && e.ph === "X" && DISPATCH.has(e.args?.data?.type)).sort((a, b) => a.ts - b.ts);
  if (!ds.length) throw new Error("no event dispatch in the trace");
  let tScript = 0, end = 0;
  for (const e of ds) if (e.ts >= end) { tScript += e.dur || 0; end = e.ts + (e.dur || 0); }
  const { pid, tid } = ds[0];
  let render = 0;
  const begun = new Map();
  for (const e of events) {
    if (e.pid !== pid || e.tid !== tid || e.ts < end || !FRAME_WORK.has(e.name)) continue;
    if (e.ph === "X") render += e.dur || 0;
    else if (e.ph === "B") begun.set(e.name, e.ts);
    else if (e.ph === "E" && begun.has(e.name)) { render += e.ts - begun.get(e.name); begun.delete(e.name); }
  }
  return { script, toPixels, trace: { script: tScript / 1000, render: render / 1000, total: (tScript + render) / 1000 } };
}
// medians of each field of a list of measurements (nested one level)
function medians(ms) {
  const o = {};
  for (const k of Object.keys(ms[0])) o[k] = typeof ms[0][k] === "object" ? medians(ms.map((m) => m[k])) : r1(median(ms.map((m) => m[k])));
  return o;
}

// A JPEG of w×h made by the browser (a smooth photo-like picture with some detail).
async function openJpeg(page, w, h) {
  return page.evaluate(async ([w, h]) => {
    const c = new OffscreenCanvas(w, h), x = c.getContext("2d");
    const g = x.createLinearGradient(0, 0, w, h); g.addColorStop(0, "#2a6"); g.addColorStop(0.5, "#fc6"); g.addColorStop(1, "#36c");
    x.fillStyle = g; x.fillRect(0, 0, w, h);
    for (let i = 0; i < 400; i++) { x.fillStyle = `hsla(${(i * 37) % 360},70%,50%,.35)`; x.beginPath(); x.arc((i * 7919) % w, (i * 104729) % h, 20 + (i % 9) * 15, 0, 6.3); x.fill(); }
    const blob = await c.convertToBlob({ type: "image/jpeg", quality: 0.9 });
    const file = new File([blob], `photo-${w}x${h}.jpg`, { type: "image/jpeg" });
    const dt = new DataTransfer(); dt.items.add(file);
    const input = document.querySelector("#open");
    input.files = dt.files;
    const t0 = performance.now();
    input.dispatchEvent(new Event("change", { bubbles: true }));
    // until the canvas has the image's preview size and the status names the file
    for (;;) {
      await new Promise((ok) => requestAnimationFrame(ok));
      const s = document.querySelector("#status");
      if (s && s.textContent.startsWith(`photo-${w}x${h}:`)) break;
      if (performance.now() - t0 > 60000) throw new Error("open timed out");
    }
    return { ms: performance.now() - t0, bytes: blob.size };
  }, [w, h]);
}

// Set a range input, or click, and time it (traced in Chromium).
const slideFn = ([sel, v]) => window.__timed(() => { const e = document.querySelector(sel); e.value = String(v); e.dispatchEvent(new Event("input", { bubbles: true })); });
const clickFn = (sel) => window.__timed(() => document.querySelector(sel).click());
const changeFn = ([sel, v]) => window.__timed(() => { const e = document.querySelector(sel); e.value = String(v); e.dispatchEvent(new Event("change", { bubbles: true })); });
const slide = (page, sel, v) => traced(page, slideFn, [sel, v]);
const click = (page, sel) => traced(page, clickFn, sel);
// untimed, for setup and warm-ups
const slideQuiet = (page, sel, v) => page.evaluate(slideFn, [sel, v]);
const clickQuiet = (page, sel) => page.evaluate(clickFn, sel);

async function waitIdle(page) {
  await page.waitForFunction(() => !document.querySelector("#busy"), null, { timeout: 600000, polling: 50 });
}

// Time a full-resolution job (click to done) and the longest frame gap while it runs.
async function job(page, sel) {
  await page.evaluate(() => { Object.assign(window.__gaps, { on: true, last: 0, max: 0, n: 0 }); window.__t0 = performance.now(); });
  await page.evaluate((sel) => document.querySelector(sel).click(), sel);   // panels may be collapsed
  await waitIdle(page);
  return page.evaluate(() => { const g = window.__gaps; g.on = false; return { ms: r(performance.now() - window.__t0), maxGap: r(g.max), frames: g.n }; function r(x) { return Math.round(x * 10) / 10; } });
}

// Brush moves on the canvas (synthetic pointer events with the button down).
async function brush(page, moves) {
  return page.evaluate(async (moves) => {
    const c = document.querySelector("#canvas"), r = c.getBoundingClientRect();
    const ev = (type, i, buttons) => new PointerEvent(type, { bubbles: true, cancelable: true, pointerId: 1, buttons,
      clientX: r.left + r.width * (0.2 + 0.6 * (i / moves)), clientY: r.top + r.height * (0.5 + 0.3 * Math.sin(i / 7)) });
    const t = [], px = [];
    let t0 = performance.now(); c.dispatchEvent(ev("pointerdown", 0, 1)); const first = performance.now() - t0;
    await window.__nextFrame();
    // each move, then its frame: script, and the time to the end of that frame's rendering
    for (let i = 1; i <= moves; i++) {
      t0 = performance.now(); c.dispatchEvent(ev("pointermove", i, 1)); t.push(performance.now() - t0);
      px.push((await window.__nextFrame()) - t0);
    }
    t0 = performance.now(); c.dispatchEvent(ev("pointerup", moves, 0)); const up = performance.now() - t0;
    t.sort((a, b) => a - b); px.sort((a, b) => a - b);
    return { down: first, moveMedian: t[Math.floor(t.length / 2)], moveMax: t[t.length - 1],
             toPixelsMedian: px[Math.floor(px.length / 2)], toPixelsMax: px[px.length - 1], up };
  }, moves);
}

const SIZES = quick ? [[1152, 864]] : [[1152, 864], [2304, 1728], [4000, 3000]];
for (const [w, h] of SIZES) {
  const key = `${Math.round(w * h / 1e6)} MP`;
  console.error(`[${engine}] ${key}`);
  const page = await fresh();
  const R = { boot: r1(await page.evaluate(() => window.__leanui.bootMs)) };
  const opened = await openJpeg(page, w, h);
  R.openMs = r1(opened.ms); R.jpegKB = Math.round(opened.bytes / 1024);
  R.heapAfterOpenMB = await page.evaluate(() => window.__heapMB());
  R.preview = await page.$eval("#canvas", (c) => `${c.width}×${c.height}`);
  // sliders: median of 8 inputs each
  for (const [name, sel, vals] of [["brightness (lookup table)", "#adj-brightness", [10, 20, 30, 40, 50, 40, 30, 20]],
                                   ["saturation (colour matrix)", "#adj-saturation", [10, 20, 30, 40, 50, 40, 30, 20]],
                                   ["blur radius 6", "#blur-radius", [6, 7, 6, 7, 6, 7, 6, 7]],
                                   ["sharpen", "#sharpen-amount", [60, 80, 100, 120, 140, 120, 100, 80]]]) {
    const ts = [];
    for (const v of vals) ts.push(await slide(page, sel, v));
    R[`slider: ${name}`] = medians(ts);
    await clickQuiet(page, name.startsWith("brightness") || name.startsWith("saturation") ? "#adj-reset" : "#filter-cancel");
  }
  // brush: 40 moves of a 40 px brush
  await page.click("#tool-brush");
  await slideQuiet(page, "#brush-size", 40);
  const b = await brush(page, quick ? 10 : 40);
  R["brush"] = { strokeStart: r1(b.down), moveMedian: r1(b.moveMedian), moveMax: r1(b.moveMax),
                 toPixelsMedian: r1(b.toPixelsMedian), toPixelsMax: r1(b.toPixelsMax), strokeEnd: r1(b.up) };
  // full-resolution jobs
  await slideQuiet(page, "#adj-brightness", 30);
  R["apply brightness"] = await job(page, "#adj-apply");
  await slideQuiet(page, "#blur-radius", 6);
  R["apply blur 6"] = await job(page, "#blur-apply");
  R["edge detect"] = await job(page, "#edges");
  const [download] = await Promise.all([page.waitForEvent("download", { timeout: 600000 }), (async () => { R["export PNG"] = await job(page, "#export"); })()]);
  R.pngKB = Math.round(fs.statSync(await download.path()).size / 1024);
  // geometry runs as a job too
  R["rotate 90"] = await job(page, "#rot-cw");
  R.heapEndMB = await page.evaluate(() => window.__heapMB());
  results.sizes[key] = R;
  await page.close();
}

// ---- UI scaling: layers and history (1 MP image), a fresh page per run ----
async function layersPage(n) {
  const page = await fresh();
  await openJpeg(page, 1152, 864);
  await page.evaluate((n) => { while (document.querySelectorAll(".layers li").length < n) document.querySelector("#layer-add").click(); }, n);
  return page;
}
async function historyPage() {
  const page = await fresh();
  await openJpeg(page, 1152, 864);
  await page.evaluate(() => {
    document.querySelector("#layer-add").click();
    // 199 cheap edits (the layer's opacity): 200 steps with the opening
    for (let i = 0; i < 199; i++) { const e = document.querySelector("#layer-opacity"); e.value = String(50 + (i % 50)); e.dispatchEvent(new Event("change", { bubbles: true })); }
  });
  return page;
}
// the k-th layer that is not the active one, as a selector
const otherLayer = (page, k, part) => page.$$eval(".layers li:not(.active)", (es, [k, part]) => `#${es[Math.floor(es.length * k)].id} ${part}`, [k, part]);
async function uiRuns(make, warm, measure) {
  const ms = [];
  for (let run = 0; run < RUNS; run++) {
    const page = await make();
    await warm(page);
    ms.push(await measure(page));
    await page.close();
  }
  return medians(ms);
}
{
  console.error(`[${engine}] UI scaling`);
  const U = {};
  for (const n of quick ? [10] : [10, 100]) {
    U[`${n} layers: select a layer`] = await uiRuns(() => layersPage(n),
      async (p) => clickQuiet(p, await otherLayer(p, 0.25, ".name")),
      async (p) => click(p, await otherLayer(p, 0.75, ".name")));
    U[`${n} layers: toggle visibility (recomposite)`] = await uiRuns(() => layersPage(n),
      async (p) => { const c = await otherLayer(p, 0.25, "input[type=checkbox]"); await clickQuiet(p, c); await clickQuiet(p, c); },
      async (p) => click(p, await otherLayer(p, 0.75, "input[type=checkbox]")));
    const p = await layersPage(n);
    U[`${n} layers: wasm heap MB`] = await p.evaluate(() => window.__heapMB());
    await p.close();
  }
  const steps = await (async () => { const p = await historyPage(); const k = await p.$$eval("#history li", (es) => es.length); await p.close(); return k; })();
  U["history steps"] = steps;
  U["200 steps: jump in history"] = await uiRuns(historyPage, (p) => clickQuiet(p, "#step-10"), (p) => click(p, "#step-150"));
  U["200 steps: undo"] = await uiRuns(historyPage, (p) => clickQuiet(p, "#undo"), (p) => click(p, "#undo"));
  U["200 steps: a new step (drops the oldest)"] = await uiRuns(historyPage,
    (p) => p.evaluate(changeFn, ["#layer-opacity", 21]),
    (p) => traced(p, changeFn, ["#layer-opacity", 22]));
  results.ui = U;
}

// ---- memory: 12 MP, then 50 brush strokes ----
if (!quick) {
  console.error(`[${engine}] memory`);
  const page = await fresh();
  const M = { atLoadMB: await page.evaluate(() => window.__heapMB()) };
  await openJpeg(page, 4000, 3000);
  M.after12MPOpenMB = await page.evaluate(() => window.__heapMB());
  await page.click("#tool-brush");
  for (let i = 0; i < 50; i++) await brush(page, 3);
  M.after50StrokesMB = await page.evaluate(() => window.__heapMB());
  M.historySteps = await page.$$eval("#history li", (es) => es.length);
  results.memory = M;
  await page.close();
}

// ---- download size (brotli 11 and gzip 9 of what the page loads) ----
for (const f of ["app.wasm", "app.js", "leanui.js", "index.html"]) {
  const p = path.join(ROOT, "dist/editor", f);
  if (!fs.existsSync(p)) continue;
  const b = fs.readFileSync(p);
  results.download[f] = { raw: b.length, brotli: zlib.brotliCompressSync(b, { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 11 } }).length, gzip: zlib.gzipSync(b, { level: 9 }).length };
}

await browser.close();
results.errors = errors;
if (out) fs.writeFileSync(out, JSON.stringify(results, null, 1));
console.log(JSON.stringify(results, null, 1));
process.exit(errors.length ? 1 : 0);
