// VIR's real resource loader, startup, callbacks, errors and shutdown.
//   vir/build.sh test && node tests/browser/vir.mjs [chromium] [firefox]
// Serves its own fixture; Playwright resolution follows playwright.mjs.
import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { pw } from "./playwright.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const dir = path.resolve(process.env.LEANUI_VIR_TEST_DIR || path.join(root, "dist/vir/test"));
const config = JSON.parse(fs.readFileSync(path.join(dir, "app.json"), "utf8"));
const engines = process.argv.slice(2);
if (!engines.length) engines.push("chromium", "firefox");
const wrapper = `
import { createProgram as create } from ${JSON.stringify("/" + config.runtimeModule)};
export async function createProgram(options) {
  const program = await create(options);
  const record = { program, calls: [], disposals: 0, fault: window.nextVirFault };
  window.nextVirFault = null;
  (window.virRecords ||= []).push(record);
  return {
    get status() { return program.status === 'disposed' ? 'disposed' : record.failed ? 'failed' : program.status; },
    call(name, ...args) {
      record.calls.push(name);
      record.runtime = LeanUI.active;
      if (record.fault && name.endsWith('.' + record.fault.entry)) {
        const fault = record.fault; record.fault = null;
        if (fault.dispose) {
          const value = program.call(name, ...args);
          record.runtime.dispose();
          return value;
        }
        record.failed = fault.terminal;
        if (fault.native) return program.call('LeanUIVir.TestApp.reject');
        throw fault.error;
      }
      return program.call(name, ...args);
    },
    dispose() {
      record.disposals++;
      program.dispose();
      if (record.disposeError) throw record.disposeError;
    },
  };
}`;

const server = http.createServer((req, res) => {
  const pathname = new URL(req.url, "http://localhost").pathname;
  if (pathname === "/favicon.ico") { res.writeHead(204); res.end(); return; }
  if (["/boot-bench.html", "/boot-life.html"].includes(pathname)) {
    res.writeHead(200, { "content-type": "text/html" });
    res.end(fs.readFileSync(path.join(root, "vir/pages", pathname.includes("bench") ? "bench.html" : "life.html")));
    return;
  }
  if (["/bench.css", "/life.css"].includes(pathname)) { res.writeHead(200, { "content-type": "text/css" }); res.end(); return; }
  if (pathname === "/slow") {
    // Start the response, but leave the body incomplete until the client aborts it.
    res.writeHead(200, { "content-type": "text/plain" });
    res.write("pending");
    return;
  }
  if (pathname === "/instrumented-runtime.js") {
    res.writeHead(200, { "content-type": "text/javascript" }); res.end(wrapper); return;
  }
  if (pathname === "/app.json") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ ...config, runtimeModule: "instrumented-runtime.js" })); return;
  }
  try {
    const file = path.join(dir, pathname === "/" ? "index.html" : pathname);
    const mime = { ".html": "text/html", ".js": "text/javascript", ".json": "application/json", ".wasm": "application/wasm" };
    const bytes = fs.readFileSync(file);
    res.writeHead(200, { "content-type": mime[path.extname(file)] || "application/octet-stream" }); res.end(bytes);
  } catch { res.writeHead(404); res.end(); }
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const base = `http://127.0.0.1:${server.address().port}/`;

async function open(browser) {
  const page = await browser.newPage(), errors = [];
  page.on("pageerror", (e) => errors.push("pageerror: " + e.message));
  page.on("console", (m) => {
    if (m.type() === "error") errors.push(Promise.all(m.args().map((a) =>
      a.evaluate((x) => x instanceof Error ? `${x.name}: ${x.message}` : String(x)).catch(() => "unavailable console argument")))
      .then((parts) => parts.join(" ")));
  });
  await page.addInitScript(() => {
    localStorage.setItem("leanui.vir.probe", "é 😀\u0000stored");
    const fetch = window.fetch;
    window.slowSignals = [];
    window.fetch = function (url, options) {
      if (url === "/slow") slowSignals.push(options.signal);
      return fetch.call(this, url, options);
    };
  });
  await page.goto(base);
  return { page, errors };
}

async function start(page) {
  await page.evaluate(async () => { window.rt = await LeanUIVir.start({ app: "LeanUIVir.TestApp" }); });
  await page.waitForFunction(() => document.querySelector("#stored").textContent === "é 😀\u0000stored" && document.querySelector("#delayed").textContent === "1");
}

