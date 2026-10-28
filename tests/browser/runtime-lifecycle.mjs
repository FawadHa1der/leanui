// Backend-independent lifetime contracts; no compiled app or web server required.
// Deterministic deferred work covers disposal races, rather than waiting for timers to win.
import assert from "node:assert/strict";
import fs from "node:fs";
import { pw } from "./playwright.mjs";

const runtime = fs.readFileSync(new URL("../../runtime/leanui.js", import.meta.url), "utf8");
const engines = process.argv.slice(2);
if (!engines.length) engines.push("chromium", "firefox");
const tests = [
  ["disposal cancels scheduled effects and removes browser listeners", async () => {
    const pending = new Map(), revoked = [], calls = [], listenerEntries = [];
    const targets = new Map([[document.querySelector("#app"), "container"], [document, "document"], [window, "window"]]);
    const add = EventTarget.prototype.addEventListener;
    // Count entry before Runtime's closed-entry/subscription guards can hide a retained listener.
    EventTarget.prototype.addEventListener = function (type, listener, options) {
      if (!targets.has(this)) return add.call(this, type, listener, options);
      const label = targets.get(this) + ":" + type;
      return add.call(this, type, function (event) { listenerEntries.push(label); listener.call(this, event); }, options);
    };
    let next = 0, navigations = 0, aborted = false;
    const schedule = (kind) => () => { const id = ++next; pending.set(id, kind); return id; };
    globalThis.setTimeout = schedule("timeout"); globalThis.setInterval = schedule("interval");
    globalThis.requestAnimationFrame = schedule("frame");
    globalThis.clearTimeout = globalThis.clearInterval = globalThis.cancelAnimationFrame = (id) => pending.delete(id);
    URL.createObjectURL = () => "blob:lifetime"; URL.revokeObjectURL = (url) => revoked.push(url);
    history.pushState = () => { navigations++; };
    globalThis.fetch = (_url, init) => new Promise((_resolve, reject) => {
      init.signal.addEventListener("abort", () => { aborted = true; reject(new DOMException("cancelled", "AbortError")); });
    });
    const rt = new LeanUI.Runtime({ event() { calls.push("event"); }, callback() { calls.push("callback"); } });
    rt.setContainer("#app"); LeanUI.active = rt;
    const button = document.createElement("button"); button.__lui = { click: [1, 0, 0] };
    rt.container.append(button); rt.delegate("click");
    const words = new Uint32Array([33, 1, 100, 34, 2, 100, 45, 3, 41, 4, 52, 5]);
    rt.apply(new Uint8Array(words.buffer), 0, words.byteLength, words.byteLength, 0);
    EventTarget.prototype.addEventListener = add;
    button.click(); document.dispatchEvent(new KeyboardEvent("keydown", { key: "a", bubbles: true }));
    dispatchEvent(new PopStateEvent("popstate"));
    const liveListeners = listenerEntries.splice(0); calls.length = 0;
    rt.objectUrl(new Blob(["owned"])); rt.fetch(6, "GET", "/pending", "", "");
    const scheduled = [...pending.values()].sort();
    rt.dispose(); rt.dispose();
    button.click(); document.dispatchEvent(new KeyboardEvent("keydown", { key: "a", bubbles: true }));
    dispatchEvent(new PopStateEvent("popstate"));
    const link = document.createElement("a"); link.dataset.link = ""; link.href = "/next";
    document.body.append(link);
    const click = new MouseEvent("click", { bubbles: true, cancelable: true });
    link.dispatchEvent(click);
    // The fetch rejection and its callback attempt settle after closure.
    await Promise.resolve(); await Promise.resolve(); await Promise.resolve();
    return { scheduled, pending: pending.size, revoked, aborted, calls, navigations, prevented: click.defaultPrevented,
      liveListeners, listenerEntries };
  }, { scheduled: ["frame", "interval", "timeout"], pending: 0, revoked: ["blob:lifetime"], aborted: true,
    calls: [], navigations: 0, prevented: false,
    liveListeners: ["container:click", "document:click", "document:keydown", "window:popstate"], listenerEntries: [] }],
  ["changing the mount removes delegation from the old container", () => {
    document.querySelector("#app").innerHTML = '<button id="old">old</button>';
    const other = document.createElement("div"); other.id = "other";
    other.innerHTML = '<button id="new">new</button>'; document.body.append(other);
    const calls = [], rt = new LeanUI.Runtime({ event(slot) { calls.push(slot); } });
    document.querySelector("#old").__lui = { click: [1, 0, 0] };
    document.querySelector("#new").__lui = { click: [2, 0, 0] };
    rt.setContainer("#app"); rt.delegate("click"); rt.setContainer("#other");
    document.querySelector("#old").click(); document.querySelector("#new").click();
    rt.dispose(); document.querySelector("#new").click();
    return calls;
  }, [2]],
  ["in-flight delegation stops before ancestor payload extraction", () => {
    document.querySelector("#app").innerHTML = '<div id="parent"><button id="child">drop</button></div>';
    let calls = 0;
    const rt = new LeanUI.Runtime({ isTerminalError() { return true; }, event() { calls++; throw new Error("terminal drop"); } });
    rt.setContainer("#app"); LeanUI.active = rt; rt.delegate("drop");
    document.querySelector("#child").__lui = { drop: [1, 5, 0] };
    document.querySelector("#parent").__lui = { drop: [2, 5, 0] };
    const transfer = new DataTransfer(); transfer.items.add(new File(["payload"], "file.bin"));
    document.querySelector("#child").dispatchEvent(new DragEvent("drop", { bubbles: true, dataTransfer: transfer }));
    return { disposed: rt.disposed, calls, files: rt.files.size };
  }, { disposed: true, calls: 1, files: 0 }],
  ["custom-element construction cannot restore disposed handle tables", () => {
    const rows = [];
    for (const mode of ["create", "template", "clone"]) {
      const rt = new LeanUI.Runtime({});
      const tag = "lifetime-" + mode;
      let armed = false, disposals = 0;
      customElements.define(tag, class extends HTMLElement {
        constructor() { super(); if (armed) { disposals++; rt.dispose(); } }
      });
      const apply = (words, text = "") => {
        const w = new Uint32Array(words), strings = new TextEncoder().encode(text);
        const bytes = new Uint8Array(w.byteLength + strings.length);
        bytes.set(new Uint8Array(w.buffer)); bytes.set(strings, w.byteLength);
        rt.apply(bytes, 0, w.byteLength, w.byteLength, strings.length);
      };
      if (mode !== "create") { rt.nodes[1] = document.createElement(tag); rt.kinds[1] = 0; }
      if (mode === "clone") apply([20, 0, 1, 1]);
      armed = true;
      if (mode === "create") apply([17, 1, 0, tag.length, 1, 1, 0, 1], tag);
      else if (mode === "template") apply([20, 0, 1, 1]);
      else apply([21, 0, 1, 2]);
      rows.push({ disposed: rt.disposed, disposals, tables: [rt.nodes.length, rt.kinds.length, rt.names.length, rt.tpl.length] });
    }
    return rows;
  }, [0, 1, 2].map(() => ({ disposed: true, disposals: 1, tables: [0, 0, 0, 0] }))],
  ["the current property opcode finishes before cleanup", () => {
    const rows = [];
    for (const opcode of [5, 8]) {
      const rt = new LeanUI.Runtime({}); let writes = 0;
      const el = document.createElement("div");
      Object.defineProperty(el, "probe", { get() { rt.dispose(); return "old"; }, set() { writes++; } });
      rt.nodes[1] = el; rt.names[1] = "probe";
      const words = new Uint32Array([...(opcode === 5 ? [5, 1, 1, 0, 0] : [8, 1, 1]), 44, 0, 4]);
      const bytes = new Uint8Array(words.byteLength + 4); bytes.set(new Uint8Array(words.buffer));
      bytes.set(new TextEncoder().encode("next"), words.byteLength);
      rt.apply(bytes, 0, words.byteLength, words.byteLength, 4);
      rows.push({ disposed: rt.disposed, writes, skippedNext: document.title !== "next" });
    }
    return rows;
  }, [{ disposed: true, writes: 1, skippedNext: true }, { disposed: true, writes: 1, skippedNext: true }]],
  ["the current coalesced removal finishes before cleanup", () => {
    const rt = new LeanUI.Runtime({}); let armed = false, disconnected = 0;
    customElements.define("lifetime-remove", class extends HTMLElement {
      disconnectedCallback() { if (armed) { disconnected++; rt.dispose(); } }
    });
    const parent = document.querySelector("#app"), a = document.createElement("lifetime-remove"), b = document.createElement("lifetime-remove"), c = document.createElement("span");
    parent.append(a, b, c); rt.nodes[1] = a; rt.nodes[2] = b; armed = true;
    const words = new Uint32Array([12, 1, 12, 2, 44, 0, 4]), bytes = new Uint8Array(words.byteLength + 4);
    bytes.set(new Uint8Array(words.buffer)); bytes.set(new TextEncoder().encode("next"), words.byteLength);
    rt.apply(bytes, 0, words.byteLength, words.byteLength, 4);
    return { disposed: rt.disposed, disconnected, remaining: parent.children.length, secondKept: b.parentNode === parent,
      skippedNext: document.title !== "next" };
  }, { disposed: true, disconnected: 2, remaining: 1, secondKept: false, skippedNext: true }],
  ["terminal cleanup waits for the outer synchronous caller", () => {
    const trace = [], error = new Error("terminal construction"), tag = "lifetime-unwind";
    let delivered = 0, intact = false, cleanAtNotice = false;
    const transport = {
      isTerminalError() { return true; },
      event() {
        trace.push("transport enter");
        const words = new Uint32Array([17, 1, 0, tag.length, 1, 1, 0, 1, 44, tag.length, 4]);
        const strings = new TextEncoder().encode(tag + "next"), bytes = new Uint8Array(words.byteLength + strings.length);
        bytes.set(new Uint8Array(words.buffer)); bytes.set(strings, words.byteLength);
        rt.apply(bytes, 0, words.byteLength, words.byteLength, strings.length);
        trace.push("transport return");
      },
      callback() { delivered++; },
      dispose() { trace.push("release"); },
    };
    const rt = new LeanUI.Runtime(transport); rt.setContainer("#app"); LeanUI.active = rt;
    rt.container.addEventListener("leanui:error", (e) => {
      trace.push("notify"); cleanAtNotice = rt.transport === null && rt.nodes.length === 0 && e.detail === error;
    });
    customElements.define(tag, class extends HTMLElement {
      constructor() {
        super(); trace.push("close"); rt.crash(error); rt.callback(1, true, "late");
        intact = rt.transport === transport && rt.names[1] === tag && rt.effects.signal.aborted && LeanUI.active === null;
        trace.push("constructor return");
      }
    });
    rt.send(0, 1, ""); rt.dispose();
    return { trace, intact, cleanAtNotice, delivered, skippedNext: document.title !== "next", disposed: rt.disposed };
  }, { trace: ["transport enter", "close", "constructor return", "transport return", "release", "notify"],
    intact: true, cleanAtNotice: true, delivered: 0, skippedNext: true, disposed: true }],
  ["unwind preserves the original exception if transport cleanup fails", () => {
    const original = new Error("property failed"); let disposals = 0, caught;
    const rt = new LeanUI.Runtime({ dispose() { disposals++; throw new Error("cleanup failed"); } });
    const el = document.createElement("div");
    Object.defineProperty(el, "probe", { get() { rt.dispose(); throw original; } });
    rt.nodes[1] = el; rt.names[1] = "probe";
    const words = new Uint32Array([5, 1, 1, 0, 0]);
    try { rt.apply(new Uint8Array(words.buffer), 0, words.byteLength, words.byteLength, 0); } catch (e) { caught = e; }
    rt.dispose();
    return { original: caught === original, disposals, handles: rt.nodes.length, transport: rt.transport };
  }, { original: true, disposals: 1, handles: 0, transport: null }],
  ["bitmap closes on every decode exit", async () => {
    const rows = [];
    for (const fail of ["context", "draw", "read", "none"]) {
      let closes = 0, result, closedAtCallback;
      const rt = new LeanUI.Runtime({ callbackBytes(...args) { result = args; closedAtCallback = closes === 1; } });
      rt.files.set(1, new File(["x"], "x"));
      globalThis.createImageBitmap = async () => ({ width: 1, height: 1, close() { closes++; } });
      globalThis.OffscreenCanvas = class {
        getContext() {
          if (fail === "context") return null;
          return {
            drawImage() { if (fail === "draw") throw new Error("draw failed"); },
            getImageData() { if (fail === "read") throw new Error("read failed"); return { data: new Uint8ClampedArray(4) }; },
          };
        }
      };
      await rt.readFile(1, 1, true);
      rows.push({ closes, closedAtCallback, ok: result[1], bytes: result[3].length });
      rt.dispose();
    }
    return rows;
  }, [{ closes: 1, closedAtCallback: true, ok: false, bytes: 0 }, { closes: 1, closedAtCallback: true, ok: false, bytes: 0 },
      { closes: 1, closedAtCallback: true, ok: false, bytes: 0 }, { closes: 1, closedAtCallback: true, ok: true, bytes: 4 }]],
  ["late bitmap closes without drawing", async () => {
    let resolve, closes = 0, canvases = 0, callbacks = 0;
    const rt = new LeanUI.Runtime({ callbackBytes() { callbacks++; } });
    rt.files.set(1, new File(["x"], "x"));
    globalThis.createImageBitmap = () => new Promise((r) => { resolve = r; });
    globalThis.OffscreenCanvas = class { constructor() { canvases++; } };
    const work = rt.readFile(1, 1, true);
    rt.dispose();
    resolve({ width: 1, height: 1, close() { closes++; } });
    await work;
    return { closes, canvases, callbacks };
  }, { closes: 1, canvases: 0, callbacks: 0 }],
  ["late frame copy cannot acquire fallback canvas", async () => {
    const rows = [];
    for (const reject of [true, false]) {
      let settle, closes = 0, canvases = 0, callbacks = 0;
      const rt = new LeanUI.Runtime({ callbackBytes() { callbacks++; } });
      globalThis.VideoFrame = class {
        constructor() { this.displayWidth = this.displayHeight = 1; this.visibleRect = { width: 1, height: 1 }; }
        copyTo() { return new Promise((ok, fail) => { settle = reject ? () => fail(new Error("unsupported")) : ok; }); }
        close() { closes++; }
      };
      globalThis.OffscreenCanvas = class { constructor() { canvases++; } };
      const query = document.querySelector;
      document.querySelector = () => ({ readyState: 2, videoWidth: 1, videoHeight: 1, paused: true, currentTime: 0 });
      try {
        const work = rt.grabFrame(1, "#video");
        rt.dispose(); settle(); await work;
        rows.push({ closes, canvases, callbacks, retained: rt.grabCanvas !== null });
      } finally { document.querySelector = query; rt.dispose(); }
    }
    return rows;
  }, [{ closes: 1, canvases: 0, callbacks: 0, retained: false }, { closes: 1, canvases: 0, callbacks: 0, retained: false }]],
  ["download click can dispose its owner", () => {
    const rt = new LeanUI.Runtime({});
    document.addEventListener("click", (e) => { e.preventDefault(); rt.dispose(); }, { capture: true, once: true });
    rt.download("probe.bin", "application/octet-stream", new Uint8Array([1, 2]));
    return { disposed: rt.disposed, timers: rt.timeouts.size, urls: rt.objectUrls.size, anchors: document.querySelectorAll("a").length };
  }, { disposed: true, timers: 0, urls: 0, anchors: 0 }],
  ["wasm startup rolls back boot and queued failures", async () => {
    const rows = [];
    // A fake Emscripten boundary exercises JS startup, not compiled-Wasm fault behavior.
    for (const failure of ["false", "throw", "queued", "disposed", "replacement"]) {
      const previous = new LeanUI.Runtime({}); LeanUI.active = previous;
      let rt, replacement, notifications = 0, reported;
      const error = new Error("boot error"), cleanupError = new Error("cleanup error");
      globalThis.LifetimeModule = async () => ({
        lengthBytesUTF8(s) { return new TextEncoder().encode(s).length; }, _malloc() { return 16n; }, stringToUTF8() {},
        _leanui_event() { throw error; },
        _leanui_boot() {
          rt = LeanUI.active;
          rt.setContainer("#app");
          rt.timeouts.add(setTimeout(() => {}, 60000));
          if (failure === "throw") {
            rt.transport.dispose = () => { throw cleanupError; };
            throw error;
          }
          if (failure === "disposed") { rt.dispose(); return 1; }
          if (failure === "queued" || failure === "replacement") {
            rt.container.addEventListener("leanui:error", () => {
              notifications++;
              if (failure === "replacement") { replacement = new LeanUI.Runtime({}); LeanUI.active = replacement; }
            }, { once: true });
            rt.send(0, 1, "queued"); return 1;
          }
          return 0;
        },
      });
      try { await LeanUI.start({ factory: "LifetimeModule", glue: "unused.js" }); } catch (e) { reported = e; }
      rows.push({ rejected: !!reported, original: failure === "throw" || failure === "queued" || failure === "replacement" ? reported === error : true,
        disposed: rt.disposed, aborted: rt.effects.signal.aborted, timers: rt.timeouts.size,
        owner: LeanUI.active === (replacement || previous), notifications });
      replacement?.dispose(); previous.dispose();
    }
    return rows;
  }, [0, 0, 1, 0, 1].map((notifications) => ({ rejected: true, original: true, disposed: true, aborted: true, timers: 0, owner: true, notifications }))],
  ["successful wasm startup drains input and releases module", async () => {
    const calls = [];
    let rt;
    globalThis.LifetimeModule = async () => ({
      lengthBytesUTF8(s) { return s.length; }, _malloc() { return 16n; }, stringToUTF8() {},
      _leanui_boot() { rt = LeanUI.active; calls.push("boot"); rt.send(0, 1, "queued"); return 1; },
      _leanui_event() { calls.push("event"); },
    });
    const returned = await LeanUI.start({ factory: "LifetimeModule", glue: "unused.js" });
    const transport = rt.transport;
    const result = { calls, same: returned === rt, active: LeanUI.active === rt, pending: rt.queue.length, busy: rt.busy };
    rt.dispose(); rt.dispose(); rt.send(0, 1, "late");
    return { ...result, released: transport.mod === null, inactive: LeanUI.active === null };
  }, { calls: ["boot", "event"], same: true, active: true, pending: 0, busy: false, released: true, inactive: true }],
  ["invalid remote mount restores previous owner", () => {
    const previous = new LeanUI.Runtime({}); LeanUI.active = previous;
    let rejected = false, calls = 0;
    globalThis.fetch = () => { calls++; throw new Error("unexpected network call"); };
    try { LeanUI.connect({ session: "test", selector: "[" }); } catch { rejected = true; }
    const result = { rejected, restored: LeanUI.active === previous, calls };
    previous.dispose(); return result;
  }, { rejected: true, restored: true, calls: 0 }],
  ["remote disposal cancels queued and late responses", async () => {
    let calls = 0, resolveResponse, aborted = false, applies = 0;
    globalThis.fetch = (_url, init) => {
      calls++; init.signal.addEventListener("abort", () => { aborted = true; });
      return new Promise((resolve) => { resolveResponse = resolve; });
    };
    const early = LeanUI.connect({ session: "early" }), earlyTransport = early.transport;
    early.dispose(); await earlyTransport.chain;
    const canceledBeforeSend = calls === 0;
    const rt = LeanUI.connect({ session: "live" }), transport = rt.transport;
    rt.apply = () => { applies++; };
    await Promise.resolve(); transport.event(1, "queued"); rt.dispose(); rt.dispose();
    resolveResponse({ status: 200, ok: true, arrayBuffer: async () => new ArrayBuffer(4) });
    await transport.chain;
    return { canceledBeforeSend, calls, aborted, applies };
  }, { canceledBeforeSend: true, calls: 1, aborted: true, applies: 0 }],
];

let failures = 0;
for (const engine of engines) {
  const browser = await pw[engine].launch({ headless: true });
  try {
    for (const [name, test, expected] of tests) {
      const page = await browser.newPage();
      try {
        await page.setContent('<base href="http://lifetime.invalid/"><div id="app"></div>');
        await page.addScriptTag({ content: runtime });
        const result = await page.evaluate(test);
        assert.deepEqual(result, expected);
        console.log(`${engine}: PASS ${name}`);
      } catch (e) { failures++; console.error(`${engine}: FAIL ${name}`, e); }
      finally { await page.close(); }
    }
  } finally { await browser.close(); }
}
assert.equal(failures, 0, `${failures} lifecycle failures`);
