// QED64's lean.wasm (Lean 4.35 compiled to wasm64) under Node 24, as the QED64 lane's build and
// tests run it (qed64/README.md):
//   run [--lib <dir>]... [--mount <dir>:<path>]... -- <lean args>
//       one lean command (a compile, the bake); exits with lean's status
//   make --src <dir> --out <dir> [--lib <dir>]... [-j <n>] <Module>...
//       compiles the modules, and those of <src> they import, in dependency order, each with
//       `run`: `lean -R <src> -o <out>/<Module>.olean`, which writes every facet --run reads
//   lane <dist>/qed64/<app>/qed64.json [--stack-mb <n>] [--pool <n>] [--selector <css>] [--flags <s>]
//       a session of the lane as its page runs one, as a stdin/stdout host (LeanUIQed/Host.lean's
//       framing): the snapshot and the run file the page's config names, lean.wasm from the cache
// startLane() is the last as a library. One lean.wasm per process (its glue runs in this global
// scope); run with the Node tools/node.sh prints, and --stack-size=8192. The host keeps to the
// runtime's contract (EMBED-RUNTIME.md in the Lean fork; its sections are cited below). Libraries
// (--lib) are mounted at /lib/l<i> and are all LEAN_PATH has; lean.js and lean.wasm come from
// <cache>/rt (tools/fetch.mjs), the cache being qed64/.cache or $LEANUI_QED64_CACHE.
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import zlib from "node:zlib";
import os from "node:os";
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CACHE = path.resolve(process.env.LEANUI_QED64_CACHE || path.join(HERE, "../.cache"));
vm.runInThisContext(fs.readFileSync(path.join(HERE, "../lane/core.js"), "utf8"), { filename: "core.js" });
const { QedCore } = globalThis;

let booted = false;
// Boot lean.wasm with `argv`, the way both hosts do: our own shared memory (so we can see the
// ring), no initial run, then the ring and callMain. stdout comes one byte at a time to onStdout.
function boot({ argv, libs = [], mounts = [], files = {}, pool = 2, stackMb = 0, onStdout, onReady, onExit }) {
  if (booted) throw new Error("one lean.wasm per process");
  booted = true;
  const rt = path.join(CACHE, "rt"), leanJs = path.join(rt, "lean.js");
  if (!fs.existsSync(path.join(rt, "lean.wasm"))) throw new Error(`no ${rt}/lean.wasm: run qed64/build.sh (or tools/fetch.mjs)`);
  const memory = QedCore.memory();
  const leanPath = libs.map((_, i) => `/lib/l${i}`).join(":");
  // main's Node prologue copies the host's LEAN_PATH and makes the host's cwd lean's (§3.5): at /
  // the paths we pass are what they say
  process.env.LEAN_PATH = leanPath;
  process.chdir("/");
  process.argv[1] = "/bin/lean";
  globalThis.__filename = "/bin/lean.js";
  globalThis.__dirname = "/bin";
  let ring = null, exited = false;
  const early = []; let closed = false;          // input before the ring exists
  const exit = (code) => { if (!exited) { exited = true; onExit(code); } };
  globalThis.Module = {
    wasmMemory: memory,
    noInitialRun: true,
    pthreadPoolSize: pool,
    locateFile: (f) => path.join(rt, f),
    mainScriptUrlOrBlob: leanJs,
    print: (s) => process.stderr.write(s + "\n"),           // stdout goes through put_char instead
    printErr: (s) => process.stderr.write(s + "\n"),
    preRun: [() => {
      const M = globalThis.Module, FS = M.FS, NODEFS = FS.filesystems.NODEFS;
      // HARDENING #52 in QED64: mailbox notifications by message, plus the kick in onRuntimeInitialized
      globalThis.waitAsyncPolyfilled = true;
      // lean's exit reaches this thread as a proxied _proc_exit or exitOnMainThread, which the
      // runtime's keepalive swallows (§5)
      const T = globalThis.proxiedFunctionTable;
      for (const i of [0, 1]) { const f = T[i]; T[i] = function (code) { exit(Number(code)); return f.apply(this, arguments); }; }
      for (const d of ["/bin", "/workspace", "/snap", "/work"]) FS.mkdirTree(d);
      libs.forEach((dir, i) => { FS.mkdirTree(`/lib/l${i}`); FS.mount(NODEFS, { root: dir }, `/lib/l${i}`); });
      for (const [dir, at] of mounts) { FS.mkdirTree(at); FS.mount(NODEFS, { root: dir }, at); }
      // a pthread's __filename is lean.js's host path, so lean must find it there too (§3.3)
      FS.mkdirTree(rt); FS.mount(NODEFS, { root: rt }, rt);
      for (const [p, bytes] of Object.entries(files)) FS.writeFile(p, bytes, { canOwn: true });
      M.ENV.LEAN_PATH = leanPath;
    }],
    onRuntimeInitialized() {
      const M = globalThis.Module;
      const tty = globalThis.TTY.ttys[M.FS.makedev(5, 0)];
      tty.ops = { ...tty.ops, put_char(t, b) { if (b !== null) onStdout(b); }, fsync() {} };
      const ptr = Number(M._malloc(16 + QedCore.RING_BYTES));
      if (Number(M._lean_browser64_configure_input_ring(BigInt(ptr), QedCore.RING_BYTES)) !== 0) throw new Error("lean.wasm refused the stdin ring");
      ring = new QedCore.Ring(memory, ptr);
      for (const b of early.splice(0)) ring.write(b);
      if (closed) ring.close();
      setInterval(() => { try { M.__emscripten_check_mailbox(); } catch (e) { if (e !== "unwind") throw e; } }, 1000).unref();
      onReady?.(M);
      M.callMain(argv);
    },
    onAbort: (what) => { process.stderr.write(`wasm-lean: lean.wasm aborted: ${what}\n`); exit(3); },
  };
  // PTHREAD stack: each pthread Worker gets this much V8 stack (a Chrome Worker has about 0.5 MiB,
  // Node 4 MiB; the interpreter's recursion is bounded by it, §6)
  const req = createRequire(leanJs);
  globalThis.require = stackMb > 0 ? Object.assign((id) => {
    const m = req(id);
    if (id !== "worker_threads" && id !== "node:worker_threads") return m;
    class Worker extends m.Worker { constructor(url, o = {}) { super(url, { ...o, resourceLimits: { ...o.resourceLimits, stackSizeMb: stackMb } }); } }
    return { ...m, Worker };
  }, req) : req;
  vm.runInThisContext(fs.readFileSync(leanJs, "utf8"), { filename: leanJs });
  return {
    write(bytes) { if (ring) ring.write(bytes); else early.push(bytes); },
    close() { if (ring) ring.close(); else closed = true; },
  };
}

