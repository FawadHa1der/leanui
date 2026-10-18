// What applying a command buffer costs the JavaScript runtime, without Lean in the way.
//
//   node tests/browser/apply-bench.mjs [--app dist/bench] [--variants a.js,b.js] [--reps 25]
//        [--mode fresh|hot] [--engines chromium,firefox] [--only create1k,clear1k] [--profile]
//        [--json out.json]
//
// 1. Record: the benchmark app (<app>, a wasm build) runs in Chromium; every buffer it flushes is
//    copied (LeanUI.__flush is wrapped), from boot through the operation's warm-up clicks to the
//    measured click (the operations and warm-ups of bench/ops.mjs, as tests/browser/bench.mjs).
// 2. Replay, in a page with the benchmark's stylesheet and container, of each runtime variant
//    (default: runtime/leanui.js against <app>/leanui.js; put the reference first, the report
//    divides by it). Each sample applies the recorded prefix to a fresh container and runtime,
//    forcing a layout after every buffer (as the frame after a real click would), then times
//    `Runtime.apply` on the measured buffer ("apply") and the forced layout after it ("layout").
//    --mode fresh (default): every sample is a new page holding one variant, so the engine's JIT
//      has seen exactly what it sees in the benchmark (boot and warm-ups) before the measured
//      buffer; variants take turns in a different order every repetition.
//    --mode hot: one page holds every variant and runs all samples, a full GC before each
//      sample's prefix: the steady state once the JIT has optimized everything.
//    No wasm runs during the replay, so Playwright's Firefox is fine here.
// 3. Per opcode: the measured buffer's command counts, and with --profile a sampled CPU profile
//    of the measured applies only (hot mode), by function: the DOM natives each opcode calls and
//    the runtime's own JavaScript (Chromium: the V8 profiler, with the runtime's time per source
//    line; Firefox: the Gecko profiler, one browser per variant, by the innermost named frame:
//    a DOM-binding label such as "Node.appendChild", or the runtime's own function).
// Timing needs fine timers: the pages are cross-origin isolated (5 µs in Chromium), and
// Firefox's timer rounding is turned off. Run it under the host browser lock.
import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { OPS as BENCH_OPS } from "../../bench/ops.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const require = createRequire(process.env.LEANUI_PLAYWRIGHT_FROM || "/Users/fawadhaider/code/wasm64-lean-fable/qed64/package.json");
const pw = require("playwright");
const argv = process.argv.slice(2);
const opt = (n, d) => { const i = argv.indexOf("--" + n); return i >= 0 ? argv[i + 1] : d; };
const APP = path.resolve(ROOT, opt("app", "dist/bench"));
const VARIANTS = opt("variants", `runtime/leanui.js,${path.relative(ROOT, APP)}/leanui.js`).split(",");
const REPS = +opt("reps", "25");
const MODE = opt("mode", "fresh");
const ENGINES = opt("engines", "chromium").split(",");
const ONLY = opt("only", "create1k,replace1k,append1k,clear1k,create10k");
const PROFILE = argv.includes("--profile");
const JSON_OUT = opt("json", null);
// extra V8 flags for the replay browser (Chromium)
const JS_FLAGS = opt("js-flags", "");
// skip the DOM checks after each sample (for probe variants that deliberately differ)
const UNCHECKED = argv.includes("--unchecked");
if (!["fresh", "hot"].includes(MODE)) throw new Error("--mode fresh|hot");
const OPS = BENCH_OPS.filter((o) => ONLY === "all" || ONLY.split(",").includes(o.name));