async function effects(browser) {
  const { page, errors } = await open(browser);
  try {
    await start(page);
    await page.click("#focus");
    await page.waitForFunction(() => document.querySelector("#order").textContent === "event;focus;");
    await page.click("#toggle");
    await page.waitForFunction(() => +document.querySelector("#ticks").textContent >= 3);
    await page.click("#toggle");
    const stopped = await page.locator("#ticks").textContent();
    await page.waitForTimeout(80);
    assert.equal(await page.locator("#ticks").textContent(), stopped);
    const reentry = await page.evaluate(() => {
      const apply = rt.apply; let inject = true, queued = false;
      rt.apply = function (...args) {
        if (inject) { inject = false; document.querySelector("#focus").click(); queued = rt.queue.length === 1; }
        return apply.apply(this, args);
      };
      document.querySelector("#probe-input").blur();
      document.querySelector("#toggle").click();
      rt.apply = apply;
      document.querySelector("#toggle").click();
      return { queued, pending: rt.queue.length, busy: rt.busy };
    });
    assert.deepEqual(reentry, { queued: true, pending: 0, busy: false });
    await page.waitForFunction(() => document.querySelector("#order").textContent === "event;focus;event;focus;");
    await page.click("#toggle");
    await page.click("#delay");
    const response = page.waitForResponse((r) => r.url() === base + "slow");
    await page.click("#fetch");
    await response;
    const aborted = page.waitForEvent("requestfailed", { predicate: (r) => r.url() === base + "slow" });
    const disposal = await page.evaluate(() => {
      document.querySelector("#frame").click();
      const record = virRecords[0], calls = record.calls.length;
      const live = { intervals: rt.timers.size, timeouts: rt.timeouts.size, frames: rt.frames.size };
      rt.dispose(); rt.dispose();
      window.disposedEvents = 0;
      rt.onEvent = () => disposedEvents++;
      document.querySelector("#focus").click();
      document.dispatchEvent(new KeyboardEvent("keydown", { key: "p" }));
      dispatchEvent(new PopStateEvent("popstate"));
      rt.callback(1, true, "late");
      return { live, callsAtDisposal: calls, fetches: slowSignals.length,
        disposals: record.disposals, status: record.program.status, stopped: rt.disposed,
        effectsAborted: rt.effects.signal.aborted, fetchAborted: slowSignals.every((s) => s.aborted),
        remaining: [rt.timers.size, rt.timeouts.size, rt.frames.size, rt.objectUrls.size, rt.files.size, rt.queue.length],
        transport: rt.transport, active: LeanUI.active, calls: record.calls.length - calls, events: disposedEvents };
    });
    assert.equal(disposal.live.intervals, 1);
    assert.equal(disposal.live.timeouts, 1);
    assert.equal(disposal.live.frames, 1);
    assert.equal(disposal.disposals, 1); assert.equal(disposal.status, "disposed");
    assert.equal(disposal.fetches, 1);
    assert.ok(disposal.stopped && disposal.effectsAborted && disposal.fetchAborted);
    assert.deepEqual(disposal.remaining, [0, 0, 0, 0, 0, 0]);
    assert.equal(disposal.transport, null); assert.equal(disposal.active, null);
    assert.equal(disposal.calls, 0); assert.equal(disposal.events, 0);
    assert.match((await aborted).failure().errorText, /abort|cancel/i);
    await page.waitForTimeout(100);
    assert.equal(await page.evaluate(() => virRecords[0].calls.length), disposal.callsAtDisposal);
    assert.deepEqual(errors, []);
  } finally { await page.close(); }
}

async function startupFailure(browser) {
  const { page, errors } = await open(browser);
  try {
    const result = await page.evaluate(async () => {
      const previous = LeanUI.active;
      let error;
      try { await LeanUIVir.start({ app: "LeanUIVir.TestApp", flags: "fail" }); } catch (e) { error = e; }
      const failed = virRecords[0], runtime = failed.runtime;
      const cleaned = { rejected: !!error, disposals: failed.disposals, status: failed.program.status,
        timeouts: runtime.timeouts.size, frames: runtime.frames.size, aborted: runtime.effects.signal.aborted,
        fetches: slowSignals.length, fetchAborted: slowSignals.every((s) => s.aborted),
        restored: LeanUI.active === previous, transport: runtime.transport };
      window.rt = await LeanUIVir.start({ app: "LeanUIVir.TestApp" });
      const valid = rt.transport.program.status;
      rt.dispose();
      return { cleaned, valid };
    });
    assert.deepEqual(result, { cleaned: { rejected: true, disposals: 1, status: "disposed", timeouts: 0, frames: 0, aborted: true, fetches: 1, fetchAborted: true, restored: true, transport: null }, valid: "active" });
    assert.deepEqual(errors, []);
  } finally { await page.close(); }
}

