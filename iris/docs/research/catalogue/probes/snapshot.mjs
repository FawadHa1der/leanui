// P2: one writer keeps updating a K-word record (every word = the version v), one reader keeps taking
// snapshots and checks that all K words agree. Five ways: no synchronisation, a seqlock with plain data
// accesses, a seqlock with Atomics data accesses, a triple buffer (ownership passed by Atomics.exchange),
// and a mutex. Reports reader snapshots/us, writer updates/us, torn snapshots accepted, reader retries,
// and how stale an accepted snapshot is (versions behind the writer, mean).
// Usage: node snapshot.mjs [ms=300] [K=16]
import { Worker, isMainThread, workerData } from 'node:worker_threads';
const L = 16, SEQ = 0, LOCK = L, STATE = 2 * L, START = 3 * L, STOP = 4 * L, VER = 5 * L, DATA = 8 * L; // DATA: 3 buffers of K words, each on its own lines
if (!isMainThread) {
  const { sab, role, mode, K, res } = workerData; const a = new Int32Array(sab), out = new Float64Array(res);
  const buf = i => DATA + i * Math.ceil(K / L) * L;
  const lock = () => { let c = Atomics.compareExchange(a, LOCK, 0, 1); if (c !== 0) { if (c !== 2) c = Atomics.exchange(a, LOCK, 2); while (c !== 0) { Atomics.wait(a, LOCK, 2); c = Atomics.exchange(a, LOCK, 2); } } };
  const unlock = () => { if (Atomics.sub(a, LOCK, 1) !== 1) { Atomics.store(a, LOCK, 0); Atomics.notify(a, LOCK, 1); } };
  while (Atomics.load(a, START) === 0) Atomics.wait(a, START, 0);
  let n = 0, torn = 0, retries = 0, stale = 0;
  if (role === 'writer') {
    let v = 0, back = 1; // triple buffer: writer owns `back`, STATE holds the middle index (+4 if fresh), reader owns the front
    while (!Atomics.load(a, STOP)) for (let r = 0; r < 64; r++) {
      v++; Atomics.store(a, VER, v);
      if (mode === 'none') { const b = buf(0); for (let i = 0; i < K; i++) a[b + i] = v; }
      else if (mode === 'seqPlain' || mode === 'seqAtomic') {
        Atomics.add(a, SEQ, 1); const b = buf(0);
        if (mode === 'seqPlain') for (let i = 0; i < K; i++) a[b + i] = v; else for (let i = 0; i < K; i++) Atomics.store(a, b + i, v);
        Atomics.add(a, SEQ, 1);
      } else if (mode === 'triple') { const b = buf(back); for (let i = 0; i < K; i++) a[b + i] = v; back = Atomics.exchange(a, STATE, back | 4) & 3; }
      else if (mode === 'mutex') { lock(); const b = buf(0); for (let i = 0; i < K; i++) a[b + i] = v; unlock(); }
      n++;
    }
  } else {
    let front = 2, sink = 0;
    while (!Atomics.load(a, STOP)) for (let r = 0; r < 64; r++) {
      let x0, ok = true, b = buf(0);
      if (mode === 'none') { x0 = a[b]; for (let i = 1; i < K; i++) if (a[b + i] !== x0) ok = false; }
      else if (mode === 'seqPlain' || mode === 'seqAtomic') {
        for (;;) {
          const s1 = Atomics.load(a, SEQ); if (s1 & 1) { retries++; continue; }
          ok = true;
          if (mode === 'seqPlain') { x0 = a[b]; for (let i = 1; i < K; i++) if (a[b + i] !== x0) ok = false; }
          else { x0 = Atomics.load(a, b); for (let i = 1; i < K; i++) if (Atomics.load(a, b + i) !== x0) ok = false; }
          if (Atomics.load(a, SEQ) === s1) break; retries++;
        }
      } else if (mode === 'triple') {
        if (Atomics.load(a, STATE) & 4) front = Atomics.exchange(a, STATE, front) & 3; // take the fresh middle, give back the old front
        b = buf(front); x0 = a[b]; for (let i = 1; i < K; i++) if (a[b + i] !== x0) ok = false;
      } else if (mode === 'mutex') { lock(); x0 = a[b]; for (let i = 1; i < K; i++) if (a[b + i] !== x0) ok = false; unlock(); }
      if (!ok) torn++; else stale += Atomics.load(a, VER) - x0;
      sink ^= x0; n++;
    }
    out[2] = torn; out[3] = retries; out[4] = stale / Math.max(1, n - torn);
  }
  out[role === 'writer' ? 0 : 1] = n;
  process.exit(0);
} else {
  const ms = +(process.argv[2] || 300), K = +(process.argv[3] || 16);
  for (const mode of ['none', 'seqPlain', 'seqAtomic', 'triple', 'mutex']) {
    const sab = new SharedArrayBuffer(4 * (DATA + 3 * Math.ceil(K / L) * L)), res = new SharedArrayBuffer(8 * 5), a = new Int32Array(sab), out = new Float64Array(res);
    Atomics.store(a, STATE, 0); // middle buffer = 0, not fresh; writer owns 1, reader owns 2
    const ws = ['writer', 'reader'].map(role => new Worker(new URL(import.meta.url), { workerData: { sab, role, mode, K, res } }));
    await Promise.all(ws.map(x => new Promise(r => x.once('online', r)))); await new Promise(r => setTimeout(r, 50));
    const t0 = performance.now(); Atomics.store(a, START, 1); Atomics.notify(a, START);
    await new Promise(r => setTimeout(r, ms)); Atomics.store(a, STOP, 1);
    await Promise.all(ws.map(x => new Promise(r => x.once('exit', r)))); const t = (performance.now() - t0) * 1000;
    console.log(JSON.stringify({ mode, K, writerPerUs: +(out[0] / t).toFixed(3), readerPerUs: +(out[1] / t).toFixed(3), torn: out[2], tornPct: +(out[2] / out[1] * 100).toFixed(3), retries: out[3], meanVersionsBehind: +out[4].toFixed(1) }));
  }
}