// ---------- the server: the app (recording), the replay pages, the recordings, the variants ----------
const names = VARIANTS.map((v, i) => `${i}:${path.basename(path.dirname(v))}/${path.basename(v)}`);
// each variant's runtime defines window.__variants[i] instead of globalThis.LeanUI
const sources = VARIANTS.map((v, i) => {
  const src = fs.readFileSync(path.resolve(ROOT, v), "utf8"), tail = "})(globalThis);", k = src.lastIndexOf(tail);
  if (k < 0) throw new Error("unexpected runtime shape (no IIFE tail): " + v);
  return `(window.__variants = window.__variants || {})[${i}] = {};\n` + src.slice(0, k) + `})(window.__variants[${i}]);\n`;
});
const recordings = new Map();   // op name -> JSON text
const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".wasm": "application/wasm", ".css": "text/css", ".json": "application/json" };
const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://x"), u = decodeURIComponent(url.pathname);
  // cross-origin isolated, so performance.now() has fine resolution
  const head = { "cross-origin-opener-policy": "same-origin", "cross-origin-embedder-policy": "require-corp", "cache-control": "no-store" };
  const send = (type, body) => { res.writeHead(200, { ...head, "content-type": type }); res.end(body); };
  if (u === "/replay.html") {
    const vs = (url.searchParams.get("v") || "").split(",").filter(Boolean);
    return send(TYPES[".html"], '<!doctype html><html><head><meta charset="utf-8"><link rel="stylesheet" href="/bench.css"></head><body><div id="app"></div>' +
      vs.map((i) => `<script src="/variant/${i}.js"></script>`).join("") + "</body></html>");
  }
  let m;
  if ((m = /^\/variant\/(\d+)\.js$/.exec(u)) && sources[+m[1]]) return send(TYPES[".js"], sources[+m[1]]);
  if ((m = /^\/rec\/(\w+)\.json$/.exec(u)) && recordings.has(m[1])) return send(TYPES[".json"], recordings.get(m[1]));
  const file = u === "/bench.css" ? path.join(ROOT, "bench/bench.css") : path.join(APP, u.slice(1) || "index.html");
  if (!file.startsWith(ROOT) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) { res.writeHead(404); res.end(); return; }
  send(TYPES[path.extname(file)] || "application/octet-stream", fs.readFileSync(file));
});
await new Promise((ok) => server.listen(0, "127.0.0.1", ok));
const BASE = `http://127.0.0.1:${server.address().port}`;

// ---------- 1. record (Chromium, the real wasm app) ----------
async function record(browser, op) {
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.addInitScript(() => {
    const rec = (window.__rec = []);
    let L;
    Object.defineProperty(window, "LeanUI", { configurable: true, get: () => L, set(v) {
      L = v;
      const flush = v.__flush;
      v.__flush = function (heap, ops, opsLen, strs, strsLen) {
        const b = new Uint8Array(opsLen + strsLen);
        b.set(heap.subarray(ops, ops + opsLen), 0); b.set(heap.subarray(strs, strs + strsLen), opsLen);
        let bin = ""; for (let i = 0; i < b.length; i += 8192) bin += String.fromCharCode.apply(null, b.subarray(i, i + 8192));
        rec.push({ opsLen, b64: btoa(bin) });
        return flush.call(this, heap, ops, opsLen, strs, strsLen);
      };
    } });
  });
  await page.goto(BASE + "/index.html");
  await page.waitForFunction(() => window.__ready, null, { timeout: 30000 });
  const click = (s) => page.evaluate((s) => { const e = document.querySelector(s); if (!e) throw new Error("no " + s); e.click(); }, s);
  for (const sel of op.warm) await click(sel);
  const before = await page.evaluate(() => window.__rec.length);
  await click(op.click);
  const bufs = await page.evaluate(() => window.__rec);
  const check = await page.$eval("#tbody", (t) => t.children.length + "|" + t.textContent.length);
  await page.close();
  if (errors.length) throw new Error(op.name + ": " + errors.join("; "));
  if (bufs.length !== before + 1) throw new Error(`${op.name}: the measured click flushed ${bufs.length - before} buffers`);
  return { name: op.name, prefix: bufs.slice(0, -1), measured: bufs[bufs.length - 1], check };
}

