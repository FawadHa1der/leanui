// The QED64 lane's Worker (qed64/README.md): Emscripten's main runtime thread for lean.wasm, which
// runs one session of the lane on a pthread of its own (lean.wasm is built PROXY_TO_PTHREAD):
//   lean -j1 --incr-load=/snap/apps.snap --root=/workspace --run /workspace/AppsRun.lean <app> --out raw …
// It does what tools/wasm-lean.mjs's startLane does in Node, with lane/core.js shared: lean.wasm gets
// a shared memory of ours, the snapshot and the run file are in MEMFS, messages go into Lean's stdin
// ring, and stdout comes back byte by byte through the TTY's put_char. This thread never blocks:
// Lean's pthreads proxy their system calls through it. The page side is lane/leanui-qed64.js.
//   in:  {type: "boot", leanJs, leanWasm, core, snapshot, snapshotBytes, snapshotDeps, runFile,
//         app, selector, flags, pool}           once, with absolute URLs
//        {type: "msg", head, body}              a message for the host (`e <slot>`, `c <cb> <0|1>`)
//        {type: "ping"}                         an empty round trip
//   out: {type: "phase", name, at}              downloaded, runtime, mounted
//        {type: "progress", got, total}         the snapshot's download, in bytes
//        {type: "reply", mount, updates, leanNs, workerMs, stall, errors, bytes}
//                                               the mount's, then one per message, in order (bytes:
//                                               the mount's only, what this Worker downloaded)
//        {type: "stopped", message}             Lean exited, or lean.wasm aborted or could not start
// Times (`at`) are on the clock the page shares, timeOrigin + now(). A reply's workerMs runs from its
// message reaching this thread (or the reply before it leaving, if later) to the reply leaving.
"use strict";
const now = () => performance.now();
let cfg = null, M = null, parser = null, ring = null, stopped = false, mounted = false, mainAt = 0, lastOut = 0;
const early = [];               // messages that came before the ring
const arrived = [];             // when each message still waiting for its reply came
const tail = [];                // Lean's last lines on stderr (and stray stdout), for when it stops
const log = (s) => { tail.push(s); if (tail.length > 20) tail.shift(); console.debug("lean:", s); };
const post = (m, transfer) => postMessage(m, transfer || []);
const phase = (name, t = now()) => post({ type: "phase", name, at: performance.timeOrigin + t });
function stop(message) {
  if (stopped) return;
  stopped = true;
  post({ type: "stopped", message: message + (tail.length ? "\n" + tail.join("\n") : "") });
}

// A reply whose time in this Worker exceeds Lean's own by this much was held up (a lost mailbox
// wakeup that the 1 s kick below caught, QED64's HARDENING #52): the race counts it as a stall.
const STALL_MS = 500;
function onReply(r) {
  const t = now(), mount = !mounted;
  mounted = true;
  const workerMs = t - (mount ? mainAt : Math.max(arrived.shift(), lastOut));
  lastOut = t;
  const updates = r.updates.map((u) => u.buffer);
  const m = { type: "reply", mount, updates, leanNs: r.leanNs, workerMs, stall: !mount && workerMs - r.leanNs / 1e6 > STALL_MS, errors: r.errors };
  if (mount) {
    phase("mounted", t);
    M.FS.unlink(QedCore.SNAP);   // Lean holds the snapshot in its own memory now: MEMFS's copy (114 MB) can go
    m.bytes = downloaded();
  }
  post(m, updates);
}

// What this Worker downloaded (the page's resource timing does not see it), compressed as it came
function downloaded() {
  const sizes = new Map(performance.getEntriesByType("resource").map((e) => [e.name, e.encodedBodySize || 0]));
  return [...sizes.values()].reduce((a, b) => a + b, 0);
}

// The snapshot is gzipped (a .snap would be served uncompressed): unpacked as it comes, into one
// buffer of its known size, which MEMFS then owns.
async function fetchSnapshot(url, size) {
  const r = await fetch(url);
  if (!r.ok) throw new Error(url + ": HTTP " + r.status);
  const total = +r.headers.get("content-length") || 0;
  let got = 0, shown = 0;
  const count = new TransformStream({ transform(chunk, c) {
    got += chunk.length;
    if (now() - shown > 200) { shown = now(); post({ type: "progress", got, total }); }
    c.enqueue(chunk);
  } });
  const out = new Uint8Array(size), rd = r.body.pipeThrough(count).pipeThrough(new DecompressionStream("gzip")).getReader();
  let off = 0;
  for (;;) {
    const { done, value } = await rd.read();
    if (done) break;
    if (off + value.length > size) throw new Error(`${url}: more than the ${size} bytes the config says`);
    out.set(value, off); off += value.length;
  }
  if (off !== size) throw new Error(`${url}: ${off} bytes, the config says ${size}`);
  return out;
}
const bytesOf = (url) => fetch(url).then((r) => { if (!r.ok) throw new Error(url + ": HTTP " + r.status); return r.arrayBuffer(); }).then((b) => new Uint8Array(b));

