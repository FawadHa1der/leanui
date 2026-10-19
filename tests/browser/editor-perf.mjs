// Interaction measurements for the photo editor (examples/Editor.lean), for docs/BENCHMARKS.md:
// opening JPEGs of 1, 4 and 12 MP; slider input to pixels at preview size; brush moves; full-size
// apply and export (time, and the longest frame gap while they run); the layers panel with 10 and
// 100 layers; history with 200 steps; wasm memory; download size.
//   node tests/browser/editor-perf.mjs <url of dist/editor/index.html> [chromium|firefox] [--out file.json] [--quick]
// Every timing is taken in the page with performance.now(). "script" is the synchronous dispatch of
// the event (Lean's update, view and diff, and the runtime applying the buffer, PUT_IMAGE
// included); "frame" runs from the dispatch to the next requestAnimationFrame callback after it
// (layout and the canvas upload happen before that frame's paint). Medians of repeated runs.
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
    window.__nextFrame = () => new Promise((ok) => requestAnimationFrame(() => ok(performance.now())));
    window.__timed = async (fn) => { const t0 = performance.now(); fn(); const t1 = performance.now(); const t2 = await window.__nextFrame(); return [t1 - t0, t2 - t0]; };
    window.__gaps = { on: false, last: 0, max: 0, n: 0 };
    const loop = (t) => { const g = window.__gaps; if (g.on) { if (g.last) { g.max = Math.max(g.max, t - g.last); g.n++; } g.last = t; } requestAnimationFrame(loop); };
    requestAnimationFrame(loop);
    window.__heapMB = () => Math.round(window.__leanui.stats.heapBytes / 1048576);
  });
  return page;
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

// Set a range input and time the input event.
const slide = (page, sel, v) => page.evaluate(([sel, v]) => window.__timed(() => {
  const e = document.querySelector(sel); e.value = String(v); e.dispatchEvent(new Event("input", { bubbles: true }));
}), [sel, v]);
const click = (page, sel) => page.evaluate((sel) => window.__timed(() => document.querySelector(sel).click()), sel);

async function waitIdle(page) {
  await page.waitForFunction(() => !document.querySelector("#busy"), null, { timeout: 600000, polling: 50 });
}

// Time a full-resolution job (click to done) and the longest frame gap while it runs.
async function job(page, sel) {
  await page.evaluate(() => { Object.assign(window.__gaps, { on: true, last: 0, max: 0, n: 0 }); window.__t0 = performance.now(); });
  await page.click(sel);
  await waitIdle(page);
  return page.evaluate(() => { const g = window.__gaps; g.on = false; return { ms: r(performance.now() - window.__t0), maxGap: r(g.max), frames: g.n }; function r(x) { return Math.round(x * 10) / 10; } });
}