// per-opcode command counts of a buffer
const OPERANDS = { 1: 3, 2: 3, 3: 4, 4: 2, 5: 4, 6: 3, 7: 4, 8: 2, 9: 3, 10: 2, 11: 3, 12: 1, 13: 2, 14: 1, 15: 5, 16: 2, 17: 3, 18: 3, 19: 4 };
const NAMES = { 1: "CREATE_ELEMENT", 2: "CREATE_TEXT", 3: "SET_ATTR", 4: "REMOVE_ATTR", 5: "SET_PROP_STR", 6: "SET_PROP_BOOL", 7: "SET_PROP_NUM", 8: "REMOVE_PROP", 9: "SET_TEXT", 10: "APPEND_CHILD", 11: "INSERT_BEFORE", 12: "REMOVE", 13: "REPLACE", 14: "FREE", 15: "SET_LISTENER", 16: "REMOVE_LISTENER", 17: "INTERN", 18: "MOUNT", 19: "HYDRATE" };
function opcodeCounts(buf) {
  const b = Buffer.from(buf.b64, "base64");
  const w = new Uint32Array(b.buffer.slice(b.byteOffset, b.byteOffset + buf.opsLen));
  const counts = {};
  for (let i = 0; i < w.length; ) {
    const op = w[i];
    if (!(op in OPERANDS)) throw new Error("opcode " + op + " (the recorder knows DOM commands only)");
    counts[NAMES[op]] = (counts[NAMES[op]] || 0) + 1;
    i += 1 + OPERANDS[op];
  }
  return { words: w.length, strBytes: b.length - buf.opsLen, counts };
}

// ---------- 2. replay (in the page) ----------
// `samples` runs, each over the variants `vs` (indices) in a seeded order; returns per variant
// the apply and layout times. `gc`: a full GC before each sample's prefix (hot mode).
async function replay({ op, vs, samples, gc, unchecked, seed0 }) {
  const rec = await (await fetch(`/rec/${op}.json`)).json();
  const dec = (r) => { const bin = atob(r.b64); const u = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i); return { u, opsLen: r.opsLen }; };
  const prefix = rec.prefix.map(dec), measured = dec(rec.measured);
  const transport = { event() {}, callback() {} };
  // the timed call, named so a profile can keep only the samples under it
  const measure = function __measured(rt, m) { rt.apply(m.u, 0, m.opsLen, m.opsLen, m.u.length - m.opsLen); };
  const out = Object.fromEntries(vs.map((v) => [v, { apply: [], layout: [], html: null }]));
  for (let s = 0; s < samples; s++) {
    const order = vs.slice();
    let seed = (seed0 + s) * 2654435761 + 1;
    for (let k = order.length - 1; k > 0; k--) { seed = (seed * 1103515245 + 12345) >>> 0; const j = seed % (k + 1); [order[k], order[j]] = [order[j], order[k]]; }
    for (const v of order) {
      document.body.innerHTML = '<div id="app"></div>';
      if (gc && window.gc) window.gc();
      const rt = new window.__variants[v].LeanUI.Runtime(transport);
      for (const b of prefix) { rt.apply(b.u, 0, b.opsLen, b.opsLen, b.u.length - b.opsLen); document.body.offsetHeight; }
      const t0 = performance.now();
      measure(rt, measured);
      const t1 = performance.now();
      document.body.offsetHeight;
      const t2 = performance.now();
      out[v].apply.push(t1 - t0); out[v].layout.push(t2 - t1);
      if (unchecked) continue;
      const t = document.getElementById("tbody");
      const got = t.children.length + "|" + t.textContent.length;
      if (got !== rec.check) throw new Error(`variant ${v} ${op}: tbody ${got}, recorded ${rec.check}`);
      if (out[v].html === null) out[v].html = document.getElementById("app").innerHTML;
    }
  }
  return out;
}

const median = (a) => { const s = a.slice().sort((x, y) => x - y); return s[s.length >> 1]; };
const q1 = (a) => { const s = a.slice().sort((x, y) => x - y); return s[s.length >> 2]; };
const r3 = (x) => Math.round(x * 1000) / 1000;
const shuffled = (xs, seed) => { const o = xs.slice(); for (let k = o.length - 1; k > 0; k--) { seed = (seed * 1103515245 + 12345) >>> 0; const j = seed % (k + 1); [o[k], o[j]] = [o[j], o[k]]; } return o; };

