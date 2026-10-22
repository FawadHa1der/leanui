// The verify page's checker, in a Web Worker: runs checker.wasm (checker/: nanoda, an independent
// Lean kernel) on a receipt. Message in: {ndjson, names}, the receipt's text and the declarations
// to pretty-print. Message out: the checker's verdict (checker/src/main.rs) and `ms`, how long the
// check took. A module worker (`new Worker("worker.js", {type: "module"})`); test.mjs imports
// `check` to run the same code under Node.

// checker.wasm is a WASI command: it reads the receipt from stdin and writes its verdict to
// stdout. These are the WASI (preview 1) calls it needs to run in memory; the others it imports
// are about files and preopened directories, of which there are none, so they answer EBADF.
const EBADF = 8;

/** Check `ndjson` (a string or a Uint8Array) with a fresh instance of `module`, the compiled
    checker.wasm, and pretty-print `names`. A rejection can stop the instance mid-way (nanoda
    rejects by panicking, which aborts), so each check gets its own. */
export async function check(module, ndjson, names = []) {
  const enc = new TextEncoder();
  const input = typeof ndjson === "string" ? enc.encode(ndjson) : ndjson;
  const args = ["checker", ...names].map((a) => enc.encode(a + "\0"));
  const out = [], err = [];
  let memory, pos = 0, code = 0;
  const view = () => new DataView(memory.buffer);
  const bytes = (ptr, len) => new Uint8Array(memory.buffer, ptr, len);
  // an iovec array: n pairs of (pointer, length), each a little-endian u32
  const iovecs = (ptr, n) => Array.from({ length: n }, (_, i) =>
    bytes(view().getUint32(ptr + 8 * i, true), view().getUint32(ptr + 8 * i + 4, true)));
  const put = (ptr, n) => { view().setUint32(ptr, n, true); return 0; };
  class Exit {}
  const wasi = {
    args_sizes_get(argc, size) { put(argc, args.length); return put(size, args.reduce((n, a) => n + a.length, 0)); },
    args_get(argv, buf) {
      for (const a of args) { put(argv, buf); bytes(buf, a.length).set(a); argv += 4; buf += a.length; }
      return 0;
    },
    environ_sizes_get(count, size) { put(count, 0); return put(size, 0); },
    environ_get: () => 0,
    fd_read(fd, iov, n, nread) {
      if (fd !== 0) return EBADF;
      const start = pos;
      for (const b of iovecs(iov, n)) {
        const chunk = input.subarray(pos, pos + b.length);
        b.set(chunk); pos += chunk.length;
        if (chunk.length < b.length) break;
      }
      return put(nread, pos - start);
    },
    fd_write(fd, iov, n, nwritten) {
      if (fd !== 1 && fd !== 2) return EBADF;
      let total = 0;
      for (const b of iovecs(iov, n)) { (fd === 1 ? out : err).push(b.slice()); total += b.length; }
      return put(nwritten, total);
    },
    // seeds for the hash maps of Rust's standard library: a few bytes
    random_get: (ptr, len) => { crypto.getRandomValues(bytes(ptr, len)); return 0; },
    proc_exit: (c) => { code = c; throw new Exit(); },
  };
  const imports = {};
  for (const { module: m, name } of WebAssembly.Module.imports(module))
    (imports[m] ??= {})[name] = wasi[name] ?? (() => EBADF);
  const instance = await WebAssembly.instantiate(module, imports);
  memory = instance.exports.memory;
  let stopped = null;
  try { instance.exports._start(); } catch (e) { if (!(e instanceof Exit)) stopped = e; }
  let verdict;
  try { verdict = JSON.parse(await new Blob(out).text()); } catch {
    // no verdict: the checker ran out of stack or memory, or crashed before its panic hook was set
    const why = String(stopped?.message ?? stopped ?? `exit code ${code}`);
    return { ok: false, error: err.length ? why + ": " + (await new Blob(err).text()) : why };
  }
  // accepted only if the checker also finished normally
  if (verdict.ok && (stopped || code !== 0)) return { ok: false, error: "the checker stopped after accepting: " + (stopped?.message ?? `exit code ${code}`) };
  return verdict;
}

if (typeof WorkerGlobalScope !== "undefined") {
  const module = WebAssembly.compileStreaming(fetch(new URL("checker.wasm", import.meta.url)));
  self.onmessage = async ({ data: { ndjson, names } }) => {
    try {
      const m = await module, t0 = performance.now();
      const verdict = await check(m, ndjson, names);
      self.postMessage({ ...verdict, ms: Math.round(performance.now() - t0) });
    } catch (e) {
      self.postMessage({ ok: false, error: "cannot run the checker: " + e.message });
    }
  };
}
