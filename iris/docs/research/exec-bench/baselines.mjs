// Hand-written JavaScript baselines (worker_threads + SharedArrayBuffer + Atomics), same scenarios
// as the translated HeapLang programs.  node bench/baselines.mjs <scenario> <variant> [T] [K] [--runs R]
// Prints JSON {scenario, variant, result, median_ms, times_ms}.
import { Worker, isMainThread, workerData, parentPort } from 'node:worker_threads';

// ---- shared layout (Int32 indices; hot words on separate 64-byte lines) ----
const GO = 0, DONE = 1, CTR = 16, LOCK = 32, NEXT = 48, SERVING = 64, RW = 80, HEAD = 96,
  A = 112, B = 128, TORN = 144, BRK = 160, RES = 176, HEAP0 = 1 << 16;

function lockMutex(I) {                              // Drepper's futex mutex: 0 free, 1 locked, 2 contended
  let c = Atomics.compareExchange(I, LOCK, 0, 1);
  if (c !== 0) {
    if (c !== 2) c = Atomics.exchange(I, LOCK, 2);
    while (c !== 0) { Atomics.wait(I, LOCK, 2); c = Atomics.exchange(I, LOCK, 2); }
  }
}
function unlockMutex(I) {
  if (Atomics.sub(I, LOCK, 1) !== 1) { Atomics.store(I, LOCK, 0); Atomics.notify(I, LOCK, 1); }
}
function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
function sumSq(i, n) { let acc = 0; for (; i < n; i++) { const m = i % 1000; acc += (m * m) % 7; } return acc; }

const KERNELS = {
  counter: {
    faa(I, K) { for (let i = 0; i < K; i++) Atomics.add(I, CTR, 1); },
    cas(I, K) {
      for (let i = 0; i < K; i++) for (;;) { const n = Atomics.load(I, CTR); if (Atomics.compareExchange(I, CTR, n, n + 1) === n) break; }
    },
    spin(I, K) {                                     // idiomatic: CAS spin lock, plain increment inside
      for (let i = 0; i < K; i++) {
        while (Atomics.compareExchange(I, LOCK, 0, 1) !== 0);
        I[CTR]++;
        Atomics.store(I, LOCK, 0);
      }
    },
    'spin-sc'(I, K) {                                // exactly what the translation does: all accesses SeqCst
      for (let i = 0; i < K; i++) {
        while (Atomics.compareExchange(I, LOCK, 0, 1) !== 0);
        Atomics.store(I, CTR, Atomics.load(I, CTR) + 1);
        Atomics.store(I, LOCK, 0);
      }
    },
    ticket(I, K) {
      for (let i = 0; i < K; i++) {
        const my = Atomics.add(I, NEXT, 1);
        while (Atomics.load(I, SERVING) !== my);
        I[CTR]++;
        Atomics.store(I, SERVING, my + 1);
      }
    },
    mutex(I, K) { for (let i = 0; i < K; i++) { lockMutex(I); I[CTR]++; unlockMutex(I); } },
    racy(I, K) { for (let i = 0; i < K; i++) I[CTR]++; },
  },
  rw: {                                              // same algorithm as iris-lean RwSpinLock
    spin(I, K, id, T, W) {
      for (let i = K; i > 0; i--) {
        if (i % W === 0) {
          while (Atomics.compareExchange(I, RW, 0, -1) !== 0);
          I[A]++; I[B]++;
          Atomics.store(I, RW, 0);
        } else {
          for (;;) { const n = Atomics.load(I, RW); if (n >= 0 && Atomics.compareExchange(I, RW, n, n + 1) === n) break; }
          if (I[A] !== I[B]) Atomics.add(I, TORN, 1);
          Atomics.sub(I, RW, 1);
        }
      }
    },
  },
  treiber: {
    sab(I, K, id) {                                  // nodes [val, next] bump-allocated per thread, never freed
      let brk = HEAP0 + id * (2 * K + 16);
      for (let x = K; x > 0; x--) {
        const n = brk; brk += 2; I[n] = x;
        for (;;) { const hd = Atomics.load(I, HEAD); I[n + 1] = hd; if (Atomics.compareExchange(I, HEAD, hd, n) === hd) break; }
      }
      let acc = 0;
      for (let i = K; i > 0;) {
        const hd = Atomics.load(I, HEAD);
        if (hd === 0) continue;
        if (Atomics.compareExchange(I, HEAD, hd, I[hd + 1]) === hd) { acc += I[hd]; i--; }
      }
      Atomics.add(I, RES, acc);
    },
  },
  par: {
    seq(I, K, id, T) { Atomics.add(I, RES, sumSq(0, K)); },
    two(I, K, id, T) { const h = K >> 1; Atomics.add(I, RES, id === 0 ? sumSq(0, h) : sumSq(h, K)); },
  },
  fib: {
    seq(I, K) { Atomics.add(I, RES, fib(K)); },
    four(I, K, id) { const sub = [K - 2, K - 3, K - 3, K - 4][id]; Atomics.add(I, RES, fib(sub)); },
  },
};