const rb = await pw.chromium.launch({ headless: true });
const results = { app: path.relative(ROOT, APP), variants: VARIANTS, reps: REPS, mode: MODE, ops: {}, engines: {} };
for (const op of OPS) {
  const r = await record(rb, op);
  recordings.set(op.name, JSON.stringify(r));
  results.ops[op.name] = { prefixBuffers: r.prefix.length, ...opcodeCounts(r.measured) };
}
await rb.close();

const vIdx = VARIANTS.map((_, i) => i);
for (const engine of ENGINES) {
  const launch = (extra = {}) => pw[engine].launch({ headless: true, args: engine === "chromium" ? [`--js-flags=--expose-gc ${JS_FLAGS}`] : [],
    firefoxUserPrefs: engine === "firefox" ? { "privacy.reduceTimerPrecision": false } : undefined, ...extra });
  const browser = await launch();
  const E = (results.engines[engine] = { version: browser.version(), ops: {}, profiles: {} });
  const newPage = async (vs) => {
    const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    await page.goto(`${BASE}/replay.html?v=${vs.join(",")}`);
    if (!(await page.evaluate(() => crossOriginIsolated))) throw new Error("the replay page is not cross-origin isolated");
    return page;
  };
  for (const op of OPS) {
    const res = Object.fromEntries(vIdx.map((v) => [v, { apply: [], layout: [], html: null }]));
    const merge = (r) => { for (const v of Object.keys(r)) { res[v].apply.push(...r[v].apply); res[v].layout.push(...r[v].layout); res[v].html ??= r[v].html; } };
    if (MODE === "fresh") {
      for (let s = 0; s < REPS; s++) for (const v of shuffled(vIdx, s * 7919 + 17)) {
        const page = await newPage([v]);
        merge(await page.evaluate(replay, { op: op.name, vs: [v], samples: 1, gc: false, unchecked: UNCHECKED, seed0: s }));
        await page.close();
      }
    } else {
      const page = await newPage(vIdx);
      await page.evaluate(replay, { op: op.name, vs: vIdx, samples: 2, gc: true, unchecked: UNCHECKED, seed0: 1000 });   // warm-up, untimed
      merge(await page.evaluate(replay, { op: op.name, vs: vIdx, samples: REPS, gc: true, unchecked: UNCHECKED, seed0: 0 }));
      if (PROFILE && engine === "chromium") {
        // each variant alone, so self times can be attributed
        const cdp = await page.context().newCDPSession(page);
        await cdp.send("Profiler.enable");
        await cdp.send("Profiler.setSamplingInterval", { interval: 25 });
        for (const v of vIdx) {
          await cdp.send("Profiler.start");
          await page.evaluate(replay, { op: op.name, vs: [v], samples: Math.max(5, REPS >> 1), gc: true, unchecked: UNCHECKED, seed0: 0 });
          E.profiles[`${op.name} ${names[v]}`] = summariseV8((await cdp.send("Profiler.stop")).profile);
        }
        await cdp.detach();
      }
      await page.close();
    }
    if (PROFILE && engine === "firefox") for (const v of vIdx) E.profiles[`${op.name} ${names[v]}`] = await geckoProfile(op, v);
    // every variant must build the same DOM
    if (!UNCHECKED) for (const v of vIdx) if (res[v].html !== res[0].html) throw new Error(`${names[v]} ${op.name}: the DOM differs from ${names[0]}'s`);
    E.ops[op.name] = Object.fromEntries(vIdx.map((v) => [names[v], { apply: r3(median(res[v].apply)), applyQ1: r3(q1(res[v].apply)), applyMin: r3(Math.min(...res[v].apply)), layout: r3(median(res[v].layout)) }]));
    process.stderr.write(`${engine} ${op.name.padEnd(10)} ${names.map((n) => `${n} ${E.ops[op.name][n].apply.toFixed(3)}`).join(" | ")}\n`);
  }
  await browser.close();

  // Firefox: the Gecko profiler records from startup to shutdown, so each profile is a browser of
  // its own running one variant's samples (hot). Samples count only under the `__measured` frame,
  // by their innermost named frame (DOM bindings label themselves, e.g. "Node.appendChild").
  async function geckoProfile(op, v) {
    const dump = path.join(os.tmpdir(), `leanui-apply-${process.pid}.json`);
    try { fs.rmSync(dump); } catch (e) {}
    const env = { ...process.env, MOZ_PROFILER_STARTUP: "1", MOZ_PROFILER_STARTUP_INTERVAL: "0.05", MOZ_PROFILER_STARTUP_FEATURES: "js,cpu",
      MOZ_PROFILER_STARTUP_ENTRIES: "16777216", MOZ_PROFILER_SHUTDOWN: dump };
    const b = await launch({ env });
    const page = await b.newPage({ viewport: { width: 1280, height: 900 } });
    await page.goto(`${BASE}/replay.html?v=${v}`);
    await page.evaluate(replay, { op: op.name, vs: [v], samples: 2 + Math.max(5, REPS >> 1), gc: false, unchecked: UNCHECKED, seed0: 0 });
    await b.close();
    for (let i = 0; i < 50 && !fs.existsSync(dump); i++) await new Promise((r) => setTimeout(r, 100));
    await new Promise((r) => setTimeout(r, 500));
    const raw = JSON.parse(fs.readFileSync(dump, "utf8"));
    fs.rmSync(dump);
    return summariseGecko(raw);
  }
}
server.close();

