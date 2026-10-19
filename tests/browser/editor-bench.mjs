// Photo-editor image operations: Lean (compiled to wasm64) against the same algorithms in plain
// JavaScript (bench/editor/ops.js) and against canvas built-ins, in one browser process.
//
//   tools/build-app.sh EditorBenchApp editor-bench          # dist/editor-bench
//   .lake/build/bin/leanui serve dist --port 5341 --quiet &
//   node tests/browser/editor-bench.mjs http://127.0.0.1:5341/ [chromium|firefox ...]
//        [--sizes 1,4,12] [--runs 5] [--out bench/editor/results-<engine>.json] [--date YYYY-MM-DD]
//        [--check 333x250] [--slow-ms 1500] [--slow-runs 3]
//
// Per engine: first the bytes check (every operation on a small image, Lean's checksum against
// JS's: MATCH/DIFF), then per size (1 MP = 1152x864, 4 MP = 2304x1728, 12 MP = 4000x3000) the
// image made in Lean and in JS, and per operation one warm-up and `runs` interleaved timed runs.
// A warm-up slower than --slow-ms cuts that operation to --slow-runs runs at that size (reported).
// Lean's time is the synchronous `input` event carrying `run OP` (update, view and diff in wasm,
// then the tiny DOM patch); JS's the call; the canvas built-in's the draw plus getImageData of the
// whole result. Writes the raw timings as JSON and prints markdown tables.
//
// The browser: Playwright's own build for each engine, else $LEANUI_CHROMIUM / $LEANUI_FIREFOX,
// else $PLAYWRIGHT_BROWSERS_PATH/<engine> (a pre-installed browser of another revision).
import { pw } from "./playwright.mjs";
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const SIZES = { 1: [1152, 864], 4: [2304, 1728], 12: [4000, 3000] };

// ---- arguments ----
const args = process.argv.slice(2);
const opt = (name, dflt) => { const i = args.indexOf("--" + name); if (i < 0) return dflt; const v = args[i + 1]; args.splice(i, 2); return v; };
const sizes = opt("sizes", "1,4,12").split(",").map((s) => {
  if (SIZES[s]) return { label: `${s} MP`, w: SIZES[s][0], h: SIZES[s][1] };
  const m = /^(\d+)x(\d+)$/.exec(s);
  if (!m) throw new Error(`size ${s}: 1, 4, 12 or WxH`);
  return { label: s, w: +m[1], h: +m[2] };
});
const runs = +opt("runs", "5");
const outPattern = opt("out", "bench/editor/results-<engine>.json");
const date = opt("date", undefined);
const [cw, ch] = opt("check", "333x250").split("x").map(Number);
const slowMs = +opt("slow-ms", "1500");
const slowRuns = +opt("slow-runs", "3");
const base = (args.find((a) => /^https?:/.test(a)) || "http://127.0.0.1:5341/").replace(/\/?$/, "/");
const engines = args.filter((a) => !/^https?:/.test(a));
if (engines.length === 0) engines.push("chromium");

// ---- the bytes check in Node: ops.js against the goldens of tests/Editor.lean ----
let goldens;
try {
  goldens = execFileSync(process.execPath, [path.join(repo, "bench/editor/check-goldens.mjs")], { encoding: "utf8" }).trim();
} catch (e) { goldens = "FAILED: " + (e.stdout || e.message).trim(); }
console.log(`ops.js against tests/Editor.lean's goldens (Node): ${goldens}\n`);

function executable(engine) {
  const env = process.env[`LEANUI_${engine.toUpperCase()}`];
  if (env) return env;
  if (fs.existsSync(pw[engine].executablePath())) return undefined;
  const alt = process.env.PLAYWRIGHT_BROWSERS_PATH && path.join(process.env.PLAYWRIGHT_BROWSERS_PATH, engine);
  return alt && fs.existsSync(alt) ? alt : undefined;
}

const median = (xs) => { const s = [...xs].sort((a, b) => a - b), n = s.length; return n === 0 ? NaN : n % 2 ? s[n >> 1] : (s[n / 2 - 1] + s[n / 2]) / 2; };
const min = (xs) => Math.min(...xs);
const ms = (v) => (v == null || !isFinite(v) ? "–" : v >= 100 ? v.toFixed(0) : v >= 10 ? v.toFixed(1) : v.toFixed(2));
const mps = (px, t) => (t == null || !isFinite(t) || t <= 0 ? "–" : (px / 1e6 / (t / 1000)).toFixed(px / 1e6 / (t / 1000) >= 100 ? 0 : 1));
const ratio = (a, b) => (a == null || b == null || !isFinite(a) || !isFinite(b) || b <= 0 ? "–" : (a / b).toFixed(2) + "×");
const mb = (b) => (b == null ? "?" : (b / 1048576).toFixed(0) + " MB");

