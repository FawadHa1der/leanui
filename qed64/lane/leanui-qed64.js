// LeanUI on Lean's own interpreter in QED64's wasm64 Lean (qed64/README.md): the app runs in a
// Worker (lane/qed64.worker.js, lean.wasm running `lean --run`), and its updates are applied here
// with the DOM code of leanui.js, which must be loaded first. Like leanui.js's RemoteTransport it is
// asynchronous: a message goes to the Worker at once and its updates come later, in order (Lean
// reads its messages one at a time).
(function (global) {
  "use strict";
  const LeanUI = global.LeanUI;
  const enc = new TextEncoder();
  const now = () => performance.now();
  const median = (a) => { const s = a.slice().sort((x, y) => x - y); return s[s.length >> 1]; };

  class QedTransport {
    constructor(worker, rt) {
      this.worker = worker; this.rt = rt;
      this.out = 0;               // messages sent and not answered yet
      this.waiters = []; this.dead = null;
      // since the mount: the replies, Lean's own time in them, the Worker's (from a message
      // reaching it to its reply leaving), applying them here, and the replies held up
      this.totals = { replies: 0, leanMs: 0, workerMs: 0, applyMs: 0, stalls: 0 };
    }
    post(m, transfer) { if (this.dead) return; this.out++; this.worker.postMessage(m, transfer || []); }
    send(head, payload) { const body = enc.encode(payload); this.post({ type: "msg", head, body }, [body.buffer]); }
    event(slot, payload) { this.send("e " + slot, payload); }
    callback(cb, ok, payload) { this.send("c " + cb + " " + (ok ? 1 : 0), payload); }
    // effects that answer with bytes (files, images) need the wasm64 host
    callbackBytes(cb) { this.callback(cb, false, "bytes need the wasm64 host"); }
    ping() { this.post({ type: "ping" }); }
    // each update is [u32 opsBytes][ops][strs] in a buffer of its own
    apply(updates) {
      for (const b of updates) {
        const u = new Uint8Array(b), opsLen = (u[0] | (u[1] << 8) | (u[2] << 16) | (u[3] << 24)) >>> 0;
        this.rt.apply(u, 4, opsLen, 4 + opsLen, u.length - 4 - opsLen);
      }
    }
    onReply(m) {
      if (this.dead) return;
      const t0 = now();
      try { this.apply(m.updates); } catch (e) { return this.die(e); }
      const t = this.totals;
      t.replies++; t.leanMs += m.leanNs / 1e6; t.workerMs += m.workerMs; t.applyMs += now() - t0; if (m.stall) t.stalls++;
      if (m.errors.length) console.warn("LeanUI (QED64): the host could not read a message:", m.errors.join("; "));
      // idle once nothing is outstanding after the microtasks this reply queued: an effect it
      // started may send its result from one
      if (--this.out === 0) queueMicrotask(() => { if (!this.out && !this.dead) this.settle(null); });
    }
    settle(e) { const w = this.waiters; this.waiters = []; for (const [ok, no] of w) e ? no(e) : ok(); }
    /** A promise that resolves once every message sent so far has been answered and applied, and
        rejects if the app has stopped. */
    idle() { return this.dead ? Promise.reject(this.dead) : this.out ? new Promise((ok, no) => this.waiters.push([ok, no])) : Promise.resolve(); }
    // Lean stopped (it exited, lean.wasm aborted, or an update could not be applied): say so once,
    // and tell the page (a "leanui:error" event on the container)
    die(e) {
      if (this.dead) return;
      this.dead = e;
      this.worker.terminate();     // its memory and its pthreads' go with it
      console.error("LeanUI (QED64): the app stopped:", e);
      const c = this.rt.container;
      if (c) c.dispatchEvent(new CustomEvent("leanui:error", { bubbles: true, detail: e }));
      this.settle(e);
    }
  }

  const memory64 = () => { try { return WebAssembly.validate(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0, 5, 3, 1, 4, 0])); } catch (e) { return false; } };
  const MB = (n) => (n / 1e6).toFixed(1);

  const LeanUIQed64 = {
    /** Run the app that `config` describes (`qed64.json`, written by qed64/build.sh) in a Worker,
        mounted at `selector`. Resolves once it is mounted, with the Runtime; its transport's `lane`
        holds what the race reads (bench/race/lanes.mjs: window.__lane). Until the mount, the
        container shows how far the start has got. */
    async start({ config = "qed64.json", selector = "#app", flags = "" } = {}) {
      const t0 = now();
      if (!memory64()) throw new Error("needs WebAssembly Memory64");
      if (!global.crossOriginIsolated) throw new Error("needs a cross-origin isolated page (lean.wasm's threads share memory)");
      const url = new URL(config, document.baseURI);
      const res = await fetch(url);
      if (!res.ok) throw new Error("cannot load " + url + ": HTTP " + res.status);
      const cfg = await res.json();
      const file = (f) => new URL(f, new URL(cfg.rt, url)).href;
      const rt = new LeanUI.Runtime(null);
      LeanUI.active = rt;
      const box = document.querySelector(selector);
      const say = (s) => { if (box && !rt.container) box.textContent = "Lean's interpreter on QED64: " + s + "…"; };
      const worker = new Worker(file(cfg.worker));
      const tr = new QedTransport(worker, rt);
      rt.transport = tr;
      // the start's milestones, on this page's clock (the Worker's are moved onto it)
      const at = {};
      let bytes = 0;
      say("downloading lean.wasm and the snapshot");
      const mount = new Promise((ok, no) => {
        const fail = (err) => { tr.die(err); no(err); };
        worker.onmessage = (e) => {
          const m = e.data;
          if (m.type === "reply" && !m.mount) tr.onReply(m);
          else if (m.type === "reply") {
            rt.busy = true;
            try { tr.apply(m.updates); } catch (err) { return fail(err); } finally { rt.busy = false; }
            at.applied = now(); bytes = m.bytes; ok();
          } else if (m.type === "phase") {
            at[m.name] = m.at - performance.timeOrigin;
            if (m.name !== "mounted") say(m.name === "downloaded" ? "starting lean.wasm" : "Lean is loading the snapshot and starting the app");
          } else if (m.type === "progress" && !at.downloaded) say(`downloading lean.wasm and the snapshot (the snapshot: ${MB(m.got)}${m.total ? " of " + MB(m.total) : ""} MB)`);
          else if (m.type === "stopped") fail(new Error(m.message));
        };
        worker.onerror = (e) => { e.preventDefault(); fail(new Error("the Worker failed: " + (e.message || "(no message)"))); };
      });
      worker.postMessage({ type: "boot", leanJs: file(cfg.leanJs), leanWasm: file(cfg.leanWasm), core: file(cfg.core),
        snapshot: file(cfg.snapshot), snapshotBytes: cfg.snapshotBytes, snapshotDeps: file(cfg.snapshotDeps), runFile: file(cfg.runFile),
        app: cfg.app, selector, flags, pool: cfg.pool });
      await mount;
      if (rt.queue.length) { const [k, a, b, c, d] = rt.queue.shift(); rt.send(k, a, b, c, d); }
      await tr.idle();
      // the floor: what any message costs, an empty one's round trip (the median of 20)
      const pings = [];
      for (let i = 0; i < 20; i++) { const t = now(); tr.ping(); await tr.idle(); pings.push(now() - t); }
      const ready = now();
      tr.lane = {
        bytes,
        // the start, in order: the downloads (lean.wasm streams into its compiler meanwhile), the
        // rest of the runtime's start (compiling, the pthreads, the files), Lean loading the snapshot
        // and mounting the app, the mount's way here and onto the page, then the pings
        phases: { download: at.downloaded - t0, runtime: at.runtime - at.downloaded, Lean: at.mounted - at.runtime,
          DOM: at.applied - at.mounted, pings: ready - at.applied },
        stats: () => ({ ...tr.totals, floorMs: median(pings) }),
      };
      rt.bootMs = ready - t0;
      return rt;
    },
    QedTransport,
  };
  global.LeanUIQed64 = LeanUIQed64;
})(globalThis);
