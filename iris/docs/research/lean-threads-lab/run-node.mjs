// Runs a ThreadLab wasm64 build in Node (24, from emsdk: Memory64 on by default).
//   node run-node.mjs <dir with threadlab.js> <workers> [suite a b c]...  [--mixed k n jsWorkers] [--ring count]
// --mixed: Lean tasks (C11 fetch_add) and plain JavaScript worker_threads (Atomics.add) increment
//          the same 64-bit cell of the module's SharedArrayBuffer at the same time.
// --ring:  a JavaScript worker pushes 1..count into the SPSC ring (SpscRing.tryPush in JS); Lean pops.
import { createRequire } from "node:module";
import { Worker } from "node:worker_threads";
import path from "node:path";
const require = createRequire(import.meta.url);
const [dir, workersArg, ...rest] = process.argv.slice(2);
const workers = Number(workersArg);
const t0 = performance.now();
const factory = require(path.resolve(dir, "threadlab.js"));
const M = await factory({ print: (s) => console.log(s), printErr: (s) => console.error(s) });
const tLoaded = performance.now();
if (!M._lab_boot(workers)) { console.error("boot failed"); process.exit(1); }
const tBooted = performance.now();
console.log(JSON.stringify({ bench: "boot", dir: path.basename(dir), workers, loadMs: +(tLoaded - t0).toFixed(1), leanInitMs: +(tBooted - tLoaded).toFixed(1), rssMB: +(process.memoryUsage().rss / 2 ** 20).toFixed(1),
  shared: M.wasmMemory ? M.wasmMemory.buffer instanceof SharedArrayBuffer : M.HEAPU8.buffer instanceof SharedArrayBuffer }));

const jsWorkerSrc = `
const { parentPort, workerData } = require("node:worker_threads");
const { sab, region, mode, n, startSab } = workerData;
const start = new Int32Array(startSab);
const cells = new BigUint64Array(sab, Number(region), 32 + 1024);
Atomics.wait(start, 0, 0);
const t0 = performance.now();
if (mode === "faa") {
  for (let i = 0; i < n; i++) Atomics.add(cells, 8, 1n);
} else if (mode === "push") {
  // SpscRing.tryPush, translated to JS: indices with Atomics (SC), the slot with a plain store
  const N = 1024n, HD = 16, TL = 24, SLOTS = 32; let full = 0;
  for (let v = 1n; v <= BigInt(n); ) {
    const t = Atomics.load(cells, TL), h = Atomics.load(cells, HD);
    if (t - h < N) { cells[SLOTS + Number(t % N)] = v; Atomics.store(cells, TL, t + 1n); v++; } else full++;
  }
  parentPort.postMessage({ full });
}
parentPort.postMessage({ ms: performance.now() - t0 });
`;
function jsWorker(mode, n, startSab) {
  const sab = M.wasmMemory ? M.wasmMemory.buffer : M.HEAPU8.buffer;
  const w = new Worker(jsWorkerSrc, { eval: true, workerData: { sab, region: M._lab_region_js(), mode, n, startSab } });
  const msgs = [];
  const done = new Promise((res, rej) => { w.on("message", (m) => { msgs.push(m); if ("ms" in m) res(msgs); }); w.on("error", rej); });
  return { w, done };
}

for (let i = 0; i < rest.length; ) {
  if (rest[i] === "--mixed") {
    const [k, n, js] = rest.slice(i + 1, i + 4).map(Number); i += 4;
    const startSab = new SharedArrayBuffer(4);
    const ws = Array.from({ length: js }, () => jsWorker("faa", n, startSab));
    await new Promise((r) => setTimeout(r, 300)); // let the workers reach Atomics.wait
    const region = M._lab_region_js();
    const cells = new BigUint64Array(M.wasmMemory ? M.wasmMemory.buffer : M.HEAPU8.buffer, Number(region), 32);
    Atomics.store(cells, 8, 0n);
    const s = performance.now();
    Atomics.store(new Int32Array(startSab), 0, 1); Atomics.notify(new Int32Array(startSab), 0);
    M._lab_mixed(k, n); // blocks this thread until the Lean tasks are done
    const rs = await Promise.all(ws.map((x) => x.done));
    console.log(JSON.stringify({ bench: "mixed-faa", leanTasks: k, jsWorkers: js, perThread: n, ms: +(performance.now() - s).toFixed(1),
      got: String(Atomics.load(cells, 8)), expected: String(BigInt(k * n + js * n)), jsMs: rs.map((m) => +m.at(-1).ms.toFixed(1)) }));
    ws.forEach((x) => x.w.terminate());
  } else if (rest[i] === "--ring") {
    const count = Number(rest[i + 1]); i += 2;
    const region = M._lab_region_js();
    const cells = new BigUint64Array(M.wasmMemory ? M.wasmMemory.buffer : M.HEAPU8.buffer, Number(region), 32);
    Atomics.store(cells, 16, 0n); Atomics.store(cells, 24, 0n);
    const startSab = new SharedArrayBuffer(4);
    const p = jsWorker("push", count, startSab);
    await new Promise((r) => setTimeout(r, 300));
    Atomics.store(new Int32Array(startSab), 0, 1); Atomics.notify(new Int32Array(startSab), 0);
    M._lab_ring(count); // Lean consumes on this thread while the JS worker produces
    const msgs = await p.done;
    console.log(JSON.stringify({ bench: "spsc-js-producer", producerMs: +msgs.at(-1).ms.toFixed(1), producerFullSpins: msgs[0].full }));
    p.w.terminate();
  } else {
    const [w, a, b, c] = rest.slice(i, i + 4).map(Number); i += 4;
    if (!M._lab_run(w, a, b, c)) { console.error("suite failed"); process.exit(1); }
  }
}
process.exit(0);
