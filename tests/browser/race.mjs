// The race page (bench/race/, assembled into dist/race by bench/race/build.sh) as a test: the same
// app in each of the race's lanes (bench/race/lanes.mjs; by default plain JavaScript, Lean compiled
// to wasm64 and Lean interpreted by lean-vir) must end in the same state. Life: 100 clicks on Step
// in each, and each must show generation 100, 53 alive and board bdbe4aa6, what tests/Kit.lean
// computes natively. Table: the keyed operations once each, the tables equal after every one. A
// lane that reports its own figures (window.__lane) must have had no stalls; the QED64 lane
// (qed64/README.md) must also have fetched lean.wasm and its snapshot itself, in its Worker.
// --perf: Life with 1,000 clicks and the table with 3 runs per operation; --out writes the page's
// results (window.__race) as JSON; --lanes picks the lanes (the page's ?lanes=; without it, the
// page's own choice, which must be the three). The QED64 lane needs a cross-origin isolated server
// (`leanui serve dist --coop`).
//   node tests/browser/race.mjs <url serving dist/> [chromium|firefox] [--perf] [--lanes a,b,…] [--out file.json]
//   (under the host browser lock)
// Without --perf the table runs in Chromium only (about a minute, and half a minute more with
// QED64): in Playwright's Firefox, where lean-vir is slowest, it takes three; Life takes 6 s in
// Chromium, 25 s in Firefox (QED64 adds about 10 s and 25 s).
import { pw } from "./playwright.mjs";
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { LANES } from "../../bench/race/lanes.mjs";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const args = process.argv.slice(2);
const base = (args.find((a) => /^https?:/.test(a)) || "http://127.0.0.1:5331/").replace(/\/?$/, "/");
const engine = args.find((a) => a === "chromium" || a === "firefox") || "chromium";
const perf = args.includes("--perf");
const oi = args.indexOf("--out"), out = oi >= 0 ? args[oi + 1] : null;
const li = args.indexOf("--lanes"), asked = li >= 0 ? args[li + 1] : null;
// examples/Life.lean natively (tests/Kit.lean): live cells and board hash after N generations
const LIFE = { 100: { pop: 53, board: "bdbe4aa6" }, 1000: { pop: 145, board: "4e6b3290" } };
// the lanes that must run, in the page's (lanes.mjs's) order
const KEYS = LANES.filter((l) => (asked ?? "vanilla,wasm64,vir").split(",").includes(l.key)).map((l) => l.key).join();
const unknown = (asked ?? "").split(",").filter((k) => k && !LANES.some((l) => l.key === k));
if (unknown.length || !KEYS) { console.error(`--lanes: no lane ${unknown.join(", ")} (bench/race/lanes.mjs has ${LANES.map((l) => l.key).join(", ")})`); process.exit(2); }
const lanes = KEYS.split(",").map((k) => LANES.find((l) => l.key === k));

const browser = await pw[engine].launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });
const errors = [], checks = [];
page.on("pageerror", (e) => errors.push("pageerror: " + e.message));
page.on("console", (m) => { if (m.type() === "error") errors.push("console: " + m.text()); });
const check = (name, ok, detail = "") => { checks.push({ name, ok: !!ok, detail: ok ? undefined : detail }); };
const ms = (v) => (v == null || !isFinite(v) ? "–" : v >= 100 ? v.toFixed(0) : v >= 10 ? v.toFixed(1) : v.toFixed(2));

// Run a scenario on the race page and return its window.__race (polled once a second, so the
// test's own work stays out of the clicks it times).
let raced = false;
async function race(query) {
  // the panels of a lane whose page's threads outlive it (lanes.mjs: unloadMs) are emptied, and
  // the next race page loads once those threads are gone, as the page itself does between loads
  const unload = Math.max(0, ...lanes.map((l) => l.unloadMs || 0));
  if (raced && unload) {
    await page.evaluate(() => { for (const f of document.querySelectorAll("iframe")) f.src = "about:blank"; });
    await new Promise((r) => setTimeout(r, unload));
  }
  raced = true;
  const t0 = Date.now();
  await page.goto(`${base}race/?${query}${asked ? "&lanes=" + KEYS : ""}&auto=1`);
  // and the time the lanes may take to start, beyond the usual minute (lanes.mjs: bootTimeoutMs)
  const boot = lanes.reduce((a, l) => a + Math.max(0, (l.bootTimeoutMs ?? 60e3) - 60e3), 0);
  await page.waitForFunction(() => window.__race, null, { timeout: (perf ? 60 : 10) * 60e3 + boot, polling: 1000 });
  return { ...(await page.evaluate(() => window.__race)), seconds: (Date.now() - t0) / 1000 };
}