async function preservePrevious(browser) {
  const { page, errors } = await open(browser);
  try {
    await start(page);
    const result = await page.evaluate(async () => {
      const previous = rt;
      let rejected = false;
      try { await LeanUIVir.start({ app: "LeanUIVir.TestApp", selector: "[" }); } catch { rejected = true; }
      const result = { rejected, restored: LeanUI.active === previous, previous: virRecords[0].program.status,
        failed: virRecords[1].program.status, disposals: virRecords[1].disposals };
      document.querySelector("#toggle").click();
      result.previousWorks = previous.timers.size === 1;
      previous.dispose(); return result;
    });
    assert.deepEqual(result, { rejected: true, restored: true, previous: "active", failed: "disposed", disposals: 1, previousWorks: true });
    assert.deepEqual(errors, []);
  } finally { await page.close(); }
}

async function disposeDuringFocus(browser) {
  const { page, errors } = await open(browser);
  try {
    await start(page);
    const result = await page.evaluate(async () => {
      const input = document.querySelector("#probe-input"), first = "#probe-input", second = "#focus";
      input.addEventListener("focus", () => rt.dispose(), { once: true });
      const words = new Uint32Array([42, 0, first.length, 42, first.length, second.length]);
      const strings = new TextEncoder().encode(first + second), bytes = new Uint8Array(words.byteLength + strings.length);
      bytes.set(new Uint8Array(words.buffer)); bytes.set(strings, words.byteLength);
      rt.apply(bytes, 0, words.byteLength, words.byteLength, strings.length);
      await new Promise(queueMicrotask);
      return { focused: document.activeElement.id, disposed: rt.disposed, disposals: virRecords[0].disposals };
    });
    assert.deepEqual(result, { focused: "probe-input", disposed: true, disposals: 1 });
    assert.deepEqual(errors, []);
  } finally { await page.close(); }
}

async function failedCalls(browser, terminal, domError = false) {
  const { page, errors } = await open(browser);
  try {
    await start(page);
    const result = await page.evaluate(({ terminal, domError }) => {
      const record = virRecords[0], error = new Error("injected call failure"), calls = record.calls.length;
      let notifications = 0, sameError = false;
      rt.container.addEventListener("leanui:error", (e) => { notifications++; sameError = e.detail === error; });
      if (domError) rt.apply = () => { throw error; };
      else record.fault = { entry: "event", terminal, native: !terminal, error };
      if (terminal) rt.queue.push([1, 0, true, "queued"]);
      document.querySelector("#toggle").click();
      const failed = { disposed: !!rt.disposed, crashed: rt.crashed === error, calls: record.calls.length - calls,
        queued: rt.queue.length, notifications, sameError, disposals: record.disposals, status: record.program.status };
      if (!terminal) document.querySelector("#toggle").click();
      const recovered = !terminal && rt.timers.size === 1;
      rt.dispose();
      return { failed, recovered };
    }, { terminal, domError });
    if (terminal) {
      assert.deepEqual(result, { failed: { disposed: true, crashed: true, calls: 1, queued: 0, notifications: 1, sameError: true, disposals: 1, status: "disposed" }, recovered: false });
    } else {
      assert.deepEqual(result, { failed: { disposed: false, crashed: false, calls: 1, queued: 0, notifications: 0, sameError: false, disposals: 0, status: "active" }, recovered: true });
    }
    assert.equal(errors.length, 1); assert.match(await errors[0], /injected call failure/);
  } finally { await page.close(); }
}

async function cleanupError(browser) {
  for (const entry of ["start", "take"]) {
    const { page, errors } = await open(browser);
    try {
      const result = await page.evaluate(async (entry) => {
        const original = new Error("original startup failure");
        window.nextVirFault = { entry, terminal: false, error: original };
        // Cover failure before a session exists as well as failure while taking its first output.
        const call = LeanUIVir.VirTransport.prototype.dispose;
        LeanUIVir.VirTransport.prototype.dispose = function () { virRecords.at(-1).disposeError = new Error("cleanup failure"); return call.call(this); };
        let sameError = false;
        try { await LeanUIVir.start({ app: "LeanUIVir.TestApp" }); } catch (e) { sameError = e === original; }
        finally { LeanUIVir.VirTransport.prototype.dispose = call; }
        const record = virRecords[0];
        return { sameError, disposals: record.disposals, status: record.program.status, stopped: record.runtime.disposed, transport: record.runtime.transport };
      }, entry);
      assert.deepEqual(result, { sameError: true, disposals: 1, status: "disposed", stopped: true, transport: null });
      assert.equal(errors.length, 1); assert.match(await errors[0], /cleanup failure/);
    } finally { await page.close(); }
  }
}