function qsortBench(variant, K, RUNS) {             // JS objects, same algorithm as Quicksort.lean
  const cons = (h, t) => ({ h, t });
  const append = (a, b) => a === null ? b : cons(a.h, append(a.t, b));
  const partition = (x, l) => {
    if (l === null) return [null, null];
    const p = partition(x, l.t);
    return l.h <= x ? [cons(l.h, p[0]), p[1]] : [p[0], cons(l.h, p[1])];
  };
  const qs = (l) => { if (l === null) return l; const [a, b] = partition(l.h, l.t); return append(qs(a), cons(l.h, qs(b))); };
  const times = []; let result;
  for (let r = 0; r < RUNS; r++) {
    const t0 = performance.now();
    let l = null, x = 1;
    for (let n = K; n > 0; n--) { l = cons(x, l); x = (x * 75 + 74) % 65537; }
    let s;
    if (variant === 'list') s = qs(l);
    else { const arr = []; for (let c = l; c; c = c.t) arr.push(c.h); arr.sort((p, q) => p - q); s = null; for (let i = arr.length - 1; i >= 0; i--) s = cons(arr[i], s); }
    let ok = true; for (let c = s; c && c.t; c = c.t) if (c.h > c.t.h) ok = false;
    times.push(performance.now() - t0); result = String(ok);
  }
  return { scenario: 'qsort', variant, T: 1, K, result, times_ms: times.map(t => +t.toFixed(3)), median_ms: +[...times].sort((a, b) => a - b)[times.length >> 1].toFixed(3) };
}

if (!isMainThread && workerData.qsortJob) {
  const { variant, K, RUNS } = workerData.qsortJob;
  parentPort.postMessage(qsortBench(variant, K, RUNS));
} else if (!isMainThread) {
  const { sab, scenario, variant, id, T, K, W } = workerData;
  const I = new Int32Array(sab);
  const fn = KERNELS[scenario][variant];
  parentPort.postMessage('ready');
  for (let gen = 1; ; gen++) {
    while (Atomics.load(I, GO) < gen) Atomics.wait(I, GO, gen - 1);
    fn(I, K, id, T, W);
    if (Atomics.add(I, DONE, 1) + 1 === T) Atomics.notify(I, DONE);
  }
} else {
  const args = process.argv.slice(2);
  const [scenario, variant] = args;
  const T = Number(args[2] || 4), K = Number(args[3] || 200000);
  const ri = args.indexOf('--runs'); const RUNS = ri >= 0 ? Number(args[ri + 1]) : 3;
  const W = 10;
  if (scenario === 'qsort') {                        // in a worker with the same 64 MB stack the translated code gets
    const w = new Worker(new URL(import.meta.url), { workerData: { qsortJob: { variant, K, RUNS } }, resourceLimits: { stackSizeMb: 64 } });
    const res = await new Promise((ok, bad) => { w.on('message', ok); w.on('error', bad); });
    console.log(JSON.stringify(res));
    process.exit(0);
  }
  if (scenario === 'forks') {                        // idiomatic JS: postMessage to a pool, K tasks
    const sab = new SharedArrayBuffer(1 << 12), I = new Int32Array(sab);
    const src = `const {parentPort, workerData} = require('node:worker_threads'); const I = new Int32Array(workerData);
      parentPort.on('message', () => { Atomics.add(I, 16, 1); parentPort.postMessage(1); });`;
    const times = []; let result;
    if (variant === 'pool') {
      const ws = []; for (let i = 0; i < T; i++) ws.push(new Worker(src, { eval: true, workerData: sab }));
      await new Promise(r => setTimeout(r, 200));
      for (let r = 0; r < RUNS; r++) {
        Atomics.store(I, 16, 0);
        const t0 = performance.now();
        let got = 0;
        await new Promise(res => { for (const w of ws) w.removeAllListeners('message').on('message', () => { if (++got === K) res(); }); for (let i = 0; i < K; i++) ws[i % T].postMessage(0); });
        times.push(performance.now() - t0); result = String(Atomics.load(I, 16));
      }
    } else {                                         // a fresh Worker per task (what `fork` would cost without a pool)
      for (let r = 0; r < RUNS; r++) {
        Atomics.store(I, 16, 0);
        const t0 = performance.now();
        await Promise.all(Array.from({ length: K }, () => new Promise(res => { const w = new Worker(src, { eval: true, workerData: sab }); w.on('message', () => { w.terminate(); res(); }); w.postMessage(0); })));
        times.push(performance.now() - t0); result = String(Atomics.load(I, 16));
      }
    }
    console.log(JSON.stringify({ scenario, variant, T, K, result, times_ms: times.map(t => +t.toFixed(3)), median_ms: +[...times].sort((a, b) => a - b)[times.length >> 1].toFixed(3) }));
    process.exit(0);
  }
  const sab = new SharedArrayBuffer(64 << 20), I = new Int32Array(sab);
  const ws = [];
  let ready = 0;
  for (let id = 0; id < T; id++) {
    const w = new Worker(new URL(import.meta.url), { workerData: { sab, scenario, variant, id, T, K, W } });
    w.on('message', () => ready++); w.on('error', e => { console.error(e); process.exit(1); });
    ws.push(w);
  }
  while (ready < T) await new Promise(r => setTimeout(r, 2));
  const times = []; let result;
  for (let gen = 1; gen <= RUNS; gen++) {
    for (const k of [DONE, CTR, LOCK, NEXT, SERVING, RW, HEAD, A, B, TORN, RES]) Atomics.store(I, k, 0);
    const t0 = performance.now();
    Atomics.store(I, GO, gen); Atomics.notify(I, GO);
    for (;;) { const d = Atomics.load(I, DONE); if (d === T) break; const r = Atomics.waitAsync(I, DONE, d); if (r.async) await r.value; }
    times.push(performance.now() - t0);
    result = scenario === 'counter' ? String(I[CTR])
      : scenario === 'rw' ? `(${I[TORN]}, ${I[A]})`
      : scenario === 'treiber' ? `(${I[RES]}, ${I[HEAD] === 0})`
      : String(I[RES]);
  }
  console.log(JSON.stringify({ scenario, variant, T, K, result, times_ms: times.map(t => +t.toFixed(3)), median_ms: +[...times].sort((a, b) => a - b)[times.length >> 1].toFixed(3) }));
  process.exit(0);
}