function boot(c) {
  cfg = c;
  importScripts(cfg.core);
  parser = new QedCore.Replies(onReply, log);
  // the downloads start now, while lean.wasm compiles (it streams: same-origin URLs, no Blob)
  let snapAt = 0;
  let files = Promise.all([fetchSnapshot(cfg.snapshot, cfg.snapshotBytes).then((s) => { snapAt = now(); return s; }),
    bytesOf(cfg.snapshotDeps), bytesOf(cfg.runFile)]);
  files.catch((e) => stop(String(e && e.message || e)));
  const memory = QedCore.memory();
  self.Module = {
    wasmMemory: memory,
    noInitialRun: true,
    pthreadPoolSize: cfg.pool,
    locateFile: (f) => (f.endsWith(".wasm") ? cfg.leanWasm : new URL(f, cfg.leanJs).href),
    mainScriptUrlOrBlob: cfg.leanJs,
    print: log,                    // stdout goes through put_char instead
    printErr: log,                 // Lean's progress lines, not errors
    preRun: [() => {
      const FS = self.Module.FS;
      // HARDENING #52 in QED64: mailbox notifications by message, plus the kick in onRuntimeInitialized
      self.waitAsyncPolyfilled = true;
      // lean's exit reaches this thread as a proxied _proc_exit or exitOnMainThread, which the
      // runtime's keepalive swallows (EMBED-RUNTIME §5)
      const T = self.proxiedFunctionTable;
      for (const i of [0, 1]) { const f = T[i]; T[i] = function (code) { stop("Lean exited with status " + Number(code)); return f.apply(this, arguments); }; }
      for (const d of ["/bin", "/workspace", "/snap"]) FS.mkdirTree(d);
      // the runtime starts once the files are in
      addRunDependency("qed64-files");
      files.then(([snap, deps, run]) => {
        FS.writeFile(QedCore.SNAP, snap, { canOwn: true });
        FS.writeFile(QedCore.SNAP + ".deps", deps);       // --incr-load opens it
        FS.writeFile(QedCore.RUN_FILE, run);
        // the closures here outlive the boot: without this the promise would keep the snapshot's
        // bytes alive after MEMFS lets go of them (the unlink after the mount)
        files = null;
        removeRunDependency("qed64-files");
      }, () => {});
    }],
    onRuntimeInitialized() {
      M = self.Module;
      // downloaded: the later of the snapshot unpacked and lean.wasm's last byte
      const wasm = performance.getEntriesByType("resource").find((e) => e.name === cfg.leanWasm);
      phase("downloaded", Math.max(snapAt, wasm ? wasm.responseEnd : 0));
      phase("runtime");
      const tty = TTY.ttys[M.FS.makedev(5, 0)];
      tty.ops = { ...tty.ops, put_char(t, b) { if (b !== null) parser.byte(b); }, fsync() {} };
      const ptr = Number(M._malloc(16 + QedCore.RING_BYTES));
      if (Number(M._lean_browser64_configure_input_ring(BigInt(ptr), QedCore.RING_BYTES)) !== 0) return stop("lean.wasm refused the stdin ring");
      ring = new QedCore.Ring(memory, ptr);
      for (const m of early.splice(0)) ring.write(m);
      setInterval(() => { try { M.__emscripten_check_mailbox(); } catch (e) { if (e !== "unwind") throw e; } }, 1000);
      mainAt = now();
      M.callMain(QedCore.argv(cfg.app, { selector: cfg.selector, flags: cfg.flags }));
    },
    onAbort: (what) => stop("lean.wasm aborted: " + what),
  };
  importScripts(cfg.leanJs);
}

const ping = new TextEncoder().encode("p\n");
self.onmessage = (e) => {
  const d = e.data;
  if (d.type === "boot") { try { boot(d); } catch (err) { stop("lean.wasm could not start: " + (err && err.message || err)); } return; }
  const m = d.type === "ping" ? ping : QedCore.message(d.head, d.body);
  arrived.push(now());
  if (ring) ring.write(m); else early.push(m);
};