async function life(steps) {
  const r = await race(`scenario=life&steps=${steps}`);
  const want = LIFE[steps];
  check(`life ${steps}: every lane ran (${KEYS})`, r.rows?.map((x) => x.key).join() === KEYS, r.error ?? JSON.stringify(r.rows));
  check(`life ${steps}: same board`, r.same && r.steps === steps, JSON.stringify(r));
  for (const x of r.rows ?? [])
    check(`life ${steps}: ${x.key} = native`, x.clicks === steps && x.gen === steps && x.pop === want.pop && x.board === want.board,
      `${x.clicks} clicks, generation ${x.gen}, alive ${x.pop}, board ${x.board}; want ${steps}, ${want.pop}, ${want.board}`);
  console.log(`life, ${steps} clicks (${r.seconds.toFixed(0)} s): script time, per click, what the app shows`);
  const w = Math.max(20, ...lanes.map((l) => l.name.length));
  for (const x of r.rows ?? [])
    console.log(`  ${x.name.padEnd(w)} ${ms(x.ms).padStart(8)} ms ${ms(x.ms / x.clicks).padStart(7)} ms  generation ${x.gen}, alive ${x.pop}, board ${x.board}`);
  own(r, `life ${steps}`);
  return r;
}

async function table(runs) {
  const r = await race(`scenario=table&runs=${runs}`);
  check(`table: every lane ran every operation (${KEYS})`, r.rows?.length > 0 && r.rows.every((x) => Object.keys(x.sig).join() === KEYS), r.error ?? JSON.stringify(r.rows));
  check(`table: same rows after every operation`, r.same && r.runs === runs, (r.rows ?? []).filter((x) => !x.same).map((x) => x.op).join(", "));
  console.log(`table, median of ${runs} run${runs > 1 ? "s" : ""} (${r.seconds.toFixed(0)} s): ms, ${lanes.map((l) => l.short).join(" / ")}`);
  for (const x of r.rows ?? [])
    console.log(`  ${x.desc.padEnd(32)}${lanes.map((l) => " " + ms(x.ms[l.key]).padStart(Math.max(7, l.short.length))).join("")}  ${x.same ? "same" : "DIFFERENT"}`);
  own(r, "table");
  return r;
}

// What a lane said of itself (window.__lane: bench/race/lanes.mjs): no stalls, and the split of
// its time per operation (the app's own, the transport's, the DOM's). The QED64 lane's Worker
// downloads lean.wasm (11 MB with brotli) and the snapshot (31 MB) itself.
function own(r, what) {
  if (KEYS.split(",").includes("qed64"))
    check(`${what}: qed64's Worker fetched lean.wasm and the snapshot`, r.lanes?.qed64?.bytes > 30e6, `${r.lanes?.qed64?.bytes} bytes`);
  for (const [key, x] of Object.entries(r.lanes ?? {})) {
    check(`${what}: ${key} had no stalls`, x.stalls === 0, `${x.stalls} stalls`);
    console.log(`  ${key}: started in ${ms(x.boot)} ms${x.phases ? " (" + Object.entries(x.phases).map(([k, v]) => `${k} ${ms(v)}`).join(", ") + ")" : ""}, ` +
      `${((x.bytes ?? 0) / 1e6).toFixed(1)} MB fetched by itself, floor ${ms(x.floorMs)} ms; per click, ms: Lean / transport / DOM`);
    for (const [op, s] of Object.entries(x.perOp ?? {}))
      console.log(`    ${op.padEnd(12)} ${ms(s.totalMs).padStart(8)} = ${ms(s.leanMs).padStart(7)} ${ms(s.totalMs - s.leanMs - s.applyMs).padStart(7)} ${ms(s.applyMs).padStart(7)}`);
  }
}

const result = { engine, browserVersion: browser.version(), date: new Date().toISOString(), commit: null };
try { result.commit = execFileSync("git", ["-C", repo, "rev-parse", "--short", "HEAD"], { encoding: "utf8" }).trim(); } catch (e) {}
if (perf) {
  result.life = await life(1000);
  result.table = await table(3);
} else {
  result.life = await life(100);
  if (engine === "chromium") result.table = await table(1);
}
result.checks = checks; result.errors = errors;
await browser.close();
if (out) {
  fs.mkdirSync(path.dirname(path.resolve(out)), { recursive: true });
  fs.writeFileSync(out, JSON.stringify(result, null, 1) + "\n");
}
for (const c of checks.filter((c) => !c.ok)) console.log(`FAIL ${c.name}: ${c.detail}`);
for (const e of errors) console.log(e);
const ok = checks.every((c) => c.ok) && errors.length === 0;
console.log(ok ? "PASS" : "FAIL");
process.exit(ok ? 0 : 1);