async function queuedStartupFailure(browser) {
  const { page, errors } = await open(browser);
  try {
    await start(page);
    const result = await page.evaluate(async () => {
      const previous = rt, apply = LeanUIVir.VirTransport.prototype.apply;
      const error = new Error("queued startup terminal failure");
      window.nextVirFault = { entry: "event", terminal: true, error };
      let inject = true;
      LeanUIVir.VirTransport.prototype.apply = function (updates) {
        const result = apply.call(this, updates);
        if (inject && this !== previous.transport) { inject = false; this.rt.queue.push([0, 0, ""]); }
        return result;
      };
      let sameError = false;
      try { await LeanUIVir.start({ app: "LeanUIVir.TestApp" }); } catch (e) { sameError = e === error; }
      finally { LeanUIVir.VirTransport.prototype.apply = apply; }
      const result = { sameError, failed: virRecords[1].program.status, previous: virRecords[0].program.status,
        restored: LeanUI.active === previous, disposals: virRecords[1].disposals };
      previous.dispose(); return result;
    });
    assert.deepEqual(result, { sameError: true, failed: "disposed", previous: "active", restored: true, disposals: 1 });
    assert.equal(errors.length, 1); assert.match(await errors[0], /queued startup terminal failure/);
  } finally { await page.close(); }
}

async function startupCancellation(browser) {
  const { page, errors } = await open(browser);
  try {
    const result = await page.evaluate(async () => {
      const previous = LeanUI.active;
      window.nextVirFault = { entry: "start", dispose: true };
      let error;
      try { await LeanUIVir.start({ app: "LeanUIVir.TestApp" }); } catch (e) { error = e; }
      const record = virRecords[0];
      return { cancelled: error?.name === "AbortError", calls: record.calls.map((name) => name.split(".").at(-1)),
        disposed: record.runtime.disposed, released: record.runtime.transport === null,
        disposals: record.disposals, status: record.program.status, restored: LeanUI.active === previous };
    });
    assert.deepEqual(result, { cancelled: true, calls: ["start"], disposed: true, released: true,
      disposals: 1, status: "disposed", restored: true });
    assert.deepEqual(errors, []);
  } finally { await page.close(); }
}

async function bootCancellation(browser) {
  for (const app of ["bench", "life"]) {
    const page = await browser.newPage(), errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    page.on("console", (m) => { if (m.type() === "error") errors.push(m.text()); });
    try {
      // Only the boot page's rejection handler is under test here; other cases use real VIR.
      await page.addInitScript(() => {
        Object.defineProperty(window, "LeanUIVir", { configurable: true, set(api) {
          Object.defineProperty(window, "LeanUIVir", { value: api, writable: true, configurable: true });
          api.start = () => {
            document.querySelector("#app").textContent = "replacement app";
            window.bootCancelled = true;
            return Promise.reject(new DOMException("The app was disposed", "AbortError"));
          };
        } });
      });
      await page.goto(base + "boot-" + app + ".html");
      await page.waitForFunction(() => window.bootCancelled);
      assert.equal(await page.locator("#app").textContent(), "replacement app");
      assert.deepEqual(errors, []);
    } finally { await page.close(); }
  }
}

try {
  for (const engine of engines) {
    const browser = await pw[engine].launch({ headless: true });
    try {
      for (const [name, test] of [["callbacks and shutdown", effects], ["startup cleanup", startupFailure], ["previous runtime", preservePrevious],
        ["queued startup failure", queuedStartupFailure], ["startup cancellation", startupCancellation],
        ["quiet cancellation on demo pages", bootCancellation], ["disposal during focus", disposeDuringFocus],
        ["terminal failure", (b) => failedCalls(b, true)], ["DOM failure", (b) => failedCalls(b, true, true)],
        ["recoverable error", (b) => failedCalls(b, false)], ["cleanup error", cleanupError]]) {
        await test(browser); console.log(`${engine}: PASS ${name}`);
      }
    } finally { await browser.close(); }
  }
} finally { server.closeAllConnections(); await new Promise((resolve) => server.close(resolve)); }
