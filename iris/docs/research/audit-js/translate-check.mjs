// Hand-translation check for the audit proofs (NOT a verified translation).
// Runs the verified HeapLang algorithms, transcribed to SharedArrayBuffer + Atomics,
// on real threads, next to deliberately broken variants.
//
//   node translate-check.mjs
//
// Each scenario prints: correct? and a timing ratio. Timings are from a CI VM: treat as
// relative, to be re-measured on the reference Mac.
import { Worker, isMainThread, parentPort, workerData } from 'node:worker_threads';
import { fileURLToPath } from 'node:url';

const self = fileURLToPath(import.meta.url);

// ---------------------------------------------------------------- worker bodies
function workerMain() {
  const { kind, sab, n, cap, gate, parties } = workerData;
  const i32 = new Int32Array(sab);
  if (gate) { // start barrier so that the threads really overlap
    const g = new Int32Array(gate);
    Atomics.add(g, 0, 1);
    while (Atomics.load(g, 0) < parties) {}
  }
  switch (kind) {
    case 'faa': // AtomicCounter.faaIncr  ==  faa(l, 1)
      for (let k = 0; k < n; k++) Atomics.add(i32, 0, 1);
      break;
    case 'cas': // AtomicCounter.casIncr  ==  load; cmpXchg retry loop
      for (let k = 0; k < n; k++) {
        for (;;) { const v = Atomics.load(i32, 0); if (Atomics.compareExchange(i32, 0, v, v + 1) === v) break; }
      }
      break;
    case 'racy': // the program Iris cannot verify: l <- !l + 1 with plain accesses
      for (let k = 0; k < n; k++) i32[0] = i32[0] + 1;
      break;
    case 'lock': { // spin lock (SpinLock.lean) around a plain increment; lock word at index 1
      for (let k = 0; k < n; k++) {
        while (Atomics.compareExchange(i32, 1, 0, 1) !== 0) {}
        i32[0] = i32[0] + 1;
        Atomics.store(i32, 1, 0);
      }
      break;
    }
    // SpscRing.lean: [0]=hd (consumer counter), [1]=tl (producer counter), slots at [2..2+cap)
    case 'producer': case 'producer-plain': {
      const plain = kind === 'producer-plain';
      for (let k = 0; k < n; k++) {
        for (;;) {
          const t = plain ? i32[1] : Atomics.load(i32, 1);
          const h = plain ? i32[0] : Atomics.load(i32, 0);
          if (t - h < cap) {
            i32[2 + (t % cap)] = k + 1;          // plain slot store (proof: slot owned by producer)
            if (plain) i32[1] = t + 1; else Atomics.store(i32, 1, t + 1); // publish
            break;
          }
        }
      }
      break;
    }
    case 'consumer': case 'consumer-plain': {
      const plain = kind === 'consumer-plain';
      let bad = 0;
      for (let k = 0; k < n; k++) {
        for (;;) {
          const h = plain ? i32[0] : Atomics.load(i32, 0);
          const t = plain ? i32[1] : Atomics.load(i32, 1);
          if (h < t) {
            const v = i32[2 + (h % cap)];        // plain slot load (proof: slot owned by consumer)
            if (v !== k + 1) bad++;
            if (plain) i32[0] = h + 1; else Atomics.store(i32, 0, h + 1);
            break;
          }
        }
      }
      parentPort.postMessage({ bad });
      return;
    }
  }
  parentPort.postMessage({});
}

// ---------------------------------------------------------------- driver
function run(kind, sab, extra = {}) {
  return new Promise((resolve, reject) => {
    const w = new Worker(self, { workerData: { kind, sab, ...extra } });
    const timer = setTimeout(() => { w.terminate(); resolve({ timeout: true }); }, extra.timeoutMs ?? 20000);
    w.once('message', (m) => { clearTimeout(timer); resolve(m); w.terminate(); });
    w.once('error', (e) => { clearTimeout(timer); reject(e); });
  });
}

async function counter(kind, threads, n) {
  const sab = new SharedArrayBuffer(8);
  const gate = new SharedArrayBuffer(4);
  const t0 = performance.now();
  await Promise.all(Array.from({ length: threads }, () => run(kind, sab, { n, gate, parties: threads })));
  const ms = performance.now() - t0;
  const got = new Int32Array(sab)[0];
  return { kind, threads, expected: threads * n, got, ok: got === threads * n, ms: +ms.toFixed(1) };
}

async function ring(plain, n, cap) {
  const sab = new SharedArrayBuffer(4 * (2 + cap));
  const gate = new SharedArrayBuffer(4);
  const t0 = performance.now();
  const [, c] = await Promise.all([
    run(plain ? 'producer-plain' : 'producer', sab, { n, cap, gate, parties: 2, timeoutMs: 15000 }),
    run(plain ? 'consumer-plain' : 'consumer', sab, { n, cap, gate, parties: 2, timeoutMs: 15000 }),
  ]);
  const ms = performance.now() - t0;
  return { kind: plain ? 'spsc-plain-indices' : 'spsc-atomic-indices', n, cap,
           ok: !c.timeout && c.bad === 0, timeout: !!c.timeout, outOfOrder: c.bad, ms: +ms.toFixed(1) };
}

if (!isMainThread) workerMain();
else {
  const N = 2_000_000, T = 4;
  const rows = [];
  for (const k of ['faa', 'cas', 'lock', 'racy']) rows.push(await counter(k, T, N));
  rows.push(await ring(false, 5_000_000, 1024));
  rows.push(await ring(true, 5_000_000, 1024));
  const base = rows.find(r => r.kind === 'faa').ms;
  for (const r of rows) console.log(JSON.stringify({ ...r, ratio_vs_faa: +(r.ms / base).toFixed(2) }));
}