// Brush moves on the canvas (synthetic pointer events with the button down).
async function brush(page, moves) {
  return page.evaluate(async (moves) => {
    const c = document.querySelector("#canvas"), r = c.getBoundingClientRect();
    const ev = (type, i, buttons) => new PointerEvent(type, { bubbles: true, cancelable: true, pointerId: 1, buttons,
      clientX: r.left + r.width * (0.2 + 0.6 * (i / moves)), clientY: r.top + r.height * (0.5 + 0.3 * Math.sin(i / 7)) });
    const t = [];
    let t0 = performance.now(); c.dispatchEvent(ev("pointerdown", 0, 1)); const first = performance.now() - t0;
    for (let i = 1; i <= moves; i++) { t0 = performance.now(); c.dispatchEvent(ev("pointermove", i, 1)); t.push(performance.now() - t0); await new Promise((ok) => requestAnimationFrame(ok)); }
    t0 = performance.now(); c.dispatchEvent(ev("pointerup", moves, 0)); const up = performance.now() - t0;
    t.sort((a, b) => a - b);
    return { down: first, moveMedian: t[Math.floor(t.length / 2)], moveMax: t[t.length - 1], up };
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
  // sliders: script and frame times, median of 8 inputs each
  for (const [name, sel, vals] of [["brightness (lookup table)", "#adj-brightness", [10, 20, 30, 40, 50, 40, 30, 20]],
                                   ["saturation (colour matrix)", "#adj-saturation", [10, 20, 30, 40, 50, 40, 30, 20]],
                                   ["blur radius 6", "#blur-radius", [6, 7, 6, 7, 6, 7, 6, 7]],
                                   ["sharpen", "#sharpen-amount", [60, 80, 100, 120, 140, 120, 100, 80]]]) {
    const ts = [];
    for (const v of vals) ts.push(await slide(page, sel, v));
    R[`slider: ${name}`] = { script: r1(median(ts.map((t) => t[0]))), frame: r1(median(ts.map((t) => t[1]))) };
    await click(page, name.startsWith("brightness") || name.startsWith("saturation") ? "#adj-reset" : "#filter-cancel");
  }
  // brush: 40 moves of a 40 px brush
  await page.click("#tool-brush");
  await slide(page, "#brush-size", 40);
  const b = await brush(page, quick ? 10 : 40);
  R["brush"] = { strokeStart: r1(b.down), moveMedian: r1(b.moveMedian), moveMax: r1(b.moveMax), strokeEnd: r1(b.up) };
  // full-resolution jobs
  await slide(page, "#adj-brightness", 30);
  R["apply brightness"] = await job(page, "#adj-apply");
  await slide(page, "#blur-radius", 6);
  R["apply blur 6"] = await job(page, "#blur-apply");
  R["edge detect"] = await job(page, "#edges");
  const [download] = await Promise.all([page.waitForEvent("download", { timeout: 600000 }), (async () => { R["export PNG"] = await job(page, "#export"); })()]);
  R.pngKB = Math.round(fs.statSync(await download.path()).size / 1024);
  // geometry is synchronous
  const rot = await click(page, "#rot-cw");
  R["rotate 90"] = { script: r1(rot[0]), frame: r1(rot[1]) };
  R.heapEndMB = await page.evaluate(() => window.__heapMB());
  results.sizes[key] = R;
  await page.close();
}

// ---- UI scaling: layers and history (1 MP image) ----
{
  console.error(`[${engine}] UI scaling`);
  const page = await fresh();
  await openJpeg(page, 1152, 864);
  const U = {};
  for (const n of quick ? [10] : [10, 100]) {
    const have = await page.$$eval(".layers li", (es) => es.length);
    for (let i = have; i < n; i++) await page.evaluate(() => document.querySelector("#layer-add").click());
    const ids = await page.$$eval(".layers li", (es) => es.map((e) => e.id));
    const sel = [], vis = [];
    for (let k = 0; k < 5; k++) {
      sel.push(await click(page, `#${ids[(k * 7) % ids.length]} .name`));
      vis.push(await click(page, `#${ids[(k * 7 + 3) % ids.length]} input[type=checkbox]`));
    }
    U[`${n} layers: select a layer`] = { script: r1(median(sel.map((t) => t[0]))), frame: r1(median(sel.map((t) => t[1]))) };
    U[`${n} layers: toggle visibility (recomposite)`] = { script: r1(median(vis.map((t) => t[0]))), frame: r1(median(vis.map((t) => t[1]))) };
    U[`${n} layers: wasm heap MB`] = await page.evaluate(() => window.__heapMB());
  }
  await page.close();
  // history: 200 steps of a cheap edit (layer opacity), then jumps and a new step
  const p2 = await fresh();
  await openJpeg(p2, 1152, 864);
  await p2.evaluate(() => document.querySelector("#layer-add").click());
  for (let i = 0; i < 199; i++) await p2.evaluate((v) => { const e = document.querySelector("#layer-opacity"); e.value = String(v); e.dispatchEvent(new Event("change", { bubbles: true })); }, 50 + (i % 50));
  U["history steps"] = await p2.$$eval("#history li", (es) => es.length);
  const jumps = [];
  for (const i of [10, 150, 60, 199, 100]) jumps.push(await click(p2, `#step-${Math.min(i, U["history steps"] - 1)}`));
  U["200 steps: jump in history"] = { script: r1(median(jumps.map((t) => t[0]))), frame: r1(median(jumps.map((t) => t[1]))) };
  const undos = [];
  for (let k = 0; k < 5; k++) undos.push(await click(p2, "#undo"));
  U["200 steps: undo"] = { script: r1(median(undos.map((t) => t[0]))), frame: r1(median(undos.map((t) => t[1]))) };
  await click(p2, `#step-${U["history steps"] - 1}`);
  const adds = [];
  for (let k = 0; k < 5; k++) adds.push(await p2.evaluate((v) => window.__timed(() => { const e = document.querySelector("#layer-opacity"); e.value = String(v); e.dispatchEvent(new Event("change", { bubbles: true })); }), 20 + k));
  U["200 steps: a new step (drops the oldest)"] = { script: r1(median(adds.map((t) => t[0]))), frame: r1(median(adds.map((t) => t[1]))) };
  results.ui = U;
  await p2.close();
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