let commit = null;
try { commit = execFileSync("git", ["-C", repo, "rev-parse", "--short", "HEAD"], { encoding: "utf8" }).trim(); } catch (e) {}

for (const engine of engines) {
  const t0 = Date.now();
  let browser;
  try {
    browser = await pw[engine].launch({ headless: true, executablePath: executable(engine) });
  } catch (e) {
    console.log(`## ${engine}: not available (${e.message.split("\n")[0]}); skipped\n`);
    continue;
  }
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push("pageerror: " + e.message));
  page.on("console", (m) => { if (m.type() === "error" && !m.text().startsWith("Failed to load resource")) errors.push("console: " + m.text()); });
  page.on("response", (r) => { if (r.status() >= 400 && !r.url().endsWith("/favicon.ico")) errors.push(`HTTP ${r.status()}: ${r.url()}`); });
  await page.goto(base + "editor-bench/index.html");
  await page.waitForFunction(() => window.__leanui, null, { timeout: 60000 });
  await page.addScriptTag({ path: path.join(repo, "bench/editor/ops.js") });
  await page.addScriptTag({ path: path.join(repo, "bench/editor/page.js") });
  const env = await page.evaluate(() => ({ userAgent: navigator.userAgent, gpu: EditorBenchPage.gpuInfo(),
    crossOriginIsolated: self.crossOriginIsolated, hardwareConcurrency: navigator.hardwareConcurrency, ops: EditorOps.OPS }));
  // Chromium says whether the 2D canvas is accelerated in chrome://gpu ("Canvas: Software only, …")
  let canvasStatus = null;
  if (engine === "chromium") {
    try {
      const g = await browser.newPage();
      await g.goto("chrome://gpu");
      await g.waitForTimeout(1500);
      const t = await g.evaluate(() => { const h = document.querySelector("info-view"); return (h && h.shadowRoot ? h.shadowRoot : document).textContent; });
      canvasStatus = (/Canvas:\s*([^*\n]+)/.exec(t) || [])[1]?.trim() || null;
      await g.close();
    } catch (e) {}
  }
  const result = { engine, browserVersion: browser.version(), userAgent: env.userAgent, gpu: env.gpu, canvasStatus, date, commit,
    runs, slowMs, slowRuns, timerNote: env.crossOriginIsolated ? "cross-origin isolated" : "performance.now() coarsened (not cross-origin isolated)",
    goldens, check: null, sizes: [] };

  // ---- bytes: Lean against JS on a small image ----
  result.check = { w: cw, h: ch, rows: await page.evaluate(([w, h]) => EditorBenchPage.verify(w, h), [cw, ch]) };

  // ---- timings ----
  for (const s of sizes) {
    const ts = Date.now();
    const made = await page.evaluate(([w, h]) => EditorBenchPage.setup(w, h), [s.w, s.h]);
    const size = { label: s.label, w: s.w, h: s.h, pixels: s.w * s.h, leanMakeMs: made.leanMakeMs, jsMakeMs: made.jsMakeMs, ops: [] };
    for (const op of env.ops) {
      size.ops.push(await page.evaluate(([op, runs, slowMs, slowRuns]) => EditorBenchPage.timeOp(op, runs, slowMs, slowRuns), [op, runs, slowMs, slowRuns]));
    }
    size.blit = await page.evaluate((runs) => EditorBenchPage.timeBlit(runs), runs);
    size.readback = await page.evaluate((runs) => EditorBenchPage.timeReadback(runs), runs);
    size.wasm = await page.evaluate(() => EditorBenchPage.wasmBytes());
    size.seconds = (Date.now() - ts) / 1000;
    result.sizes.push(size);
    console.error(`${engine} ${s.label}: ${size.seconds.toFixed(0)} s`);
  }
  result.errors = errors;
  result.seconds = (Date.now() - t0) / 1000;
  await browser.close();

  if (outPattern) {
    const out = path.resolve(repo, outPattern.replace("<engine>", engine));
    fs.mkdirSync(path.dirname(out), { recursive: true });
    fs.writeFileSync(out, JSON.stringify(result, null, 1) + "\n");
    result.file = out.startsWith(repo + path.sep) ? path.relative(repo, out) : out;
  }
  printMarkdown(result);
}