// stdout bytes to this process's stdout, in one write per turn of the event loop
function stdoutSink() {
  let buf = Buffer.allocUnsafe(1 << 16), n = 0, queued = false;
  const flush = (done) => { queued = false; const out = Buffer.from(buf.subarray(0, n)); n = 0; if (out.length || done) process.stdout.write(out, done); };
  return {
    byte(b) {
      if (n === buf.length) { const nb = Buffer.allocUnsafe(buf.length * 2); buf.copy(nb); buf = nb; }
      buf[n++] = b;
      if (!queued) { queued = true; setImmediate(flush); }
    },
    exit(code) { flush(() => process.exit(code)); },
  };
}

/** A session of the lane: the page's config (`<dist>/qed64/<app>/qed64.json`), its snapshot and
    run file in MEMFS where the browser puts them, `QedCore.argv`. Returns { write(bytes), close(),
    phases } at once; onStdout gets lean's stdout byte by byte, onExit its status. */
export function startLane({ config, selector = "#app", flags = "", pool, stackMb = 0, onStdout, onExit = () => {}, onPhase = () => {} }) {
  const t0 = performance.now(), phases = {};
  const phase = (name) => { phases[name] = +(performance.now() - t0).toFixed(1); onPhase(name, phases[name]); };
  const cfg = JSON.parse(fs.readFileSync(config, "utf8"));
  const rt = path.resolve(path.dirname(config), cfg.rt);
  const snap = zlib.gunzipSync(fs.readFileSync(path.join(rt, cfg.snapshot)));
  if (snap.length !== cfg.snapshotBytes) throw new Error(`${cfg.snapshot}: ${snap.length} bytes unpacked, the config says ${cfg.snapshotBytes}`);
  phase("snapshot");
  // the first reply is the mount; then MEMFS's copy of the snapshot can go (lean holds its own)
  let M = null, mounted = false;
  const replies = new QedCore.Replies(() => {
    if (mounted) return;
    mounted = true; phase("mounted");
    M.FS.unlink(QedCore.SNAP);
  });
  const lean = boot({
    argv: QedCore.argv(cfg.app, { selector, flags }),
    files: {
      [QedCore.SNAP]: new Uint8Array(snap.buffer, snap.byteOffset, snap.length),
      [QedCore.SNAP + ".deps"]: fs.readFileSync(path.join(rt, cfg.snapshotDeps)),   // --incr-load opens it
      [QedCore.RUN_FILE]: fs.readFileSync(path.join(rt, cfg.runFile)),
    },
    pool: pool ?? cfg.pool, stackMb,
    onStdout: (b) => { if (!mounted) replies.byte(b); onStdout(b); },
    onReady: (m) => { M = m; phase("runtime"); },
    onExit,
  });
  return { write: lean.write, close: lean.close, phases };
}

// ---- the command line ----
const opts = (args, flags) => {
  const o = { _: [] };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--") { o["--"] = args.slice(i + 1); break; }
    if (flags[a] === "list") (o[a] ??= []).push(args[++i]);
    else if (flags[a] === "value") o[a] = args[++i];
    else if (a.startsWith("-")) throw new Error(`unknown option ${a}`);
    else o._.push(a);
  }
  return o;
};
const mountsOf = (o) => (o["--mount"] || []).map((m) => { const i = m.lastIndexOf(":"); return [path.resolve(m.slice(0, i)), m.slice(i + 1)]; });