function summariseGecko(raw) {
  const self = new Map();
  let total = 0;
  const visit = (proc) => {
    for (const th of proc.threads || []) {
      if (th.name !== "GeckoMain") continue;
      const strs = th.stringTable || th.stringArray || [];
      const S = th.samples, sStack = S.schema.stack, sTime = S.schema.time, data = S.data;
      const st = th.stackTable, ss = st.schema, ft = th.frameTable, fsc = ft.schema;
      const label = (fi) => { const loc = ft.data[fi][fsc.location]; return typeof loc === "number" ? strs[loc] : String(loc); };
      // per stack: under __measured? and its innermost named frame (JIT frames are bare addresses)
      const memo = new Map();
      const info = (si) => {
        if (si === null) return { under: false, name: null };
        if (memo.has(si)) return memo.get(si);
        const row = st.data[si], nm = label(row[ss.frame]), up = info(row[ss.prefix]);
        const named = !/^0x[0-9a-f]+$/.test(nm);
        const v = { under: up.under || /^__measured\b/.test(nm), name: named ? nm : up.name };
        memo.set(si, v);
        return v;
      };
      for (let i = 0; i < data.length; i++) {
        const si = data[i][sStack];
        if (si === null) continue;
        const { under, name } = info(si);
        if (!under) continue;
        const dt = i + 1 < data.length ? data[i + 1][sTime] - data[i][sTime] : 0.05;
        // a sample whose innermost named frame is the runtime itself is the runtime's own code
        let k = (name || "?").replace(/ \(http[^)]*\)/, "").replace(/\[\d+\]$/, "");
        if (/^(__measured|apply)\b/.test(k)) k = "the runtime's own code (" + k + ")";
        self.set(k, (self.get(k) || 0) + dt); total += dt;
      }
    }
    for (const p of proc.processes || []) visit(p);
  };
  visit(raw);
  return { totalMs: r3(total), top: [...self].sort((a, b) => b[1] - a[1]).slice(0, 20).map(([k, ms]) => [k, r3(ms), +(100 * ms / total).toFixed(1)]), lines: [] };
}

