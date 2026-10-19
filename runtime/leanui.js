// LeanUI browser runtime: applies Lean's command buffers to the DOM, delegates events back to
// Lean, and runs effects. One transport per app: the app's wasm module in this page, or a Lean
// server driving the page over HTTP (for browsers without WebAssembly Memory64, e.g. Safari).
// The protocol is specified in docs/PROTOCOL.md; LeanUI/Testing/Dom.lean is the reference model.
(function (global) {
  "use strict";
  const NS = [null, "http://www.w3.org/2000/svg", "http://www.w3.org/1998/Math/MathML"];
  const HTML = "http://www.w3.org/1999/xhtml";
  // events that do not bubble are delegated in the capture phase
  const CAPTURE = new Set(["focus", "blur", "mouseenter", "mouseleave", "load", "error", "scroll", "pointerenter", "pointerleave"]);
  // events whose default a listener may prevent only if it is not passive (browsers make some
  // wheel and touch listeners passive by default)
  const ACTIVE = new Set(["wheel", "touchstart", "touchmove"]);
  // KEYS_LISTEN: keys that are only modifiers, and the inputs that take no text (keys pressed
  // while one of them has focus are reported)
  const MODIFIER_KEYS = new Set(["Control", "Shift", "Alt", "Meta", "AltGraph", "CapsLock", "Fn", "FnLock", "Hyper", "Super", "Symbol", "SymbolLock", "NumLock", "ScrollLock", "OS"]);
  const NOT_TEXT = new Set(["checkbox", "radio", "range", "button", "submit", "reset", "file", "color", "image"]);
  const decoder = new TextDecoder();

  class Runtime {
    constructor(transport) {
      this.transport = transport;
      this.nodes = [null];
      // per handle: 0 an HTML element, 1/2 an SVG/MathML element, 3 a text node or a freed
      // handle (SET_ATTR uses `className` for "class" on HTML elements only: SVGElement's
      // className is read-only). Every command that binds a handle records its kind; FREE
      // resets it, so a handle bound without one falls back to setAttribute.
      this.kinds = [3];
      this.names = [null];
      // per name id: true if the name is "class"
      this.isClass = [false];
      this.container = null;
      this.delegated = new Set();
      this.wanted = new Set();
      this.timers = new Map();
      this.urlSub = 0;
      this.busy = false;
      this.queue = [];
      this.after = [];
      // commands that run at the end of the buffer that carries them (PUT_IMAGE: after the DOM
      // changes, while the pixels it reads are still valid)
      this.late = [];
      // per blob index of the next buffer: [address, length] in wasm memory (LeanUI.__blob)
      this.blobs = [];
      // files the app was given (Payload.files), by id; the 64 most recent are kept
      this.files = new Map();
      this.fileSeq = 1;
      this.keysSub = 0;
      this.tpl = [];
      this.stats = { flushes: 0, ops: 0, bytes: 0 };
    }

    // ---- input: events and effect results go to Lean one at a time ----
    send(kind, a, b, c, d) {
      if (this.crashed) return;
      if (this.busy) { this.queue.push([kind, a, b, c, d]); return; }
      this.busy = true;
      try {
        if (kind === 0) this.transport.event(a, b);
        else if (kind === 1) this.transport.callback(a, b, c);
        else this.transport.callbackBytes(a, b, c, d);
      } catch (e) { this.crash(e); }
      finally { this.busy = false; }
      if (this.queue.length) { const [k, x, y, z, u] = this.queue.shift(); this.send(k, x, y, z, u); }
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
    // an effect's result with bytes (a Uint8Array or Uint8ClampedArray; null for none)
    callbackBytes(cb, ok, payload, bytes) { this.send(2, cb, ok, payload, bytes || new Uint8Array(0)); }

    // One real listener per event type, on the container. Listener commands can precede the
    // mount command in a buffer, so wanted types are remembered and attached once it exists.
    delegate(type) {
      this.wanted.add(type);
      if (!this.container || this.delegated.has(type)) return;
      this.delegated.add(type);
      const opts = { capture: CAPTURE.has(type) };
      if (ACTIVE.has(type)) opts.passive = false;
      this.container.addEventListener(type, (e) => this.onEvent(e), opts);
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
          // flag 4: capture the pointer, so moves and the pointerup keep coming to this element
          if (flags & 4 && type === "pointerdown" && n.setPointerCapture) try { n.setPointerCapture(e.pointerId); } catch (x) {}
          this.send(0, slot, extract(payload, n, e, this));
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
      const N = this.nodes, K = this.kinds, names = this.names, isClass = this.isClass;
      // the string operand at word i
      const S = (i) => text.substr(w[i], w[i + 1]);
      this.stats.flushes++; this.stats.ops += w.length; this.stats.bytes += opsLen + strsLen;
      let i = 0;
      const n = w.length;
      while (i < n) {
        switch (w[i]) {
          case 1: { const h = w[i + 1], ns = w[i + 2]; N[h] = ns ? document.createElementNS(NS[ns], names[w[i + 3]]) : document.createElement(names[w[i + 3]]); K[h] = ns; i += 4; break; }
          case 2: { const h = w[i + 1]; N[h] = document.createTextNode(S(i + 2)); K[h] = 3; i += 4; break; }
          case 3: {
            // On an HTML element, `className = v` is the same attribute write as
            // setAttribute("class", v), and cheaper (no name to look up): 7-9% of applying a
            // create-1,000-rows buffer before templates (tests/browser/apply-bench.mjs). A CLONE's
            // copy brings its template's classes, so it now pays on subtrees mounted node by node,
            // a copy whose class differs from its template's, and class changes.
            const h = w[i + 1], nm = w[i + 2], v = S(i + 3);
            if (isClass[nm] === true && K[h] === 0) N[h].className = v; else N[h].setAttribute(names[nm], v);
            i += 5; break;
          }
          case 4: N[w[i + 1]].removeAttribute(names[w[i + 2]]); i += 3; break;
          case 5: { const el = N[w[i + 1]], k = names[w[i + 2]], v = S(i + 3); if (el[k] !== v) el[k] = v; i += 5; break; }
          case 6: N[w[i + 1]][names[w[i + 2]]] = w[i + 3] === 1; i += 4; break;
          case 7: N[w[i + 1]][names[w[i + 2]]] = Number(S(i + 3)); i += 5; break;
          case 8: { const el = N[w[i + 1]], k = names[w[i + 2]]; el[k] = typeof el[k] === "boolean" ? false : ""; i += 3; break; }
          case 9: N[w[i + 1]].nodeValue = S(i + 2); i += 4; break;
          case 10: N[w[i + 1]].appendChild(N[w[i + 2]]); i += 3; break;
          case 11: N[w[i + 1]].insertBefore(N[w[i + 2]], N[w[i + 3]]); i += 4; break;
          case 12: {
            // A run of REMOVE (and FREE) commands that detaches every child of one parent, first
            // to last in order (clearing or replacing a list), becomes one replaceChildren():
            // the same DOM, without a removal per child (4-5% of applying a clear). Handles are
            // freed in order as the run is read and no other command runs in between, so no
            // command can tell. Page code can: a MutationObserver sees one record instead of one
            // per child, and custom elements' disconnectedCallbacks (replaceChildren is a single
            // [CEReactions] call) all run after the last removal instead of after each one, so
            // each sees its old parent already empty (tests/browser/apply-semantics.mjs).
            const el = N[w[i + 1]];
            i += 2;
            const p = el.parentNode;
            if (p === null || (w[i] !== 12 && w[i] !== 14) || el !== p.firstChild) { el.remove(); break; }
            let last = el, next = el.nextSibling;
            while (i < n) {
              const op = w[i];
              if (op === 14) { N[w[i + 1]] = undefined; K[w[i + 1]] = 3; i += 2; }
              else if (op === 12 && next !== null && N[w[i + 1]] === next) { last = next; next = next.nextSibling; i += 2; }
              else break;
            }
            if (next === null) p.replaceChildren();
            else for (let x = el; ; ) { const nx = x.nextSibling; x.remove(); if (x === last) break; x = nx; }
            break;
          }
          case 13: N[w[i + 1]].replaceWith(N[w[i + 2]]); i += 3; break;
          case 14: N[w[i + 1]] = undefined; K[w[i + 1]] = 3; i += 2; break;
          case 15: { const el = N[w[i + 1]], ev = names[w[i + 2]]; (el.__lui || (el.__lui = {}))[ev] = [w[i + 3], w[i + 4], w[i + 5]]; this.delegate(ev); i += 6; break; }
          case 16: { const el = N[w[i + 1]]; if (el.__lui) delete el.__lui[names[w[i + 2]]]; i += 3; break; }
          case 17: { const s = S(i + 2); names[w[i + 1]] = s; isClass[w[i + 1]] = s === "class"; i += 4; break; }
          case 18: { this.setContainer(S(i + 1)); this.container.replaceChildren(N[w[i + 3]]); i += 4; break; }
          case 19: { this.setContainer(S(i + 1)); this.hydrate(w[i + 3], w[i + 4]); i += 5; break; }
          case 20: i = this.template(w, i); break;
          case 21: i = this.clone(w, i); break;
          case 32: this.fetch(w[i + 1], S(i + 2), S(i + 4), S(i + 6), S(i + 8)); i += 10; break;
          case 33: { const cb = w[i + 1]; setTimeout(() => this.callback(cb, true, ""), w[i + 2]); i += 3; break; }
          case 34: { const sub = w[i + 1]; this.timers.set(sub, setInterval(() => this.callback(sub, true, ""), w[i + 2])); i += 3; break; }
          case 35: { const sub = w[i + 1]; clearInterval(this.timers.get(sub)); this.timers.delete(sub); if (this.urlSub === sub) this.urlSub = 0; if (this.keysSub === sub) this.keysSub = 0; i += 2; break; }
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
          case 48: {
            const sel = S(i + 1), b = this.blob(bytes, w[i + 3]), iw = w[i + 4], ih = w[i + 5], x = w[i + 6], y = w[i + 7], dw = w[i + 8], dh = w[i + 9];
            this.late.push(() => this.putImage(sel, b, iw, ih, x, y, dw, dh)); i += 10; break;
          }
          case 49: this.readFile(w[i + 1], w[i + 2], false); i += 3; break;
          case 50: this.readFile(w[i + 1], w[i + 2], true); i += 3; break;
          case 51: this.download(S(i + 1), S(i + 3), this.blob(bytes, w[i + 5])); i += 6; break;
          case 52: this.listenKeys(w[i + 1]); i += 2; break;
          case 53: this.grabFrame(w[i + 1], S(i + 2)); i += 4; break;
          case 54: { const cb = w[i + 1], f = this.files.get(w[i + 2]); const u = f ? URL.createObjectURL(f) : ""; queueMicrotask(() => this.callback(cb, !!f, u)); i += 3; break; }
          default: throw new Error("LeanUI: unknown opcode " + w[i] + " at word " + i);
        }
      }
      if (this.late.length) { const a = this.late; this.late = []; a.forEach((f) => f()); }
      this.blobs.length = 0;
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
            if (c.data === "t") { const t = document.createTextNode(""); c.replaceWith(t); this.kinds[h] = 3; this.nodes[h++] = t; }
          } else if (c.nodeType === 1 || c.nodeType === 3) {
            this.kinds[h] = c.nodeType === 3 ? 3 : c.namespaceURI === HTML ? 0 : 1;
            this.nodes[h++] = c;
            if (c.nodeType === 1) walk(c);
          }
          c = next;
        }
      };
      walk(this.container);
      if (h - first !== count) throw new Error("LeanUI: hydration found " + (h - first) + " nodes, expected " + count + "; the server and client views differ");
    }

    // TEMPLATE tid count h1..hcount: keep a copy of the subtree rooted at h1, whose nodes are
    // h1..hcount in pre-order (Lean sends it before any property or listener touches the subtree).
    template(w, i) {
      const tid = w[i + 1], count = w[i + 2], snap = this.nodes[w[i + 3]].cloneNode(true), moves = [];
      // each node's kind in pre-order (as in this.kinds: 0 HTML element, 1 other element, 3 text),
      // copied to the clone's handles so class writes keep their fast path
      const kind = (n) => (n.nodeType === 3 ? 3 : n.namespaceURI === HTML ? 0 : 1), kinds = [kind(snap)];
      // the pre-order walk, as moves from each node to the next: 0 to the first child, u > 0 up
      // u - 1 levels, then to the next sibling (a clone is walked without probing for children)
      for (let n = snap; ; ) {
        if (n.firstChild !== null) { n = n.firstChild; moves.push(0); kinds.push(kind(n)); continue; }
        let u = 1;
        while (n !== snap && n.nextSibling === null) { n = n.parentNode; u++; }
        if (n === snap) break;
        n = n.nextSibling; moves.push(u); kinds.push(kind(n));
      }
      if (moves.length !== count - 1) throw new Error("LeanUI: TEMPLATE " + tid + " names " + count + " nodes, its subtree has " + (moves.length + 1));
      this.tpl[tid] = { snap, moves: Uint8Array.from(moves), kinds: Uint8Array.from(kinds) };
      return i + 3 + count;
    }
    // CLONE tid count h1..hcount: a copy of template tid, whose nodes become h1..hcount in pre-order
    // (the order mount allocates handles in).
    clone(w, i) {
      const N = this.nodes, K = this.kinds, t = this.tpl[w[i + 1]], moves = t.moves, kinds = t.kinds, m = moves.length;
      let n = t.snap.cloneNode(true), k = i + 3;
      K[w[k]] = kinds[0]; N[w[k++]] = n;
      for (let j = 0; j < m; j++) {
        const u = moves[j];
        if (u === 0) n = n.firstChild;
        else { for (let q = 1; q < u; q++) n = n.parentNode; n = n.nextSibling; }
        K[w[k]] = kinds[j + 1]; N[w[k++]] = n;
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

    // ---- pixels, files, keys ----
    // Blob k of the buffer being applied, as a view of wasm memory (read it before returning to
    // Lean, which may then free or reuse the bytes); null without one (a server-driven page).
    blob(bytes, k) {
      const b = this.blobs[k];
      return b ? new Uint8ClampedArray(bytes.buffer, bytes.byteOffset + b[0], b[1]) : null;
    }
    noBytes(what) {
      if (!this.warnedBytes) { this.warnedBytes = true; console.warn("LeanUI: " + what + " needs the in-page (wasm) host; ignored"); }
    }
    // A mistake here (a bitmap whose size does not match its bytes, a bad selector, a canvas with
    // another kind of context) is logged, not thrown: it would otherwise unwind through the wasm
    // call and stop the app.
    putImage(sel, b, iw, ih, x, y, dw, dh) {
      if (!b) return this.noBytes("PUT_IMAGE");
      try {
        if (b.length !== iw * ih * 4) throw new Error("a " + iw + "x" + ih + " bitmap with " + b.length + " bytes");
        const c = document.querySelector(sel);
        if (!c || !c.getContext || dw === 0 || dh === 0) return;
        const ctx = c.__lui2d || (c.__lui2d = c.getContext("2d"));
        if (!ctx) throw new Error(sel + " has no 2D context");
        // ImageData wraps the view (no copy); putImageData copies the dirty rectangle into the canvas
        ctx.putImageData(new ImageData(b, iw, ih), 0, 0, x, y, dw, dh);
      } catch (e) { console.error("LeanUI: PUT_IMAGE " + sel + ":", e); }
    }
    download(name, type, b) {
      if (!b) return this.noBytes("DOWNLOAD");
      const url = URL.createObjectURL(new Blob([b], { type }));   // Blob copies the bytes now
      const a = document.createElement("a");
      a.href = url; a.download = name; a.style.display = "none";
      document.body.appendChild(a); a.click(); a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 30000);
    }
    keepFiles(list) {
      const out = [];
      for (const f of list) {
        const id = this.fileSeq++;
        this.files.set(id, f);
        if (this.files.size > 64) this.files.delete(this.files.keys().next().value);
        // a tab or newline in a name would break the lines: they become spaces
        out.push(id + "\t" + f.size + "\t" + f.type + "\t" + f.name.replace(/[\t\r\n]/g, " "));
      }
      return out.join("\n");
    }
    // FILE_READ (the file's bytes) and IMAGE_DECODE (RGBA pixels, payload "width height")
    async readFile(cb, id, decode) {
      const f = this.files.get(id);
      try {
        if (!f) throw new Error("no file " + id);
        if (!decode) return this.callbackBytes(cb, true, "", new Uint8Array(await f.arrayBuffer()));
        const bmp = await createImageBitmap(f, { premultiplyAlpha: "none", colorSpaceConversion: "none" });
        const iw = bmp.width, ih = bmp.height;
        const c = typeof OffscreenCanvas === "function" ? new OffscreenCanvas(iw, ih) : Object.assign(document.createElement("canvas"), { width: iw, height: ih });
        const ctx = c.getContext("2d", { willReadFrequently: true });
        ctx.drawImage(bmp, 0, 0);
        bmp.close();
        this.callbackBytes(cb, true, iw + " " + ih, ctx.getImageData(0, 0, iw, ih).data);
      } catch (e) { this.callbackBytes(cb, false, String((e && e.message) || e), null); }
    }
    // FRAME_GRAB: the frame a <video> shows now, as RGBA, payload "width height timeMs". While the
    // video plays, the time is the presented frame's media time, which requestVideoFrameCallback
    // reports (VideoFrame's timestamp is 0 in Firefox; currentTime moves between frames); while it
    // is paused (or without that callback), currentTime, which then names the frame shown.
    // WebCodecs' VideoFrame converts to RGBA; a 2D canvas draws the frame where it cannot.
    async grabFrame(cb, sel) {
      let f = null;
      try {
        const v = document.querySelector(sel);
        if (!v || !(v.readyState >= 2) || !v.videoWidth) throw new Error("no video frame");
        if (v.requestVideoFrameCallback && v.__leanuiFrameMs === undefined) {
          v.__leanuiFrameMs = -1;
          const seen = (now, md) => { v.__leanuiFrameMs = Math.round(md.mediaTime * 1000); v.requestVideoFrameCallback(seen); };
          v.requestVideoFrameCallback(seen);
        }
        const t = !v.paused && v.__leanuiFrameMs >= 0 ? v.__leanuiFrameMs : Math.round(v.currentTime * 1000);
        if (typeof VideoFrame === "function") { try { f = new VideoFrame(v); } catch (e) { f = null; } }
        let w = f ? f.displayWidth : v.videoWidth, h = f ? f.displayHeight : v.videoHeight, px = null;
        if (f && f.visibleRect.width === w && f.visibleRect.height === h) {
          try { const buf = new Uint8Array(4 * w * h); await f.copyTo(buf, { format: "RGBA" }); px = buf; } catch (e) { px = null; }
        }
        if (!px) {
          const c = this.grabCanvas || (this.grabCanvas = new OffscreenCanvas(w, h));
          if (c.width !== w || c.height !== h) { c.width = w; c.height = h; }
          const ctx = c.getContext("2d", { willReadFrequently: true });
          ctx.drawImage(f || v, 0, 0, w, h);
          px = ctx.getImageData(0, 0, w, h).data;
        }
        this.callbackBytes(cb, true, w + " " + h + " " + t, px);
      } catch (e) { this.callbackBytes(cb, false, String((e && e.message) || e), null); }
      finally { if (f) f.close(); }
    }
    listenKeys(sub) {
      this.keysSub = sub;
      if (this.keysListening) return;
      this.keysListening = true;
      document.addEventListener("keydown", (e) => {
        const t = e.composedPath ? e.composedPath()[0] : e.target, k = e.key;
        if (!this.keysSub || e.isComposing || MODIFIER_KEYS.has(k)) return;
        if (t && (t.isContentEditable || t.tagName === "TEXTAREA" || t.tagName === "SELECT" || (t.tagName === "INPUT" && !NOT_TEXT.has(t.type)))) return;
        this.callback(this.keysSub, true, (e.ctrlKey ? "Ctrl+" : "") + (e.altKey ? "Alt+" : "") + (e.shiftKey ? "Shift+" : "") + (e.metaKey ? "Meta+" : "") + k);
      });
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

  // a number as Payload.pointer writes it: at most two decimals, never an exponent
  const num = (v) => String(Math.round((+v || 0) * 100) / 100);

  function extract(kind, el, e, rt) {
    switch (kind) {
      case 1: return String(el.value ?? "");
      case 2: return el.checked ? "true" : "false";
      case 3: return e.key || "";
      case 4: {
        const form = el instanceof HTMLFormElement ? el : el.form;
        if (!form) return "";
        const out = []; for (const [k, v] of new FormData(form)) out.push(k + "=" + (typeof v === "string" ? v : v.name)); return out.join("\n");
      }
      case 5: {
        const dt = e.dataTransfer, list = dt && dt.files && dt.files.length ? dt.files : el.files;
        return list ? rt.keepFiles(list) : "";
      }
      case 6: {
        const r = el.getBoundingClientRect();
        let dx = 0, dy = 0;
        if (e.type === "wheel") { const k = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? r.height : 1; dx = e.deltaX * k; dy = e.deltaY * k; }
        const mods = (e.shiftKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) | (e.altKey ? 4 : 0) | (e.metaKey ? 8 : 0);
        return num((e.clientX ?? 0) - r.left) + " " + num((e.clientY ?? 0) - r.top) + " " + num(r.width) + " " + num(r.height) + " " +
          (e.buttons | 0) + " " + mods + " " + (e.pointerId | 0) + " " + num(e.pressure ?? 0) + " " + num(dx) + " " + num(dy) + " " +
          num(e.clientX ?? 0) + " " + num(e.clientY ?? 0);
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
    // the bytes are written straight into a Lean ByteArray, which Lean then owns
    callbackBytes(cb, ok, payload, bytes) {
      const mod = this.mod, obj = mod._leanui_bytes_alloc(ptr(bytes.length));
      if (!obj || Number(obj) === 0) return this.callback(cb, false, "not enough memory for " + bytes.length + " bytes");
      mod.HEAPU8.set(bytes, Number(mod._leanui_bytes_data(obj)));   // HEAPU8 after the allocation: memory may have grown
      mod._leanui_callback_bytes(cb, ok ? 1 : 0, ...utf8(mod, payload), ptr(obj));
    }
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
    // bytes do not travel to a server: the result arrives as a failure
    callbackBytes(cb) { this.callback(cb, false, "bytes need the in-page (wasm) host"); }
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
      if (rt.queue.length) { const [k, a, b, c, d] = rt.queue.shift(); rt.send(k, a, b, c, d); }
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
    // called by the wasm module before a flush whose commands carry byte arrays
    __blob(k, p, len) { LeanUI.active.blobs[k] = [p, len]; },
    Runtime,
  };
  global.LeanUI = LeanUI;
})(globalThis);
