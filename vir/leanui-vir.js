// LeanUI on lean-vir: runs an app's Lean code in lean-vir's interpreter (Lean's IR interpreter,
// compiled to wasm32) instead of a compiled wasm64 module, and applies its updates with the DOM code
// of leanui.js, which must be loaded first. The Lean side is vir/LeanUIVir/Host.lean; vir/README.md
// explains the whole path.
(function (global) {
  "use strict";
  const LeanUI = global.LeanUI;

  // Each call into Lean returns the updates it made, each [u32 opsBytes][ops][strs] (the bytes a
  // LeanUI server sends), as fresh Uint8Arrays (lean-vir copies byte arrays out of its memory), so
  // Runtime.apply can read the words in place.
  class VirTransport {
    constructor(program, app, session, rt) { this.program = program; this.app = app; this.session = session; this.rt = rt; }
    call(fn, ...args) { this.apply(this.program.call(this.app + "." + fn, this.session, ...args)); }
    apply(updates) {
      try {
        for (const u of updates) {
          if (this.rt.disposed) return;
          const opsLen = (u[0] | (u[1] << 8) | (u[2] << 16) | (u[3] << 24)) >>> 0;
          this.rt.apply(u, 4, opsLen, 4 + opsLen, u.length - 4 - opsLen);
        }
      } catch (e) { this.broken = true; throw e; }
    }
    event(slot, payload) { this.call("event", slot, payload); }
    callback(cb, ok, payload) { this.call("callback", cb, ok, payload); }
    // effects that answer with bytes (files, images) need the wasm64 host
    callbackBytes(cb) { this.callback(cb, false, "bytes need the wasm64 host"); }
    // A failed DOM update may leave the screen and Lean state out of sync.
    isTerminalError() { return this.broken || this.program?.status === "failed"; }
    dispose() {
      const program = this.program;
      this.program = this.session = null;
      program?.dispose();
    }
  }

  const LeanUIVir = {
    /** Run `app`, the namespace of a `leanui_vir_app` (e.g. "LeanUIVir.BenchApp"), from the
        lean-vir files that `config` describes (`app.json`, written by `lake exe publish`). */
    async start({ config = "app.json", app, selector = "#app", flags = "" }) {
      const t0 = performance.now();
      const url = new URL(config, document.baseURI);
      const res = await fetch(url);
      if (!res.ok) throw new Error("cannot load " + url + ": HTTP " + res.status);
      const cfg = await res.json();
      const { createProgram } = await import(new URL(cfg.runtimeModule, url).href);
      const program = await createProgram({
        runtimeManifestUrl: new URL(cfg.runtimeManifest, url),
        programManifestUrl: new URL(cfg.programManifest, url),
      });
      const rt = new LeanUI.Runtime(null);
      rt.transport = new VirTransport(program, app, null, rt);
      rt.start(() => {
        const session = program.call(app + ".start", flags, selector);
        if (rt.disposed) return;
        rt.transport.session = session;
        rt.transport.apply(program.call(app + ".take", session));
      });
      rt.bootMs = performance.now() - t0;
      return rt;
    },
    VirTransport,
  };
  global.LeanUIVir = LeanUIVir;
})(globalThis);