function run(args) {
  const o = opts(args, { "--lib": "list", "--mount": "list", "--pool": "value" });
  const out = stdoutSink();
  const lean = boot({ argv: o["--"] || [], libs: (o["--lib"] || []).map((d) => path.resolve(d)), mounts: mountsOf(o),
    pool: +(o["--pool"] ?? 2), onStdout: out.byte, onExit: out.exit });
  process.stdin.on("data", (b) => lean.write(b)).on("end", () => lean.close());
}

// The header of a Lean file: the modules it imports
function imports(file) {
  const out = []; let comment = false;
  for (const line of fs.readFileSync(file, "utf8").split("\n")) {
    const t = line.trim();
    if (comment) { if (t.includes("-/")) comment = false; continue; }
    if (t.startsWith("/-")) { comment = !t.includes("-/", 2); continue; }
    if (t === "" || t.startsWith("--") || t === "module" || t === "prelude") continue;
    const m = t.match(/^(?:public\s+)?(?:meta\s+)?import\s+(?:all\s+)?([\w.]+)/);
    if (!m) break;
    out.push(m[1]);
  }
  return out;
}

async function make(args) {
  const o = opts(args, { "--src": "value", "--out": "value", "--lib": "list", "-j": "value" });
  const src = path.resolve(o["--src"]), out = path.resolve(o["--out"]), libs = (o["--lib"] || []).map((d) => path.resolve(d));
  const jobs = +(o["-j"] ?? os.availableParallelism());
  const file = (m) => path.join(src, ...m.split(".")) + ".lean";
  const deps = new Map();
  const visit = (m) => {
    if (deps.has(m) || !fs.existsSync(file(m))) return;
    deps.set(m, []);
    const ds = imports(file(m)).filter((d) => fs.existsSync(file(d)));
    deps.set(m, ds); ds.forEach(visit);
  };
  for (const m of o._) { visit(m); if (!deps.has(m)) throw new Error(`make: no ${file(m)}`); }
  const done = new Set(), running = new Map();
  const start = (m) => new Promise((ok) => {
    const rel = m.split(".").join("/"), log = path.join(out, rel + ".log"), t = performance.now();
    fs.mkdirSync(path.dirname(log), { recursive: true });
    const fd = fs.openSync(log, "w");
    const p = spawn(process.execPath, ["--stack-size=8192", fileURLToPath(import.meta.url), "run", ...[...libs, out].flatMap((l) => ["--lib", l]),
      "--mount", `${src}:/work/src`, "--mount", `${out}:/work/out`, "--", "-R", "/work/src", "-o", `/work/out/${rel}.olean`, `/work/src/${rel}.lean`],
      { stdio: ["ignore", fd, fd] });
    p.on("exit", (code) => { fs.closeSync(fd); ok({ m, code, ms: performance.now() - t, log }); });
  });
  while (done.size < deps.size) {
    for (const [m, ds] of deps) {
      if (running.size >= jobs) break;
      if (!done.has(m) && !running.has(m) && ds.every((d) => done.has(d))) running.set(m, start(m));
    }
    const r = await Promise.race(running.values());
    running.delete(r.m);
    if (r.code !== 0) {
      process.stderr.write(fs.readFileSync(r.log, "utf8").split("\n").slice(-30).join("\n") + `\nmake: ${r.m} failed (${r.log})\n`);
      await Promise.all(running.values());
      process.exit(1);
    }
    done.add(r.m);
    console.log(`  ${r.m} ${(r.ms / 1000).toFixed(1)} s`);
  }
}

function lane(args) {
  const o = opts(args, { "--stack-mb": "value", "--pool": "value", "--selector": "value", "--flags": "value" });
  if (o._.length !== 1) throw new Error("usage: wasm-lean.mjs lane <dist>/qed64/<app>/qed64.json [--stack-mb n] [--pool n] [--selector css] [--flags s]");
  const out = stdoutSink();
  const l = startLane({ config: path.resolve(o._[0]), selector: o["--selector"], flags: o["--flags"], pool: o["--pool"] && +o["--pool"],
    stackMb: +(o["--stack-mb"] ?? 0), onStdout: out.byte, onExit: out.exit,
    onPhase: (name) => { if (name === "mounted") process.stderr.write(`qed64 phases ${JSON.stringify(l.phases)}\n`); } });
  process.stdin.on("data", (b) => l.write(b)).on("end", () => l.close());
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [cmd, ...rest] = process.argv.slice(2);
  const cmds = { run, make, lane };
  if (!cmds[cmd]) { console.error("usage: wasm-lean.mjs run|make|lane … (see the top of this file)"); process.exit(2); }
  await cmds[cmd](rest);
}
