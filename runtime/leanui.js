// LeanUI browser runtime: applies Lean's command buffers to the DOM, delegates events back to
// Lean, and runs effects. One transport per app: the app's wasm module in this page, or a Lean
// server driving the page over HTTP (for browsers without WebAssembly Memory64, e.g. Safari).
// The protocol is specified in docs/PROTOCOL.md; LeanUI/Testing/Dom.lean is the reference model.
(function (global) {
  "use strict";
  const NS = [null, "http://www.w3.org/2000/svg", "http://www.w3.org/1998/Math/MathML"];
  // events that do not bubble are delegated in the capture phase
  const CAPTURE = new Set(["focus", "blur", "mouseenter", "mouseleave", "load", "error", "scroll", "pointerenter", "pointerleave"]);
  const decoder = new TextDecoder();

  class Runtime {
    constructor(transport) {
      this.transport = transport;
      this.nodes = [null];
      this.names = [null];
      this.container = null;
      this.delegated = new Set();
      this.wanted = new Set();
      this.timers = new Map();
      this.urlSub = 0;
      this.busy = false;
      this.queue = [];
      this.after = [];
      this.tpl = [];
      this.stats = { flushes: 0, ops: 0, bytes: 0 };
    }

    // ---- input: events and effect results go to Lean one at a time ----
    send(kind, a, b, c) {
      if (this.crashed) return;
      if (this.busy) { this.queue.push([kind, a, b, c]); return; }
      this.busy = true;
      try {
        if (kind === 0) this.transport.event(a, b); else this.transport.callback(a, b, c);
      } catch (e) { this.crash(e); }
      finally { this.busy = false; }
      if (this.queue.length) { const [k, x, y, z] = this.queue.shift(); this.send(k, x, y, z); }
    }
    // An update that throws (in wasm: the native stack overflowed on a view nested about a
    // thousand levels deep, or memory ran out) leaves the app without its state: say so once,
    // stop calling it, and tell the page (a "leanui:error" event on the container).
    crash(e) {
      if (this.transport instanceof WasmTransport) {
        this.crashed = e;
        this.queue.length = 0;
        console.error("LeanUI: the app stopped after an error in an update; reload the page to restart it.", e);
        if (this.container) this.container.dispatchEvent(new CustomEvent("leanui:error", { bubbles: true, detail: e }));
      } else console.error("LeanUI:", e);
    }
    callback(cb, ok, payload) { this.send(1, cb, ok, payload); }

    // One real listener per event type, on the container. Listener commands can precede the
    // mount command in a buffer, so wanted types are remembered and attached once it exists.
    delegate(type) {
      this.wanted.add(type);
      if (!this.container || this.delegated.has(type)) return;
      this.delegated.add(type);
      this.container.addEventListener(type, (e) => this.onEvent(e), CAPTURE.has(type));
    }
    onEvent(e) {
      const type = e.type;
      // events that do not bubble (delegated in the capture phase) reach only their target
      const bubbles = !CAPTURE.has(type);
      for (let n = e.target; n; n = n.parentNode) {
        const hs = n.__lui;
        const h = hs && hs[type];
        if (h) {
          const [slot, payload, flags] = h;
          if (flags & 1) e.preventDefault();
          this.send(0, slot, extract(payload, n, e));
          if (flags & 2) { e.stopPropagation(); return; }
        }
        if (!bubbles || n === this.container) return;
      }
    }

    // ---- output: one command buffer per Lean update ----
    apply(bytes, opsOff, opsLen, strsOff, strsLen) {
      const w = (opsOff & 3) === 0
        ? new Uint32Array(bytes.buffer, bytes.byteOffset + opsOff, opsLen >>> 2)
        : new Uint32Array(bytes.slice(opsOff, opsOff + opsLen).buffer);
      const text = strsLen ? decoder.decode(bytes.subarray(strsOff, strsOff + strsLen)) : "";
      const N = this.nodes, names = this.names;
      const S = (i) => text.substr(w[i], w[i + 1]);
      this.stats.flushes++; this.stats.ops += w.length; this.stats.bytes += opsLen + strsLen;
      let i = 0;
      const n = w.length;
      while (i < n) {
        switch (w[i]) {
          case 1: N[w[i + 1]] = w[i + 2] ? document.createElementNS(NS[w[i + 2]], names[w[i + 3]]) : document.createElement(names[w[i + 3]]); i += 4; break;
          case 2: N[w[i + 1]] = document.createTextNode(S(i + 2)); i += 4; break;
          case 3: N[w[i + 1]].setAttribute(names[w[i + 2]], S(i + 3)); i += 5; break;
          case 4: N[w[i + 1]].removeAttribute(names[w[i + 2]]); i += 3; break;
          case 5: { const el = N[w[i + 1]], k = names[w[i + 2]], v = S(i + 3); if (el[k] !== v) el[k] = v; i += 5; break; }
          case 6: N[w[i + 1]][names[w[i + 2]]] = w[i + 3] === 1; i += 4; break;
          case 7: N[w[i + 1]][names[w[i + 2]]] = Number(S(i + 3)); i += 5; break;
          case 8: { const el = N[w[i + 1]], k = names[w[i + 2]]; el[k] = typeof el[k] === "boolean" ? false : ""; i += 3; break; }
          case 9: N[w[i + 1]].nodeValue = S(i + 2); i += 4; break;
          case 10: N[w[i + 1]].appendChild(N[w[i + 2]]); i += 3; break;
          case 11: N[w[i + 1]].insertBefore(N[w[i + 2]], N[w[i + 3]]); i += 4; break;
          case 12: N[w[i + 1]].remove(); i += 2; break;
          case 13: N[w[i + 1]].replaceWith(N[w[i + 2]]); i += 3; break;
          case 14: N[w[i + 1]] = undefined; i += 2; break;
          case 15: { const el = N[w[i + 1]], ev = names[w[i + 2]]; (el.__lui || (el.__lui = {}))[ev] = [w[i + 3], w[i + 4], w[i + 5]]; this.delegate(ev); i += 6; break; }
          case 16: { const el = N[w[i + 1]]; if (el.__lui) delete el.__lui[names[w[i + 2]]]; i += 3; break; }
          case 17: names[w[i + 1]] = S(i + 2); i += 4; break;
          case 18: { this.setContainer(S(i + 1)); this.container.replaceChildren(N[w[i + 3]]); i += 4; break; }
          case 19: { this.setContainer(S(i + 1)); this.hydrate(w[i + 3], w[i + 4]); i += 5; break; }
          case 20: i = this.template(w, i); break;
          case 21: i = this.clone(w, i); break;
          case 32: this.fetch(w[i + 1], S(i + 2), S(i + 4), S(i + 6), S(i + 8)); i += 10; break;
          case 33: { const cb = w[i + 1]; setTimeout(() => this.callback(cb, true, ""), w[i + 2]); i += 3; break; }
          case 34: { const sub = w[i + 1]; this.timers.set(sub, setInterval(() => this.callback(sub, true, ""), w[i + 2])); i += 3; break; }
          case 35: { const sub = w[i + 1]; clearInterval(this.timers.get(sub)); this.timers.delete(sub); if (this.urlSub === sub) this.urlSub = 0; i += 2; break; }
          case 36: try { localStorage.setItem(S(i + 1), S(i + 3)); } catch (e) {} i += 5; break;
          case 37: { const cb = w[i + 1]; let v = null; try { v = localStorage.getItem(S(i + 2)); } catch (e) {} queueMicrotask(() => this.callback(cb, v !== null, v ?? "")); i += 4; break; }
          case 38: try { localStorage.removeItem(S(i + 1)); } catch (e) {} i += 3; break;
          case 39: history.pushState(null, "", S(i + 1)); i += 3; break;
          case 40: history.replaceState(null, "", S(i + 1)); i += 3; break;
          case 41: this.listenUrl(w[i + 1]); i += 2; break;
          case 42: { const sel = S(i + 1); this.after.push(() => { const el = document.querySelector(sel); if (el) el.focus(); }); i += 3; break; }
          case 43: console.log(S(i + 1)); i += 3; break;
          case 44: document.title = S(i + 1); i += 3; break;
          case 45: { const cb = w[i + 1]; requestAnimationFrame((t) => this.callback(cb, true, String(Math.round(t)))); i += 2; break; }
          case 46: { const sel = S(i + 1); this.after.push(() => { const el = document.querySelector(sel); if (el) el.blur(); }); i += 3; break; }
          case 47: { const sel = S(i + 1); this.after.push(() => { const el = document.querySelector(sel); if (el) el.scrollIntoView({ block: "nearest" }); }); i += 3; break; }
          default: throw new Error("LeanUI: unknown opcode " + w[i] + " at word " + i);
        }
      }
      if (this.after.length) { const a = this.after; this.after = []; queueMicrotask(() => a.forEach((f) => f())); }
    }

    setContainer(sel) {
      const c = document.querySelector(sel);
      if (!c) throw new Error("LeanUI: no element matches " + sel);
      if (c !== this.container) { this.container = c; this.delegated.clear(); for (const t of this.wanted) this.delegate(t); }
    }

    // Adopt server-rendered nodes: handles first .. first+count-1 in pre-order, skipping the
    // markers LeanUI.Render writes (<!--|--> between texts; <!--t--> for an empty text).
    hydrate(first, count) {
      let h = first;
      const walk = (parent) => {
        for (let c = parent.firstChild; c; ) {
          const next = c.nextSibling;
          if (c.nodeType === 8) {
            if (c.data === "t") { const t = document.createTextNode(""); c.replaceWith(t); this.nodes[h++] = t; }
          } else if (c.nodeType === 1 || c.nodeType === 3) {
            this.nodes[h++] = c;
            if (c.nodeType === 1) walk(c);
          }
          c = next;
        }
      };
      walk(this.container);
      if (h - first !== count) throw new Error("LeanUI: hydration found " + (h - first) + " nodes, expected " + count + "; the server and client views differ");
    }

    // TEMPLATE tid count h1..hcount: keep a copy of the subtree rooted at h1 as mount built it,
    // whose nodes are h1..hcount in pre-order.
    template(w, i) {
      const N = this.nodes, end = i + 3 + w[i + 2], root = N[w[i + 3]], snap = root.cloneNode(true);
      // keep only the nodes Lean knows (a property such as innerHTML can add others)
      const prune = (o, s, k) => {
        for (let oc = o.firstChild, sc = s.firstChild; oc !== null; ) {
          const on = oc.nextSibling, sn = sc.nextSibling;
          if (k < end && oc === N[w[k]]) k = prune(oc, sc, k + 1); else sc.remove();
          oc = on; sc = sn;
        }
        return k;
      };
      if (prune(root, snap, i + 4) !== end) throw new Error("LeanUI: TEMPLATE " + w[i + 1] + " does not name its subtree");
      // cloneNode copies the value and checkedness of form controls (dirty flags included), which
      // a fresh mount does not have: give the copy fresh controls with the same attributes
      for (const el of snap.querySelectorAll("input, textarea")) {
        if (el.namespaceURI !== "http://www.w3.org/1999/xhtml") continue;
        const f = document.createElement(el.localName);
        for (const a of el.attributes) f.setAttributeNode(a.cloneNode());
        while (el.firstChild !== null) f.appendChild(el.firstChild);
        el.replaceWith(f);
      }
      // the pre-order walk, as moves from each node to the next: 0 to the first child, u > 0 up
      // u - 1 levels, then to the next sibling (a clone is walked without probing for children)
      const moves = new Uint8Array(w[i + 2] - 1);
      for (let n = snap, k = 0; k < moves.length; k++) {
        if (n.firstChild !== null) { n = n.firstChild; continue; }
        let u = 1;
        while (n.nextSibling === null) { n = n.parentNode; u++; }
        n = n.nextSibling; moves[k] = u;
      }
      this.tpl[w[i + 1]] = { snap, moves };
      return end;
    }
    // CLONE tid count h1..hcount: a copy of template tid, whose nodes become h1..hcount in pre-order
    // (the order mount allocates handles in).
    clone(w, i) {
      const N = this.nodes, t = this.tpl[w[i + 1]], moves = t.moves, m = moves.length;
      let n = t.snap.cloneNode(true), k = i + 3;
      N[w[k++]] = n;
      for (let j = 0; j < m; j++) {
        const u = moves[j];
        if (u === 0) n = n.firstChild;
        else { for (let q = 1; q < u; q++) n = n.parentNode; n = n.nextSibling; }
        N[w[k++]] = n;
      }
      return k;
    }

    fetch(cb, method, url, body, headerLines) {
      const headers = {};
      for (const line of headerLines.split("\n")) { const k = line.indexOf(": "); if (k > 0) headers[line.slice(0, k)] = line.slice(k + 2); }
      const init = { method, headers };
      if (method !== "GET" && method !== "HEAD") init.body = body;
      fetch(url, init)
        .then((r) => r.text().then((t) => this.callback(cb, r.ok, r.status + "\n" + t)))
        .catch(() => this.callback(cb, false, "0\n"));
    }

    listenUrl(sub) {
      this.urlSub = sub;
      if (this.urlListening) return;
      this.urlListening = true;
      addEventListener("popstate", () => { if (this.urlSub) this.callback(this.urlSub, true, location.pathname + location.search + location.hash); });
      document.addEventListener("click", (e) => {
        const a = e.target.closest && e.target.closest("a[data-link]");
        if (!a || !this.urlSub || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey) return;
        e.preventDefault();
        history.pushState(null, "", a.getAttribute("href"));
        this.callback(this.urlSub, true, location.pathname + location.search + location.hash);
      });
    }
  }

  function extract(kind, el, e) {
    switch (kind) {
      case 1: return String(el.value ?? "");
      case 2: return el.checked ? "true" : "false";
      case 3: return e.key || "";
      case 4: {
        const form = el instanceof HTMLFormElement ? el : el.form;
        if (!form) return "";
        const out = []; for (const [k, v] of new FormData(form)) out.push(k + "=" + (typeof v === "string" ? v : v.name)); return out.join("\n");
      }
      default: return "";
    }
  }

  // ---- transports ----
  // wasm64 exports take pointers and sizes as 64-bit integers (BigInt); malloc returns a Number
  const ptr = (p) => (typeof p === "bigint" ? p : BigInt(p));
  // A string as malloc'd UTF-8 bytes and their length: the length travels separately, so a
  // payload may contain U+0000 (a C string would end there). C frees the bytes.
  function utf8(mod, s) {
    const n = mod.lengthBytesUTF8(s), p = mod._malloc(ptr(n + 1));
    mod.stringToUTF8(s, Number(p), n + 1);
    return [ptr(p), ptr(n)];
  }

  class WasmTransport {
    constructor(mod) { this.mod = mod; }
    event(slot, payload) { this.mod._leanui_event(slot, ...utf8(this.mod, payload)); }
    callback(cb, ok, payload) { this.mod._leanui_callback(cb, ok ? 1 : 0, ...utf8(this.mod, payload)); }
  }

  // Server-driven: Lean runs natively on the server; every event is a POST whose response is the
  // command buffer ([u32 opsBytes][ops][strs]). Requests are serialised to keep event order.
  class RemoteTransport {
    constructor(endpoint, session, runtime) { this.endpoint = endpoint; this.session = session; this.rt = runtime; this.chain = Promise.resolve(); }
    post(body) {
      this.chain = this.chain.then(() => fetch(this.endpoint + "/" + this.session, { method: "POST", body, headers: { "content-type": "text/plain" } }))
        .then(async (r) => {
          const buf = await r.arrayBuffer();
          if (r.status === 410) { this.expired(); return; }
          // a LeanUI server answers errors with a buffer that logs the reason: apply it either way
          if (!r.ok) console.error("LeanUI remote: HTTP " + r.status);
          if (buf.byteLength) applyEncoded(this.rt, new Uint8Array(buf));
        })
        .catch((e) => console.error("LeanUI remote:", e));
    }
    // The server forgot this session (it expired): reload once for a fresh one, never in a loop.
    expired() {
      const key = "leanui.reloadedAt";
      let last = 0;
      try { last = +sessionStorage.getItem(key) || 0; } catch (e) {}
      if (Date.now() - last > 10000) {
        try { sessionStorage.setItem(key, String(Date.now())); } catch (e) {}
        console.warn("LeanUI remote: the session expired; reloading");
        location.reload();
      } else console.error("LeanUI remote: the session expired again right after a reload; not reloading");
    }
    event(slot, payload) { this.post("e\n" + slot + "\n" + payload); }
    callback(cb, ok, payload) { this.post("c\n" + cb + "\n" + (ok ? 1 : 0) + "\n" + payload); }
  }

  function applyEncoded(rt, bytes) {
    const opsLen = bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24);
    const copy = new Uint8Array(bytes.length); copy.set(bytes);
    rt.apply(copy, 4, opsLen, 4 + opsLen, copy.length - 4 - opsLen);
  }

  // Memory64 + legacy exception handling, the two features a LeanUI wasm module needs.
  function supported() {
    try {
      const m64 = new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0, 5, 3, 1, 4, 0]); // (memory i64 0)
      return typeof WebAssembly === "object" && WebAssembly.validate(m64);
    } catch (e) { return false; }
  }

  function loadScript(src) {
    return new Promise((ok, fail) => { const s = document.createElement("script"); s.src = src; s.onload = ok; s.onerror = () => fail(new Error("cannot load " + src)); document.head.appendChild(s); });
  }

  const LeanUI = {
    supported,
    /** Run an app's wasm module in this page. `glue` is its Emscripten script, `factory` the
        global it defines (default `LeanUIApp`). */
    async start({ glue = "app.js", factory = "LeanUIApp", selector = "#app", flags = "", hydrate = false } = {}) {
      const t0 = performance.now();
      if (!global[factory]) await loadScript(glue);
      const base = new URL(glue, document.baseURI).href.replace(/[^/]*$/, "");
      const mod = await global[factory]({ locateFile: (p) => base + p });
      const rt = new Runtime(new WasmTransport(mod));
      LeanUI.active = rt;
      rt.busy = true;
      let ok;
      try { ok = mod._leanui_boot(...utf8(mod, flags), ...utf8(mod, selector), hydrate ? 1 : 0); }
      finally { rt.busy = false; }
      if (!ok) throw new Error("LeanUI: the app failed to start (see the console)");
      if (rt.queue.length) { const [k, a, b, c] = rt.queue.shift(); rt.send(k, a, b, c); }
      rt.bootMs = performance.now() - t0;
      return rt;
    },
    /** Let a Lean server drive this page (the server rendered it and opened `session`). */
    connect({ endpoint = "/leanui", session, selector = "#app" } = {}) {
      const rt = new Runtime(null);
      rt.transport = new RemoteTransport(endpoint, session, rt);
      LeanUI.active = rt;
      rt.setContainer(selector);
      rt.transport.post("h");   // hydrate: the server answers with the claim + listener commands
      return rt;
    },
    /** In-page wasm when the browser supports it, the server otherwise. */
    boot(opts) { return supported() || !opts.session ? LeanUI.start(opts) : Promise.resolve(LeanUI.connect(opts)); },
    // called by the wasm module (runtime/leanui_wasm.c) once per update
    __flush(heap, ops, opsLen, strs, strsLen) { const rt = LeanUI.active; rt.stats.heapBytes = heap.byteLength; rt.apply(heap, ops, opsLen, strs, strsLen); },
    Runtime,
  };
  global.LeanUI = LeanUI;
})(globalThis);
