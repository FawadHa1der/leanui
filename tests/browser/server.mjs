// Browser tests for the native LeanUI server (examples/ServerDemo.lean, `leanui serve`).
//   node tests/browser/server.mjs [chromium|firefox|all]      (run under the host browser lock, from the repo root)
// Starts leanui-demo-server on :5351 (dist/counter must hold the wasm build: `leanui build CounterApp counter`)
// and `leanui serve dist/counter --coop` on :5352, and checks, per engine:
//  - server-driven counter: the session adopts the server-rendered nodes, clicks and input work;
//  - SSR + wasm hydration: an expando put on SSR nodes before the wasm boots survives (same nodes), events work;
//  - LeanUI.boot: wasm with Memory64, the server when Memory64 is hidden;
//  - a server-driven ticker: subscriptions (c bodies from setInterval), fetch results, document.title;
//  - pages without JavaScript; static serving: MIME types, HEAD, ETag/304, COOP/COEP, traversal refused;
// and reports the latency of a server-driven round trip (click -> DOM updated) on localhost.
import { createRequire } from "node:module";
import { spawn } from "node:child_process";
import net from "node:net";
import fs from "node:fs";
import path from "node:path";
const require = createRequire("/Users/fawadhaider/code/wasm64-lean-fable/qed64/package.json");
const pw = require("playwright");

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../..");
const DEMO = 5351, STATIC = 5352;
const engines = (process.argv[2] || "all") === "all" ? ["chromium", "firefox"] : [process.argv[2]];
const failures = [];
const report = { engines: {}, static: {} };
const check = (ok, what, extra) => { if (!ok) failures.push(what + (extra !== undefined ? ": " + JSON.stringify(extra) : "")); return ok; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---- servers (children of this script; stopped by their handles) ----
function start(cmd, args) {
  const child = spawn(cmd, args, { cwd: ROOT, stdio: ["ignore", "pipe", "pipe"] });
  child.log = "";
  child.stdout.on("data", (d) => (child.log += d));
  child.stderr.on("data", (d) => (child.log += d));
  return child;
}
async function waitUp(port) {
  for (let i = 0; i < 100; i++) {
    try { const r = await fetch(`http://127.0.0.1:${port}/`); await r.arrayBuffer(); return; } catch { await sleep(100); }
  }
  throw new Error("server on " + port + " did not come up");
}
async function stop(child, name) {
  if (child.exitCode !== null) return { name, code: child.exitCode, ms: 0 };
  const t0 = Date.now();
  const done = new Promise((r) => child.once("exit", (code, sig) => r({ code, sig })));
  child.kill("SIGTERM");
  const res = await Promise.race([done, sleep(5000).then(() => null)]);
  if (!res) { child.kill("SIGKILL"); await done; return { name, clean: false }; }
  return { name, clean: true, ms: Date.now() - t0, code: res.code };
}
// one raw HTTP/1.1 request, bytes exactly as given (fetch would normalise %2e%2e)
function rawGet(port, target) {
  return new Promise((ok, fail) => {
    const s = net.connect(port, "127.0.0.1", () => s.write(`GET ${target} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n`));
    let buf = ""; s.on("data", (d) => (buf += d)); s.on("end", () => ok(buf)); s.on("error", fail);
  });
}
const stats = async () => (await fetch(`http://127.0.0.1:${DEMO}/leanui/stats`)).json();
const pct = (xs, p) => { const s = [...xs].sort((a, b) => a - b); return s[Math.min(s.length - 1, Math.floor(p * s.length))]; };
const round = (x) => Math.round(x * 100) / 100;

const wasmPath = path.join(ROOT, "dist/counter/app.wasm");
if (!fs.existsSync(wasmPath)) { console.error("no dist/counter: run `leanui build CounterApp counter` first"); process.exit(2); }
const demo = start(path.join(ROOT, ".lake/build/bin/leanui-demo-server"), ["--port", String(DEMO), "--dist", "dist", "--quiet"]);
const stat = start(path.join(ROOT, ".lake/build/bin/leanui"), ["serve", "dist/counter", "--port", String(STATIC), "--coop", "--quiet"]);

try {
  await waitUp(DEMO); await waitUp(STATIC);
  report.pids = { demo: demo.pid, static: stat.pid };

  // ---- static serving (engine-independent) ----
  {
    const S = `http://127.0.0.1:${STATIC}`;
    const ID = { "accept-encoding": "identity" };
    const w = await fetch(S + "/app.wasm", { headers: ID });
    const wasmBytes = new Uint8Array(await w.arrayBuffer());
    check(w.status === 200 && w.headers.get("content-type") === "application/wasm", "wasm MIME", w.headers.get("content-type"));
    check(wasmBytes.length === fs.statSync(wasmPath).size, "wasm size");
    check(w.headers.get("cross-origin-opener-policy") === "same-origin" && w.headers.get("cross-origin-embedder-policy") === "require-corp", "--coop headers");
    const js = await fetch(S + "/leanui.js"); await js.arrayBuffer();
    check(js.headers.get("content-type") === "text/javascript; charset=utf-8", "js MIME", js.headers.get("content-type"));
    const idx = await fetch(S + "/"); const idxText = await idx.text();
    check(idx.headers.get("content-type") === "text/html; charset=utf-8" && idxText.includes("leanui.js"), "index.html for /");
    const head = await fetch(S + "/app.wasm", { method: "HEAD", headers: ID });
    check(head.status === 200 && Number(head.headers.get("content-length")) === wasmBytes.length && (await head.arrayBuffer()).byteLength === 0, "HEAD");
    const etag = w.headers.get("etag");
    const nm = await fetch(S + "/app.wasm", { headers: { ...ID, "if-none-match": etag } });
    check(nm.status === 304, "ETag revalidation", nm.status);
    const trav = await rawGet(STATIC, "/%2e%2e/%2e%2e/lakefile.toml");
    check(/^HTTP\/1\.1 40[04]/.test(trav) && !trav.includes("defaultTargets"), "traversal refused", trav.slice(0, 40));
    const trav2 = await rawGet(DEMO, "/assets/counter/..%2f..%2f..%2flakefile.toml");
    check(/^HTTP\/1\.1 40[04]/.test(trav2) && !trav2.includes("defaultTargets"), "encoded traversal refused", trav2.slice(0, 40));
    const missing = await fetch(S + "/nope.js"); await missing.arrayBuffer();
    check(missing.status === 404, "404");
    // precompressed siblings (leanui build --compress): sent when accepted, decoded to the same bytes
    if (fs.existsSync(wasmPath + ".br")) {
      for (const coding of ["br", "gzip"]) {
        const c = await fetch(S + "/app.wasm", { headers: { "accept-encoding": coding } });
        const bytes = new Uint8Array(await c.arrayBuffer());
        check(c.headers.get("content-encoding") === coding && c.headers.get("content-type") === "application/wasm" &&
          bytes.length === wasmBytes.length && bytes.every((b, i) => b === wasmBytes[i]), "precompressed " + coding, c.headers.get("content-encoding"));
        report.static[coding] = fs.statSync(wasmPath + (coding === "br" ? ".br" : ".gz")).size;
      }
    }
    const demoWasm = await fetch(`http://127.0.0.1:${DEMO}/assets/counter/app.wasm`); await demoWasm.arrayBuffer();
    check(demoWasm.headers.get("content-type") === "application/wasm" && !demoWasm.headers.get("cross-origin-opener-policy"), "demo assets: wasm MIME, no COOP by default");
    Object.assign(report.static, { wasmBytes: wasmBytes.length, etag, traversal: trav.split("\r\n")[0] });
  }

  // ---- load: many server-driven sessions at once over HTTP keep-alive (engine-independent) ----
  {
    const clients = 32, events = 100, lat = [];
    const D = `http://127.0.0.1:${DEMO}`;
    const one = async () => {
      const page = await (await fetch(D + "/counter/server")).text();
      const sid = /"session":"([0-9a-f]+)"/.exec(page)[1];
      const post = async (body) => { const t0 = performance.now(); const r = await fetch(`${D}/leanui/${sid}`, { method: "POST", body });
        const b = new Uint8Array(await r.arrayBuffer()); lat.push(performance.now() - t0); return { status: r.status, b }; };
      await post("h");
      let last;
      for (let i = 0; i < events; i++) last = await post("e\n2\n");   // slot 2 is the + button
      const opsLen = last.b[0] | (last.b[1] << 8) | (last.b[2] << 16) | (last.b[3] << 24);
      // the update's strings: the output's text and the input's value, both the new count
      return new TextDecoder().decode(last.b.subarray(4 + opsLen));
    };
    const t0 = performance.now();
    const finals = await Promise.all(Array.from({ length: clients }, one));
    const wall = performance.now() - t0;
    check(finals.every((f) => f === String(events).repeat(2)), "load: every session counted all its events", finals.slice(0, 4));
    report.load = { clients, eventsPerClient: events, requests: lat.length, wallMs: Math.round(wall), requestsPerSec: Math.round(lat.length / (wall / 1000)),
      latencyMs: { p50: round(pct(lat, 0.5)), p95: round(pct(lat, 0.95)), p99: round(pct(lat, 0.99)), max: round(Math.max(...lat)) } };
  }

  for (const engine of engines) {
    const browser = await pw[engine].launch({ headless: true });
    const R = (report.engines[engine] = { version: browser.version() });
    const errors = [];
    const warnings = [];
    const newPage = async (ctxOpts = {}) => {
      const ctx = await browser.newContext(ctxOpts);
      const page = await ctx.newPage();
      page.on("pageerror", (e) => errors.push(engine + " pageerror: " + e.message));
      page.on("console", (m) => {
        if (m.type() === "error") errors.push(engine + " console: " + m.text());
        if (m.type() === "warning") warnings.push(m.text());
      });
      return { ctx, page };
    };
    const D = `http://127.0.0.1:${DEMO}`;
    const value = (page) => page.$eval("#value", (e) => e.textContent);
    const waitValue = (page, v) => page.waitForFunction((v) => document.querySelector("#value")?.textContent === v, v, { timeout: 10000 });

    // ---- 1. server-driven counter: SSR nodes adopted, events, latency ----
    {
      const { ctx, page } = await newPage();
      let release; const gate = new Promise((r) => (release = r));
      let posts = 0;
      await page.route("**/leanui/*", async (route) => { if (posts++ === 0) await gate; await route.continue(); });
      const before = await stats();
      await page.goto(D + "/counter/server", { waitUntil: "domcontentloaded" });
      // the server-rendered page is complete before the session answers
      R.serverSsr = await value(page);
      await page.evaluate(() => {
        const v = document.querySelector("#value");
        v.__ssr = "kept"; window.__ssrNodes = [...document.querySelectorAll("#app *")]; window.__ssrText = v.firstChild;
      });
      release();
      await page.waitForFunction(() => window.__leanui && window.__leanui.stats.flushes >= 1, null, { timeout: 10000 });
      const adopt = await page.evaluate(() => {
        const now = [...document.querySelectorAll("#app *")];
        return { expando: document.querySelector("#value").__ssr, same: now.length === window.__ssrNodes.length && now.every((n, i) => n === window.__ssrNodes[i]),
                 text: document.querySelector("#value").firstChild === window.__ssrText, mode: document.documentElement.dataset.leanui };
      });
      R.serverAdopt = adopt;
      check(R.serverSsr === "0" && adopt.expando === "kept" && adopt.same && adopt.text && adopt.mode === "server", engine + ": server session adopts the SSR nodes", adopt);
      for (let i = 0; i < 3; i++) await page.click("#inc");
      await waitValue(page, "3");
      await page.click("#dec"); await waitValue(page, "2");
      await page.fill("#box", "-7"); await waitValue(page, "-7");
      const cls = await page.$eval("#value", (e) => e.className);
      await page.click("#reset"); await waitValue(page, "0");
      check(cls === "neg", engine + ": server-driven class update", cls);
      const after = await stats();
      check(after.spawned === before.spawned + 1, engine + ": one session started", { before, after });
      // latency: click -> DOM changed, measured in the page (no Playwright round trips inside)
      const lat = await page.evaluate(async (n) => {
        const v = document.querySelector("#value"), b = document.querySelector("#inc"), out = [];
        for (let i = 0; i < n; i++) {
          const before = v.textContent, t0 = performance.now();
          await new Promise((res) => { const mo = new MutationObserver(() => { if (v.textContent !== before) { mo.disconnect(); res(); } });
            mo.observe(v, { subtree: true, characterData: true, childList: true }); b.click(); });
          out.push(performance.now() - t0);
        }
        const st = performance.getEntriesByType("resource").filter((e) => e.name.includes("/leanui/"))
          .flatMap((e) => (e.serverTiming || []).filter((t) => t.name === "actor").map((t) => t.duration));
        return { out, server: st, final: v.textContent };
      }, 200);
      check(lat.final === "200", engine + ": 200 clicks counted", lat.final);
      R.roundTripMs = { n: lat.out.length, median: round(pct(lat.out, 0.5)), p95: round(pct(lat.out, 0.95)), min: round(Math.min(...lat.out)),
        mean: round(lat.out.reduce((a, b) => a + b, 0) / lat.out.length),
        serverActorMedian: lat.server.length ? round(pct(lat.server, 0.5)) : null, serverTimingEntries: lat.server.length };
      await ctx.close();
    }

    // ---- 2. SSR + wasm hydration keeps the server-rendered nodes ----
    {
      const { ctx, page } = await newPage();
      let release; const gate = new Promise((r) => (release = r));
      const requests = [];
      page.on("request", (r) => requests.push(r.url()));
      await page.route("**/assets/counter/app.js", async (route) => { await gate; await route.continue(); });
      const before = await stats();
      // the held app.js is preloaded, and a preload delays the load event: do not wait for it
      await page.goto(D + "/counter/wasm", { waitUntil: "domcontentloaded" });
      R.wasmSsr = await value(page);
      await page.evaluate(() => {
        const v = document.querySelector("#value");
        v.__ssr = "kept"; document.querySelector("#inc").__ssr = "kept too";
        window.__ssrNodes = [...document.querySelectorAll("#app *")]; window.__ssrText = v.firstChild;
      });
      release();
      await page.waitForFunction(() => window.__leanui && document.documentElement.dataset.leanui, null, { timeout: 30000 });
      const adopt = await page.evaluate(() => {
        const now = [...document.querySelectorAll("#app *")];
        return { expando: document.querySelector("#value").__ssr, expando2: document.querySelector("#inc").__ssr,
                 same: now.length === window.__ssrNodes.length && now.every((n, i) => n === window.__ssrNodes[i]),
                 text: document.querySelector("#value").firstChild === window.__ssrText,
                 mode: document.documentElement.dataset.leanui, bootMs: window.__leanui.bootMs };
      });
      R.wasmAdopt = adopt;
      check(R.wasmSsr === "0" && adopt.expando === "kept" && adopt.expando2 === "kept too" && adopt.same && adopt.text && adopt.mode === "wasm",
        engine + ": wasm hydration adopts the SSR nodes", adopt);
      for (let i = 0; i < 3; i++) await page.click("#inc");
      check(await value(page) === "3", engine + ": wasm clicks after hydration");
      await page.fill("#box", "-7");
      check(await value(page) === "-7" && (await page.$eval("#value", (e) => e.className)) === "neg", engine + ": wasm input after hydration");
      await page.click("#reset");
      check(await value(page) === "0", engine + ": wasm reset");
      check(requests.filter((u) => u.endsWith("/app.wasm")).length === 1 && requests.filter((u) => u.endsWith("/app.js")).length === 1, engine + ": each asset fetched once", requests);
      // what the wasm cost on the wire (a precompressed sibling when the build has one)
      R.wasmTransfer = await page.evaluate(() => {
        const e = performance.getEntriesByType("resource").find((e) => e.name.endsWith("/app.wasm"));
        return e ? { encoded: e.encodedBodySize, decoded: e.decodedBodySize } : null;
      });
      if (fs.existsSync(wasmPath + ".gz"))
        check(R.wasmTransfer && R.wasmTransfer.encoded > 0 && R.wasmTransfer.encoded < R.wasmTransfer.decoded / 3, engine + ": the wasm travels compressed", R.wasmTransfer);
      const after = await stats();
      check(after.reserved === before.reserved && after.spawned === before.spawned, engine + ": a wasm page costs no session", { before, after });
      await ctx.close();
    }

    // ---- 3. LeanUI.boot: wasm with Memory64; the server without ----
    {
      const { ctx, page } = await newPage();
      const before = await stats();
      await page.goto(D + "/counter");
      await page.waitForFunction(() => document.documentElement.dataset.leanui, null, { timeout: 30000 });
      R.autoMode = await page.evaluate(() => document.documentElement.dataset.leanui);
      await page.click("#inc");
      check(R.autoMode === "wasm" && await value(page) === "1", engine + ": /counter boots wasm", R.autoMode);
      const mid = await stats();
      check(mid.reserved === before.reserved + 1 && mid.spawned === before.spawned, engine + ": auto page reserves but does not start a session", { before, mid });
      await ctx.close();
      const n = await newPage();
      // a browser without Memory64: hide it from the feature test
      await n.page.addInitScript(() => { const v = WebAssembly.validate; WebAssembly.validate = (b) => (b && b.length === 13 ? false : v(b)); });
      await n.page.goto(D + "/counter");
      await n.page.waitForFunction(() => window.__leanui && window.__leanui.stats.flushes >= 1, null, { timeout: 10000 });
      R.autoNoM64 = await n.page.evaluate(() => document.documentElement.dataset.leanui);
      await n.page.click("#inc"); await waitValue(n.page, "1");
      await n.page.click("#inc"); await waitValue(n.page, "2");
      check(R.autoNoM64 === "server", engine + ": /counter without Memory64 is server-driven", R.autoNoM64);
      const end = await stats();
      check(end.spawned === mid.spawned + 1, engine + ": the fallback started its session", { mid, end });
      await n.ctx.close();
    }

    // ---- 4. a server-driven ticker: subscriptions, fetch, title ----
    {
      const { ctx, page } = await newPage();
      await page.goto(D + "/ticker/server?from=5");
      await page.waitForFunction(() => window.__leanui && window.__leanui.stats.flushes >= 1, null, { timeout: 10000 });
      const ticks = () => page.$eval("#ticks", (e) => Number(e.textContent));
      const t0 = await ticks();
      await page.click("#toggle");
      await page.waitForFunction(() => Number(document.querySelector("#ticks").textContent) >= 10, null, { timeout: 10000 });
      await page.click("#toggle");
      await sleep(250);
      const stopped = await ticks();
      await sleep(400);
      const still = await ticks();
      await page.click("#fetch");
      await page.waitForFunction(() => document.querySelector("#reply").textContent.includes("from Lean"), null, { timeout: 10000 });
      const reply = await page.$eval("#reply", (e) => e.textContent);
      await page.click("#bump");
      await page.waitForFunction(() => document.title.startsWith("ticker "), null, { timeout: 10000 });
      const title = await page.title();
      R.ticker = { from: t0, stopped, still, reply, title };
      check(t0 === 5 && stopped >= 10 && still === stopped && reply.includes(`"n":"${stopped}"`) && title === `ticker ${stopped + 100}`,
        engine + ": ticker (interval callbacks, fetch callback, title)", R.ticker);
      await ctx.close();
    }

    // ---- 5. markup the HTML parser rewrites still hydrates exactly (LeanUI.Render's contract) ----
    {
      const { ctx, page } = await newPage();
      await page.goto(D + "/contract/server");
      await page.waitForFunction(() => window.__leanui && window.__leanui.stats.flushes >= 1, null, { timeout: 10000 });
      const read = () => page.evaluate(() => {
        const q = (s) => document.querySelector(s);
        return { pre: q("#pre").textContent, texts: [...q("#texts").childNodes].filter((n) => n.nodeType === 3).map((n) => n.data),
                 crlf: q("#crlf").textContent, title: q("#crlf").getAttribute("title"), dup: q("#dup").className,
                 dupText: q("#dup").textContent, ta: q("#ta").value };
      });
      const before = await read();
      await page.click("#go");
      await page.waitForFunction(() => document.querySelector("#pre").textContent === "\n1\n", null, { timeout: 10000 });
      const after = await read();
      R.contract = { before, after };
      check(before.pre === "\n0\n" && JSON.stringify(before.texts) === JSON.stringify(["a", "", "b", "0"]) && before.crlf === "c\r\nd" &&
        before.title === "x\r\ny" && before.dup === "last" && before.dupText === "😀 & <tags>" && before.ta === "\nline",
        engine + ": parser-rewritten markup hydrates as the view", before);
      check(JSON.stringify(after.texts) === JSON.stringify(["a", "", "b", "1"]), engine + ": updates reach the claimed text nodes", after);
      await ctx.close();
    }

    // ---- 6. without JavaScript the server-rendered page is the page ----
    {
      const { ctx, page } = await newPage({ javaScriptEnabled: false });
      await page.goto(D + "/counter/ssr");
      const ssr = { value: await value(page), scripts: await page.$$eval("script", (s) => s.length), button: await page.$eval("#inc", (e) => e.textContent) };
      await page.goto(D + "/counter/server");
      ssr.serverPage = await value(page);
      R.noJs = ssr;
      check(ssr.value === "0" && ssr.scripts === 0 && ssr.button === "+" && ssr.serverPage === "0", engine + ": pages render without JavaScript", ssr);
      await ctx.close();
    }

    R.mimeWarnings = warnings.filter((w) => /mime|wasm streaming/i.test(w));
    check(R.mimeWarnings.length === 0, engine + ": no wasm MIME fallback warnings", R.mimeWarnings);
    check(errors.length === 0, engine + ": no page errors", errors);
    await browser.close();
  }
  report.sessions = await stats();
} catch (e) {
  failures.push("exception: " + (e && e.stack || e));
} finally {
  report.shutdown = [await stop(demo, "leanui-demo-server"), await stop(stat, "leanui serve")];
  for (const s of report.shutdown) check(s.clean !== false && s.code === 0, s.name + " shuts down cleanly on SIGTERM", s);
}
report.failures = failures;
console.log(JSON.stringify(report, null, 1));
if (failures.length) { console.log("demo server log:\n" + demo.log.slice(-2000)); }
console.log(failures.length ? "FAIL" : "PASS");
process.exit(failures.length ? 1 : 0);
