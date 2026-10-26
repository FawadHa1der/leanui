// What the QED64 lane's two hosts of lean.wasm share: its browser Worker and its Node host
// (tools/wasm-lean.mjs). Lean's memory and command line, the producer of its stdin ring, and the
// parser of what LeanUIQed/Host.lean writes. A classic script that defines QedCore: the Worker loads
// it with importScripts, Node evaluates it in its global scope (wasm-lean.mjs), as the glue is.
(function (global) {
  "use strict";
  const PAGE = 65536;

  // The shared memory lean.wasm imports (wasm64, EMBED-RUNTIME §1): 256 MiB to start, so loading
  // the 114 MB snapshot does not grow it, and the runtime's maximum, 16 GiB.
  const memory = () => new WebAssembly.Memory({ initial: BigInt((256 << 20) / PAGE), maximum: BigInt(16 * 2 ** 30 / PAGE), shared: true, address: "i64" });

  // Where a session's files are. The bake (tools/bake.sh) names the run file the same way, with
  // --root: a snapshot records its main module's name, and here and there it is `AppsRun`.
  const SNAP = "/snap/apps.snap", ROOT = "/workspace", RUN_FILE = "/workspace/AppsRun.lean";

  // lean's arguments for a session of `app` (bench or life): the header snapshot instead of
  // oleans, one task thread, the updates as raw bytes (--out raw: no base64 in the interpreter).
  const argv = (app, { selector = "#app", flags = "" } = {}) =>
    ["-j1", "--incr-load=" + SNAP, "--root=" + ROOT, "--run", RUN_FILE, app, "--out", "raw", "--selector", selector,
      ...(flags ? ["--flags", flags] : [])];

  // The stdin ring (patch 0031): u32 READ (Lean's cursor), WRITE (ours), CLOSED, WAKE, then the
  // bytes; READ == WRITE is empty. The thread that writes it is Emscripten's main runtime thread,
  // which Lean's pthreads proxy their system calls through, so it never waits: when the ring is
  // full it tries again 1 ms later. Messages are written whole and in order.
  const RING_BYTES = 1 << 20;
  class Ring {
    constructor(memory, ptr, cap = RING_BYTES) {
      this.memory = memory; this.ptr = ptr; this.cap = cap;
      this.queue = []; this.closed = false; this.timer = null; this.fullRetries = 0;
    }
    write(bytes) { this.queue.push({ bytes, off: 0 }); this.pump(); }
    close() { this.closed = true; this.pump(); }       // end of input once the ring has drained
    pump() {
      if (this.timer) return;
      // views are taken anew each time: growing the memory replaces its buffer
      const ctrl = new Int32Array(this.memory.buffer, this.ptr, 4), ring = new Uint8Array(this.memory.buffer, this.ptr + 16, this.cap);
      while (this.queue.length) {
        const m = this.queue[0];
        while (m.off < m.bytes.length) {
          const r = Atomics.load(ctrl, 0), w = Atomics.load(ctrl, 1), free = (r - w - 1 + this.cap) % this.cap;
          if (free === 0) { this.fullRetries++; this.timer = setTimeout(() => { this.timer = null; this.pump(); }, 1); return; }
          const n = Math.min(free, this.cap - w, m.bytes.length - m.off);
          ring.set(m.bytes.subarray(m.off, m.off + n), w); m.off += n;
          Atomics.store(ctrl, 1, (w + n) % this.cap);
          Atomics.add(ctrl, 3, 1); Atomics.notify(ctrl, 3);
        }
        this.queue.shift();
      }
      if (this.closed) { Atomics.store(ctrl, 2, 1); Atomics.add(ctrl, 3, 1); Atomics.notify(ctrl, 3); }
    }
  }

  // What the host writes, one byte at a time (the glue's TTY hands stdout over byte by byte):
  //   u <n>\n<n bytes>            one update, [u32 opsBytes][ops][strs]
  //   ! <message>\n               a message the host could not parse
  //   . <leanNs> <encodeNs>\n     the end of a reply (the first is the mount's, then one per message)
  // onReply gets { updates: [Uint8Array], leanNs, encodeNs, errors: [string], bytes }; any other
  // line goes to onLine.
  const text = new TextDecoder();
  class Replies {
    constructor(onReply, onLine = () => {}) {
      this.onReply = onReply; this.onLine = onLine;
      this.line = []; this.need = 0; this.update = null; this.off = 0;
      this.updates = []; this.errors = []; this.bytes = 0;
    }
    push(bytes) { for (let i = 0; i < bytes.length; i++) this.byte(bytes[i]); }
    byte(b) {
      this.bytes++;
      if (this.need > 0) {
        this.update[this.off++] = b;
        if (--this.need === 0) { this.updates.push(this.update); this.update = null; }
        return;
      }
      if (b !== 10) { this.line.push(b); return; }
      const s = text.decode(Uint8Array.from(this.line)); this.line = [];
      if (s.startsWith("u ")) {
        const n = Number(s.slice(2));
        this.update = new Uint8Array(n); this.off = 0; this.need = n;
        if (n === 0) { this.updates.push(this.update); this.update = null; }
      } else if (s.startsWith("! ")) this.errors.push(s.slice(2));
      else if (s.startsWith(". ")) {
        const [leanNs, encodeNs] = s.slice(2).split(" ").map(Number);
        const r = { updates: this.updates, leanNs, encodeNs, errors: this.errors, bytes: this.bytes };
        this.updates = []; this.errors = []; this.bytes = 0;
        this.onReply(r);
      } else this.onLine(s);
    }
  }

  global.QedCore = { memory, SNAP, ROOT, RUN_FILE, argv, RING_BYTES, Ring, Replies };
})(globalThis);