function printMarkdown(r) {
  const L = [];
  L.push(`## ${r.engine} ${r.browserVersion}${r.date ? `, ${r.date}` : ""}${r.commit ? `, commit ${r.commit}` : ""}`, "");
  L.push(`${r.userAgent}; 2D canvas: ${r.canvasStatus || "?"} (WebGL renderer: ${r.gpu}); ${r.timerNote}; ${r.seconds.toFixed(0)} s in all.`, "");
  L.push(`### Bytes: Lean (wasm) against JS on a ${r.check.w}×${r.check.h} test image`, "");
  L.push("| operation | compared | Lean | JS | Lean = JS | canvas built-in = JS |", "|---|---|---|---|---|---|");
  for (const c of r.check.rows) {
    L.push(`| ${c.op} | ${c.kind} | ${c.lean} | ${c.js} | ${c.match ? "MATCH" : "**DIFF**"} | ${c.canvasSame == null ? "–" : c.canvasSame ? "same pixels" : "differs"} |`);
  }
  L.push("", `ops.js against tests/Editor.lean's goldens (Node): ${r.goldens}`, "");
  for (const s of r.sizes) {
    const px = s.pixels;
    L.push(`### ${s.label} (${s.w}×${s.h}): median of ${r.runs} runs (min)`, "");
    L.push("| operation | Lean | JS | canvas built-in | Lean MPix/s | JS MPix/s | canvas MPix/s | Lean ÷ JS | Lean ÷ canvas |",
      "|---|--:|--:|--:|--:|--:|--:|--:|--:|");
    let reduced = false;
    for (const o of s.ops) {
      const lm = median(o.lean), jm = median(o.js), cm = o.canvas ? median(o.canvas) : null;
      const mark = o.reduced ? " †" : "";
      reduced ||= o.reduced;
      L.push(`| ${o.op}${mark} | ${ms(lm)} ms (${ms(min(o.lean))}) | ${ms(jm)} ms (${ms(min(o.js))}) | ` +
        (o.canvas ? `${ms(cm)} ms (${ms(min(o.canvas))})` : "–") +
        ` | ${mps(px, lm)} | ${mps(px, jm)} | ${o.canvas ? mps(px, cm) : "–"} | **${ratio(lm, jm)}** | ${o.canvas ? ratio(lm, cm) : "–"} |`);
    }
    const b = s.blit, blm = median(b.lean), bjm = median(b.js);
    L.push(`| blit (putImageData ${s.w}×${s.h}) | ${ms(blm)} ms (${ms(min(b.lean))}) | ${ms(bjm)} ms (${ms(min(b.js))}) | – | ${mps(px, blm)} | ${mps(px, bjm)} | – | **${ratio(blm, bjm)}** | – |`);
    L.push("");
    if (reduced) L.push(`† warm-up over ${r.slowMs} ms: ${r.slowRuns} runs instead of ${r.runs}.`, "");
    const forced = s.ops.filter((o) => o.canvasForced);
    L.push(`Canvas without the full readback (draw, then a 1-pixel getImageData to force it), median ms: ` +
      forced.map((o) => `${o.op} ${ms(median(o.canvasForced))}`).join(", ") +
      `. Draw call alone (as issued): ` + forced.map((o) => `${o.op} ${ms(median(o.canvasDraw))}`).join(", ") +
      `. getImageData of the whole ${s.w}×${s.h} canvas alone: ${ms(median(s.readback))} ms.`, "");
    const png = s.ops.find((o) => o.op === "png-1");
    const pngStored = s.ops.find((o) => o.op === "png-stored");
    L.push(`Made in ${ms(s.leanMakeMs)} ms (Lean) and ${ms(s.jsMakeMs)} ms (JS). PNG sizes: stored ${pngStored?.jsN} bytes, level 1 ${png?.jsN} bytes` +
      (png?.canvasBlobBytes ? ` (toBlob: ${png.canvasBlobBytes} bytes)` : "") +
      `. Wasm memory after this size: ${mb(s.wasm.statsHeapBytes)} (\`__leanui.stats.heapBytes\`; the Memory's buffer: ${mb(s.wasm.memoryBytes)}). ${s.seconds.toFixed(0)} s.`, "");
  }
  const descs = r.sizes[0]?.ops.filter((o) => o.canvasDesc) || [];
  if (descs.length) {
    L.push("Canvas built-ins (not the same algorithms; drawn from an ImageBitmap of the image, timed with getImageData of the whole result):", "");
    for (const o of descs) L.push(`- ${o.op}: ${o.canvasDesc}`);
    L.push("");
  }
  if (r.errors.length) L.push("Page errors:", "", ...r.errors.map((e) => "- " + e), "");
  if (r.file) L.push(`Raw timings: \`${r.file}\`.`, "");
  console.log(L.join("\n"));
}