// self time per function under the measured apply (samples outside `__measured` are dropped)
function summariseV8(profile) {
  const byId = new Map(profile.nodes.map((n) => [n.id, n]));
  const parent = new Map();
  for (const n of profile.nodes) for (const c of n.children || []) parent.set(c, n.id);
  const memo = new Map();
  const isUnder = (id) => {
    if (memo.has(id)) return memo.get(id);
    const v = byId.get(id).callFrame.functionName === "__measured" || (parent.has(id) && isUnder(parent.get(id)));
    memo.set(id, v);
    return v;
  };
  const self = new Map();
  // time by source line (V8 records ticks per line; a DOM native's line is its call site, and a
  // setter's time counts as its caller's)
  const lines = new Map();
  const tickMs = profile.samples.length ? (profile.endTime - profile.startTime) / 1000 / profile.samples.length : 0;
  for (const n of profile.nodes) {
    // the runtime's frames (served as /variant/<i>.js) and the DOM natives it calls (no url)
    if (!n.positionTicks || !isUnder(n.id) || (n.callFrame.url && !n.callFrame.url.includes("/variant/"))) continue;
    // line - 1: the variant's source is served behind a one-line prefix
    for (const { line, ticks } of n.positionTicks) { const k = `${n.callFrame.functionName || "(anonymous)"}:${line - 1}`; lines.set(k, (lines.get(k) || 0) + ticks * tickMs); }
  }
  let total = 0;
  for (let i = 0; i < profile.samples.length; i++) {
    if (!isUnder(profile.samples[i])) continue;
    const { functionName } = byId.get(profile.samples[i]).callFrame;
    const dt = (profile.timeDeltas[i + 1] ?? profile.timeDeltas[i]) / 1000;
    self.set(functionName || "(anonymous)", (self.get(functionName || "(anonymous)") || 0) + dt);
    total += dt;
  }
  const top = (m, n) => [...m].sort((a, b) => b[1] - a[1]).slice(0, n).map(([k, ms]) => [k, r3(ms), +(100 * ms / total).toFixed(1)]);
  return { totalMs: r3(total), top: top(self, 20), lines: top(lines, 15) };
}

// ---------- report ----------
const out = [];
out.push(`\n## apply-bench: ${results.app}, ${MODE} mode, median of ${REPS} samples\n`);
out.push("| operation | prefix buffers | words | commands in the measured buffer |", "|---|--:|--:|---|");
for (const [op, o] of Object.entries(results.ops)) out.push(`| ${op} | ${o.prefixBuffers} | ${o.words} | ${Object.entries(o.counts).map(([k, v]) => `${k} ${v}`).join(", ")} |`);
for (const [engine, E] of Object.entries(results.engines)) {
  // one row per variant: apply median / lower quartile / minimum, its ratio to variant 0, the layout
  out.push("", `### ${engine} ${E.version}: Runtime.apply in ms (median / lower quartile / minimum), and the forced layout after it`, "");
  const ops = Object.keys(E.ops);
  out.push("| variant | " + ops.map((op) => `${op} apply | ÷ 0 | layout`).join(" | ") + " |", "|---|" + ops.map(() => "--:|--:|--:").join("|") + "|");
  for (const n of names) out.push(`| ${n} | ` + ops.map((op) => { const o = E.ops[op]; return `${o[n].apply.toFixed(3)} / ${o[n].applyQ1.toFixed(3)} / ${o[n].applyMin.toFixed(3)} | ${(o[n].apply / o[names[0]].apply).toFixed(3)} | ${o[n].layout.toFixed(2)}`; }).join(" | ") + " |");
  for (const [k, p] of Object.entries(E.profiles)) {
    out.push("", `profile ${engine} ${k} (${p.totalMs} ms sampled inside the measured apply):`);
    for (const [fn, ms, pct] of p.top) out.push(`  ${ms.toFixed(1).padStart(8)} ms ${pct.toFixed(1).padStart(5)}%  ${fn}`);
    if (p.lines.length) out.push("  by line of the variant's file (function:line):");
    for (const [k2, ms, pct] of p.lines) out.push(`  ${ms.toFixed(1).padStart(8)} ms ${pct.toFixed(1).padStart(5)}%  ${k2}`);
  }
}
console.log(out.join("\n"));
if (JSON_OUT) fs.writeFileSync(JSON_OUT, JSON.stringify(results, null, 1));
